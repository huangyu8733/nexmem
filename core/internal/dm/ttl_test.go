package dm

import (
	"context"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/expiry"
)

// TestSendTextWithTTL 覆盖定时消息端到端：正文 InnerMessage.ttl_hours 随密文到达对端，
// 发送方与接收方各自按 sent_at + ttl 计算本机销毁时间（expires_at），且超出范围被拒。
func TestSendTextWithTTL(t *testing.T) {
	received := make(chan InboundEvent, 4)
	b := newTestNode(t, "B", func(o *Options) {
		o.OnMessage = func(ev InboundEvent) { received <- ev }
	})
	a := newTestNode(t, "A")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const ttlHours = uint32(24)
	target := Target{PeerID: b.svc.host.ID(), Addrs: b.svc.host.Addrs(), AccountPub: b.account.Pub()}
	msgID, err := a.svc.SendTextWithOptions(ctx, target, "定时消息正文", "", nil, ttlHours)
	if err != nil {
		t.Fatalf("发送定时消息: %v", err)
	}

	// 发送方本机落库应带 expires_at。
	outMsg, err := a.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取发送方消息: %v", err)
	}
	wantExpiry := expiry.ExpiresAt(outMsg.SentAt, ttlHours)
	if outMsg.ExpiresAt != wantExpiry {
		t.Fatalf("发送方 expires_at = %d，期望 %d", outMsg.ExpiresAt, wantExpiry)
	}
	var inner nexmemv1.InnerMessage
	if err := proto.Unmarshal(outMsg.BodyEnc, &inner); err != nil || inner.GetTtlHours() != ttlHours {
		t.Fatalf("发送方正文 ttl_hours 不正确: %d / %v", inner.GetTtlHours(), err)
	}

	select {
	case ev := <-received:
		if ev.MsgUUID != msgID {
			t.Fatalf("接收方事件 msg_uuid = %s，期望 %s", ev.MsgUUID, msgID)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("等待接收方落库事件超时")
	}

	// 接收方本机落库应带相同的 expires_at（按同一 sent_at 计算）。
	inMsg, err := b.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取接收方消息: %v", err)
	}
	if inMsg.ExpiresAt != wantExpiry {
		t.Fatalf("接收方 expires_at = %d，期望 %d", inMsg.ExpiresAt, wantExpiry)
	}

	// 越界 TTL 应被拒绝。
	if _, err := a.svc.SendTextWithOptions(ctx, target, "bad", "", nil, 169); err == nil {
		t.Fatal("TTL=169 应被拒绝，实际成功")
	}
	// TTL=0 表示永不过期。
	id2, err := a.svc.SendTextWithOptions(ctx, target, "永久消息", "", nil, 0)
	if err != nil {
		t.Fatalf("TTL=0 发送失败: %v", err)
	}
	perm, err := a.dao.GetMessage(ctx, id2)
	if err != nil || perm.ExpiresAt != 0 {
		t.Fatalf("TTL=0 消息 expires_at 应为 0，实际 %d / %v", perm.ExpiresAt, err)
	}
}
