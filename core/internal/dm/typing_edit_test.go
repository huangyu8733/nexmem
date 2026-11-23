package dm

import (
	"context"
	"testing"
	"time"
)

// TestSendTyping 覆盖七-3 单聊输入状态：对端收到后回调，且不落库。
func TestSendTyping(t *testing.T) {
	events := make(chan TypingEvent, 4)
	b := newTestNode(t, "B", func(o *Options) {
		o.OnTyping = func(ev TypingEvent) { events <- ev }
	})
	a := newTestNode(t, "A")
	convID := ConversationID(a.account.Pub(), b.account.Pub())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	target := Target{PeerID: b.svc.host.ID(), Addrs: b.svc.host.Addrs(), AccountPub: b.account.Pub()}
	if err := a.svc.SendTyping(ctx, target, true); err != nil {
		t.Fatalf("发送输入状态: %v", err)
	}
	select {
	case ev := <-events:
		if !ev.Typing || ev.ConversationID != convID ||
			string(ev.PeerAccount) != string(a.account.Pub()) {
			t.Fatalf("输入状态事件不正确: %+v", ev)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("等待输入状态超时")
	}
	if err := a.svc.SendTyping(ctx, Target{PeerID: a.svc.host.ID(), AccountPub: a.account.Pub()}, true); err != ErrSelfSend {
		t.Fatalf("自发输入状态应返回 ErrSelfSend，实际 %v", err)
	}
}

// TestSendEdit 覆盖七-2 单聊编辑通知：对端收到后回调携带新正文。
func TestSendEdit(t *testing.T) {
	events := make(chan EditEvent, 4)
	b := newTestNode(t, "B", func(o *Options) {
		o.OnEdit = func(ev EditEvent) { events <- ev }
	})
	a := newTestNode(t, "A")
	convID := ConversationID(a.account.Pub(), b.account.Pub())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	target := Target{PeerID: b.svc.host.ID(), Addrs: b.svc.host.Addrs(), AccountPub: b.account.Pub()}
	editedAt := time.Now().UnixMilli()
	if err := a.svc.SendEdit(ctx, target, "msg-edit-1", "新正文", editedAt); err != nil {
		t.Fatalf("发送编辑通知: %v", err)
	}
	select {
	case ev := <-events:
		if ev.MsgUUID != "msg-edit-1" || ev.Text != "新正文" || ev.EditedAt != editedAt ||
			ev.ConversationID != convID || string(ev.PeerAccount) != string(a.account.Pub()) {
			t.Fatalf("编辑通知事件不正确: %+v", ev)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("等待编辑通知超时")
	}
	if err := a.svc.SendEdit(ctx, target, "", "x", editedAt); err == nil {
		t.Fatal("空 msg_uuid 应被拒绝")
	}
}
