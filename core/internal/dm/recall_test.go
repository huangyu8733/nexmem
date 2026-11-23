package dm

import (
	"context"
	"errors"
	"testing"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/store"
)

// TestSendRecall 覆盖 P6-12 单聊撤回：对端收到通知后删除本机消息并回调。
func TestSendRecall(t *testing.T) {
	events := make(chan RecallEvent, 4)
	b := newTestNode(t, "B", func(o *Options) {
		o.OnRecall = func(ev RecallEvent) { events <- ev }
	})
	a := newTestNode(t, "A")

	convID := ConversationID(a.account.Pub(), b.account.Pub())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := b.dao.EnsureConversation(ctx, store.Conversation{
		ID: convID, Kind: store.ConversationKindDM,
	}); err != nil {
		t.Fatalf("建会话: %v", err)
	}
	if err := b.dao.PutMessage(ctx, store.Message{
		MsgUUID:        "msg-recall-1",
		ConversationID: convID,
		SenderAccount:  a.account.Pub(),
		SentAt:         time.Now().Add(-time.Minute).UnixMilli(),
		Direction:      store.DirectionIn,
		ContentType:    int(nexmemv1.ContentType_CONTENT_TYPE_TEXT),
		BodyEnc:        []byte("cipher"),
		Body:           "hi",
		State:          store.MessageStateReceived,
	}); err != nil {
		t.Fatalf("写入消息: %v", err)
	}

	target := Target{PeerID: b.svc.host.ID(), Addrs: b.svc.host.Addrs(), AccountPub: b.account.Pub()}
	if err := a.svc.SendRecall(ctx, target, "msg-recall-1"); err != nil {
		t.Fatalf("发送撤回通知: %v", err)
	}

	select {
	case ev := <-events:
		if ev.MsgUUID != "msg-recall-1" {
			t.Fatalf("撤回 msg_uuid = %s", ev.MsgUUID)
		}
		if ev.ConversationID != convID {
			t.Fatalf("撤回会话 = %s, 期望 %s", ev.ConversationID, convID)
		}
		if string(ev.PeerAccount) != string(a.account.Pub()) {
			t.Fatal("撤回对端账号不匹配")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("等待撤回通知超时")
	}

	if _, err := b.dao.GetMessage(ctx, "msg-recall-1"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("撤回后消息应已删除，实际 err=%v", err)
	}

	if err := a.svc.SendRecall(ctx, target, ""); err == nil {
		t.Fatal("空 msg_uuid 应被拒绝")
	}
	if err := a.svc.SendRecall(ctx, Target{PeerID: a.svc.host.ID(), AccountPub: a.account.Pub()}, "x"); err != ErrSelfSend {
		t.Fatalf("自发撤回应返回 ErrSelfSend，实际 %v", err)
	}
	if err := a.svc.SendRecall(ctx, Target{AccountPub: []byte("bad")}, "x"); err != ErrInvalidTarget {
		t.Fatalf("非法账号公钥应返回 ErrInvalidTarget，实际 %v", err)
	}
}

// TestValidRecallNotice 覆盖撤回通知校验：接收方、会话与时间戳都必须合法。
func TestValidRecallNotice(t *testing.T) {
	b := newTestNode(t, "B")
	sender := make([]byte, 32)
	sender[0] = 9
	now := time.Now().UnixMilli()

	valid := func() *nexmemv1.RecallNotice {
		return &nexmemv1.RecallNotice{
			MsgUuid:         "m-1",
			SenderAccount:   sender,
			ReceiverAccount: b.account.Pub(),
			ConversationId:  []byte(ConversationID(b.account.Pub(), sender)),
			RecalledAt:      now,
		}
	}
	if !b.svc.validRecallNotice(valid()) {
		t.Fatal("合法撤回通知应通过校验")
	}

	cases := []struct {
		name   string
		mutate func(*nexmemv1.RecallNotice)
	}{
		{"空 msg_uuid", func(n *nexmemv1.RecallNotice) { n.MsgUuid = "" }},
		{"接收方不是本机", func(n *nexmemv1.RecallNotice) { n.ReceiverAccount = sender }},
		{"发送方是本机", func(n *nexmemv1.RecallNotice) { n.SenderAccount = b.account.Pub() }},
		{"会话不匹配", func(n *nexmemv1.RecallNotice) { n.ConversationId = []byte("dm:deadbeef") }},
		{"时间为零", func(n *nexmemv1.RecallNotice) { n.RecalledAt = 0 }},
		{"未来时间超出余量", func(n *nexmemv1.RecallNotice) {
			n.RecalledAt = now + recallMaxFuture.Milliseconds() + 60_000
		}},
	}
	for _, tc := range cases {
		notice := valid()
		tc.mutate(notice)
		if b.svc.validRecallNotice(notice) {
			t.Fatalf("%s 应被拒绝", tc.name)
		}
	}
}
