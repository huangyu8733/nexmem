package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func putSearchMessage(t *testing.T, dao *DAO, id, conv, body string, sentAt int64) {
	t.Helper()
	if err := dao.PutMessage(context.Background(), Message{
		MsgUUID:        id,
		ConversationID: conv,
		SenderAccount:  []byte("alice"),
		SentAt:         sentAt,
		Direction:      DirectionIn,
		ContentType:    0,
		BodyEnc:        []byte(body),
		State:          MessageStateReceived,
		Body:           body,
	}); err != nil {
		t.Fatalf("写入消息 %s 失败: %v", id, err)
	}
}

func TestSearchMessagesMatchesSubstrings(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	putSearchMessage(t, dao, "m1", "dm:a|b", "今天天气很好，我们去公园散步", 100)
	putSearchMessage(t, dao, "m2", "dm:a|b", "nexmem meeting notes for the team", 200)
	putSearchMessage(t, dao, "m3", "dm:a|c", "周报：完成了全文检索验收", 300)

	cases := []struct {
		query string
		want  []string
	}{
		{"天气很好", []string{"m1"}},
		{"meeting notes", []string{"m2"}},
		{"全文检索", []string{"m3"}},
		{"天气", []string{"m1"}}, // 两字中文走 LIKE 回退
		{"不存在的内容", nil},
	}
	for _, tc := range cases {
		hits, err := dao.SearchMessages(ctx, MessageSearchQuery{Query: tc.query})
		if err != nil {
			t.Fatalf("检索 %q 失败: %v", tc.query, err)
		}
		got := make([]string, 0, len(hits))
		for _, h := range hits {
			got = append(got, h.MsgUUID)
		}
		if strings.Join(got, ",") != strings.Join(tc.want, ",") {
			t.Fatalf("检索 %q 命中 %v, 期望 %v", tc.query, got, tc.want)
		}
		if tc.want != nil && hits[0].Snippet == "" {
			t.Fatalf("检索 %q 的命中片段为空", tc.query)
		}
	}
}

