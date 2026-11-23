package store

import (
	"context"
	"errors"
	"testing"
)

// TestConversationFlags 覆盖 P6-17 会话置顶 / 免打扰的落库与排序语义。
func TestConversationFlags(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	seed := []Conversation{
		{ID: "dm:a", Kind: ConversationKindDM, LastMsgAt: 300},
		{ID: "dm:b", Kind: ConversationKindDM, LastMsgAt: 100, Pinned: true},
		{ID: "dm:c", Kind: ConversationKindDM, LastMsgAt: 200, Pinned: true},
		{ID: "dm:d", Kind: ConversationKindDM, LastMsgAt: 400, Muted: true},
	}
	for _, c := range seed {
		if err := dao.UpsertConversation(ctx, c); err != nil {
			t.Fatalf("写入会话 %s: %v", c.ID, err)
		}
	}

	order := func() []string {
		t.Helper()
		list, err := dao.ListConversations(ctx, 10)
		if err != nil {
			t.Fatalf("读取会话列表: %v", err)
		}
		out := make([]string, 0, len(list))
		for _, c := range list {
			out = append(out, c.ID)
		}
		return out
	}
	assertOrder := func(want ...string) {
		t.Helper()
		got := order()
		if len(got) != len(want) {
			t.Fatalf("会话数 = %d，期望 %d（%v）", len(got), len(want), got)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("会话顺序 = %v，期望 %v", got, want)
			}
		}
	}

	// 置顶优先，置顶内部与其余会话都按最近消息时间倒序。
	assertOrder("dm:c", "dm:b", "dm:d", "dm:a")

	pinned := true
	if err := dao.SetConversationFlags(ctx, "dm:a", &pinned, nil); err != nil {
		t.Fatalf("置顶会话 a: %v", err)
	}
	assertOrder("dm:a", "dm:c", "dm:b", "dm:d")

	muted := true
	if err := dao.SetConversationFlags(ctx, "dm:a", nil, &muted); err != nil {
		t.Fatalf("免打扰会话 a: %v", err)
	}
	got, err := dao.GetConversation(ctx, "dm:a")
	if err != nil {
		t.Fatalf("读取会话 a: %v", err)
	}
	if !got.Pinned || !got.Muted {
		t.Fatalf("会话 a 标记 = pinned:%v muted:%v，期望都为 true", got.Pinned, got.Muted)
	}

	// 入站消息只走 EnsureConversation，不得清掉已有标记。
	if err := dao.EnsureConversation(ctx, Conversation{ID: "dm:a", Kind: ConversationKindDM}); err != nil {
		t.Fatalf("EnsureConversation: %v", err)
	}
	got, err = dao.GetConversation(ctx, "dm:a")
	if err != nil {
		t.Fatalf("再次读取会话 a: %v", err)
	}
	if !got.Pinned || !got.Muted {
		t.Fatalf("EnsureConversation 后标记丢失 = pinned:%v muted:%v", got.Pinned, got.Muted)
	}

	if err := dao.SetConversationFlags(ctx, "dm:missing", &pinned, nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("未知会话应返回 ErrNotFound，实际 %v", err)
	}
	if err := dao.SetConversationFlags(ctx, "dm:a", nil, nil); !errors.Is(err, ErrInvalidFlags) {
		t.Fatalf("未提供标记应返回 ErrInvalidFlags，实际 %v", err)
	}
}
