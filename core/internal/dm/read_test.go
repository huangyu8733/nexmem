package dm

import (
	"context"
	"testing"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

// TestSendReadReceipt 覆盖 P6-07 在线已读回执：对端收到水位并回调 OnRead。
func TestSendReadReceipt(t *testing.T) {
	events := make(chan ReadEvent, 4)
	b := newTestNode(t, "B", func(o *Options) {
		o.OnRead = func(ev ReadEvent) { events <- ev }
	})
	a := newTestNode(t, "A")

	target := Target{PeerID: b.svc.host.ID(), Addrs: b.svc.host.Addrs(), AccountPub: b.account.Pub()}
	upTo := time.Now().Add(-time.Minute).UnixMilli()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := a.svc.SendReadReceipt(ctx, target, upTo); err != nil {
		t.Fatalf("发送已读回执: %v", err)
	}

	select {
	case ev := <-events:
		if ev.ConversationID != ConversationID(a.account.Pub(), b.account.Pub()) {
			t.Fatalf("回执会话 = %s", ev.ConversationID)
		}
		if ev.UpTo != upTo {
			t.Fatalf("回执水位 = %d, 期望 %d", ev.UpTo, upTo)
		}
		if string(ev.PeerAccount) != string(a.account.Pub()) {
			t.Fatal("回执对端账号不匹配")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("等待已读回执超时")
	}

	if err := a.svc.SendReadReceipt(ctx, target, 0); err == nil {
		t.Fatal("水位为 0 应被拒绝")
	}
	if err := a.svc.SendReadReceipt(ctx, target, time.Now().Add(time.Hour).UnixMilli()); err == nil {
		t.Fatal("未来水位应被拒绝")
	}
	if err := a.svc.SendReadReceipt(ctx, Target{PeerID: a.svc.host.ID(), AccountPub: a.account.Pub()}, upTo); err != ErrSelfSend {
		t.Fatalf("自发回执应返回 ErrSelfSend，实际 %v", err)
	}
	if err := a.svc.SendReadReceipt(ctx, Target{AccountPub: []byte("bad")}, upTo); err != ErrInvalidTarget {
		t.Fatalf("非法账号公钥应返回 ErrInvalidTarget，实际 %v", err)
	}
}

// TestValidReadReceipt 覆盖回执校验：接收方、会话与水位都必须与本地身份一致。
func TestValidReadReceipt(t *testing.T) {
	b := newTestNode(t, "B")
	sender := make([]byte, 32)
	sender[0] = 7
	now := time.Now().UnixMilli()

	valid := func() *nexmemv1.ReadReceipt {
		return &nexmemv1.ReadReceipt{
			SenderAccount:   sender,
			ReceiverAccount: b.account.Pub(),
			ConversationId:  []byte(ConversationID(b.account.Pub(), sender)),
			UpToTimestamp:   now,
		}
	}
	if !b.svc.validReadReceipt(valid()) {
		t.Fatal("合法回执应通过校验")
	}

	rc := valid()
	rc.ReceiverAccount = sender
	if b.svc.validReadReceipt(rc) {
		t.Fatal("接收方不是本机应被拒绝")
	}

	rc = valid()
	rc.SenderAccount = b.account.Pub()
	if b.svc.validReadReceipt(rc) {
		t.Fatal("发送方是本机应被拒绝")
	}

	rc = valid()
	rc.ConversationId = []byte("dm:deadbeef")
	if b.svc.validReadReceipt(rc) {
		t.Fatal("会话 ID 不匹配应被拒绝")
	}

	rc = valid()
	rc.UpToTimestamp = 0
	if b.svc.validReadReceipt(rc) {
		t.Fatal("水位为 0 应被拒绝")
	}

	rc = valid()
	rc.UpToTimestamp = now + time.Hour.Milliseconds()
	if b.svc.validReadReceipt(rc) {
		t.Fatal("超前水位应被拒绝")
	}
}