func TestSearchMessagesFiltersAndOrders(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	for i := 0; i < 5; i++ {
		conv := "dm:a|b"
		if i%2 == 1 {
			conv = "dm:a|c"
		}
		putSearchMessage(t, dao, fmt.Sprintf("m%d", i), conv, fmt.Sprintf("alice hello %d", i), int64(100+i))
	}

	hits, err := dao.SearchMessages(ctx, MessageSearchQuery{Query: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 5 {
		t.Fatalf("应命中 5 条, 实际 %d", len(hits))
	}
	for i := 1; i < len(hits); i++ {
		if hits[i].SentAt > hits[i-1].SentAt {
			t.Fatalf("结果未按时间倒序: %d -> %d", hits[i-1].SentAt, hits[i].SentAt)
		}
	}

	hits, err = dao.SearchMessages(ctx, MessageSearchQuery{Query: "hello", ConversationID: "dm:a|c"})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 2 {
		t.Fatalf("会话过滤后应命中 2 条, 实际 %d", len(hits))
	}
	for _, h := range hits {
		if h.ConversationID != "dm:a|c" {
			t.Fatalf("命中不属于指定会话: %s", h.ConversationID)
		}
	}

	hits, err = dao.SearchMessages(ctx, MessageSearchQuery{Query: "hello", Limit: 2})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 2 {
		t.Fatalf("limit=2 应返回 2 条, 实际 %d", len(hits))
	}
}

func TestSearchMessagesEmptyQuery(t *testing.T) {
	dao := newTestDAO(t)
	if _, err := dao.SearchMessages(context.Background(), MessageSearchQuery{Query: "   "}); !errors.Is(err, ErrEmptySearchQuery) {
		t.Fatalf("空关键词应返回 ErrEmptySearchQuery, 实际 %v", err)
	}
}

func TestSearchIndexFollowsUpdatesAndDeletes(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	putSearchMessage(t, dao, "m1", "dm:a|b", "第一版内容：苹果", 100)
	hits, err := dao.SearchMessages(ctx, MessageSearchQuery{Query: "苹果"})
	if err != nil || len(hits) != 1 {
		t.Fatalf("检索两字关键词失败: hits=%d err=%v", len(hits), err)
	}

	// 同一 msg_uuid 更新正文后，旧关键词不应再命中。
	if err := dao.PutMessage(ctx, Message{
		MsgUUID:        "m1",
		ConversationID: "dm:a|b",
		SenderAccount:  []byte("alice"),
		SentAt:         100,
		Direction:      DirectionIn,
		BodyEnc:        []byte("第二版内容：香蕉"),
		State:          MessageStateReceived,
		Body:           "第二版内容：香蕉",
	}); err != nil {
		t.Fatal(err)
	}
	if hits, err = dao.SearchMessages(ctx, MessageSearchQuery{Query: "苹果"}); err != nil || len(hits) != 0 {
		t.Fatalf("旧关键词不应命中: hits=%d err=%v", len(hits), err)
	}
	if hits, err = dao.SearchMessages(ctx, MessageSearchQuery{Query: "香蕉"}); err != nil || len(hits) != 1 {
		t.Fatalf("新关键词应命中 1 条: hits=%d err=%v", len(hits), err)
	}

	// 仅更新状态（Body 为空）时保留索引。
	if err := dao.UpdateMessageState(ctx, "m1", MessageStateAcked); err != nil {
		t.Fatal(err)
	}
	if hits, err = dao.SearchMessages(ctx, MessageSearchQuery{Query: "香蕉"}); err != nil || len(hits) != 1 {
		t.Fatalf("状态更新后索引应保留: hits=%d err=%v", len(hits), err)
	}

	if err := dao.DeleteMessage(ctx, "m1"); err != nil {
		t.Fatal(err)
	}
	if hits, err = dao.SearchMessages(ctx, MessageSearchQuery{Query: "香蕉"}); err != nil || len(hits) != 0 {
		t.Fatalf("删除消息后不应命中: hits=%d err=%v", len(hits), err)
	}
	n, err := dao.CountSearchIndex(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("删除后索引应为空, 实际 %d", n)
	}
}

// TestSearchTenThousandUnder100ms 对应 P2-07 验收标准：1 万条消息下检索 < 100ms。
func TestSearchTenThousandUnder100ms(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	const total = 10000
	msgs := make([]Message, 0, total)
	for i := 0; i < total; i++ {
		body := fmt.Sprintf("第 %d 条消息：今天天气很好，我们一起去公园散步吧。nexmem meeting notes %d", i, i)
		conv := fmt.Sprintf("dm:a|peer%d", i%20)
		msgs = append(msgs, Message{
			MsgUUID:        fmt.Sprintf("m%05d", i),
			ConversationID: conv,
			SenderAccount:  []byte("alice"),
			SentAt:         int64(1_700_000_000 + i),
			Direction:      DirectionIn,
			ContentType:    0,
			BodyEnc:        []byte(body),
			State:          MessageStateReceived,
			Body:           body,
		})
	}
	if err := dao.PutMessages(ctx, msgs); err != nil {
		t.Fatalf("批量写入 %d 条消息失败: %v", total, err)
	}
	n, err := dao.CountSearchIndex(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != total {
		t.Fatalf("索引条数应为 %d, 实际 %d", total, n)
	}

	queries := []string{"nexmem", "天气很好", "公园散步", "meeting notes", "不存在的关键词"}
	for _, q := range queries {
		start := time.Now()
		hits, err := dao.SearchMessages(ctx, MessageSearchQuery{Query: q, Limit: 50})
		elapsed := time.Since(start)
		if err != nil {
			t.Fatalf("检索 %q 失败: %v", q, err)
		}
		t.Logf("检索 %q 命中 %d 条, 耗时 %v", q, len(hits), elapsed)
		if q != "不存在的关键词" && len(hits) == 0 {
			t.Fatalf("检索 %q 应有命中", q)
		}
		if elapsed >= 100*time.Millisecond {
			t.Fatalf("检索 %q 耗时 %v, 超过 100ms 验收标准", q, elapsed)
		}
	}
}
