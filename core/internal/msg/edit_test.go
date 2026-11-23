package msg_test

import (
	"context"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/msg"
	"github.com/nexmem/core/internal/store"
)

func bindWithEdit(t *testing.T, dao *store.DAO, onEdited func(string, string, string, int64)) *gateway.Gateway {
	t.Helper()
	gw := gateway.New()
	err := msg.Bind(gw, &msg.Service{
		DAO:      func() *store.DAO { return dao },
		OnEdited: onEdited,
	})
	if err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	return gw
}

func TestEditMessageUpdatesBodyAndNotifies(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	putConversation(t, dao, conv, 0)

	inner, _ := proto.Marshal(&nexmemv1.InnerMessage{Text: "原文", Mentions: []string{"bob"}})
	putMessage(t, dao, store.Message{
		MsgUUID: "0192f3aa-bbbb-7ccc-8ddd-0123456789ab",
		ConversationID: conv, SenderAccount: []byte("self"),
		SentAt: time.Now().UnixMilli(), Direction: store.DirectionOut,
		ContentType: int(nexmemv1.ContentType_CONTENT_TYPE_TEXT),
		BodyEnc: inner, State: store.MessageStateAcked, Body: "原文",
	})

	var cbConv, cbID, cbText string
	var cbAt int64
	gw := bindWithEdit(t, dao, func(c, id, text string, at int64) {
		cbConv, cbID, cbText, cbAt = c, id, text, at
	})
	res, gerr := handle(t, gw, "msg.edit", map[string]any{
		"conversation_id": conv,
		"msg_uuid":        "0192f3aa-bbbb-7ccc-8ddd-0123456789ab",
		"text":            "改后的正文",
	})
	if gerr != nil {
		t.Fatalf("编辑失败: %v", gerr)
	}
	if res.(map[string]any)["edited"] != true {
		t.Fatalf("应返回 edited=true: %v", res)
	}

	got, err := dao.GetMessage(context.Background(), "0192f3aa-bbbb-7ccc-8ddd-0123456789ab")
	if err != nil {
		t.Fatalf("读取编辑后消息: %v", err)
	}
	var out nexmemv1.InnerMessage
	if err := proto.Unmarshal(got.BodyEnc, &out); err != nil {
		t.Fatalf("解析编辑后正文: %v", err)
	}
	if out.GetText() != "改后的正文" || !out.GetEdited() || out.GetEditedAt() <= 0 {
		t.Fatalf("正文/编辑标记不正确: %+v", &out)
	}
	if len(out.GetMentions()) != 1 || out.GetMentions()[0] != "bob" {
		t.Fatalf("编辑不应丢失 mentions: %+v", &out)
	}
	if cbConv != conv || cbID != "0192f3aa-bbbb-7ccc-8ddd-0123456789ab" || cbText != "改后的正文" || cbAt <= 0 {
		t.Fatalf("OnEdited 回调参数不正确: %s %s %s %d", cbConv, cbID, cbText, cbAt)
	}

	// 全文索引应更新为新正文。
	hits, err := dao.SearchMessages(context.Background(), store.MessageSearchQuery{Query: "改后的正文"})
	if err != nil || len(hits) == 0 {
		t.Fatalf("全文索引未更新: hits=%d err=%v", len(hits), err)
	}
}

func TestEditMessageRejectsInvalid(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	gw := bindWithEdit(t, dao, nil)

	cases := []struct {
		name   string
		params map[string]any
	}{
		{"空正文", map[string]any{"conversation_id": conv, "msg_uuid": "x", "text": "  "}},
		{"未知会话类型", map[string]any{"conversation_id": "weird", "msg_uuid": "x", "text": "t"}},
		{"消息不存在", map[string]any{"conversation_id": conv, "msg_uuid": "missing", "text": "t"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, gerr := handle(t, gw, "msg.edit", c.params); gerr == nil {
				t.Fatalf("期望失败但成功")
			}
		})
	}
}
