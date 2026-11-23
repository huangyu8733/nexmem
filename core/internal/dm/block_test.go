package dm

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/contacts"
	"github.com/nexmem/core/internal/store"
)

// withContacts 在测试节点上装配联系人服务，并返回到它的引用。
func withContacts(t *testing.T, target **contacts.Service) func(*Options) {
	return func(o *Options) {
		svc, err := contacts.New(o.DAO)
		if err != nil {
			t.Fatalf("创建联系人服务: %v", err)
		}
		o.Blocklist = svc
		*target = svc
	}
}

// TestBlockedPeerCannotSend 校验拉黑后本机直接拒绝发送，不落库、不触达对端。
func TestBlockedPeerCannotSend(t *testing.T) {
	var aContacts *contacts.Service
	a := newTestNode(t, "A", withContacts(t, &aContacts))
	b := newTestNode(t, "B")
	ctx := context.Background()

	if err := aContacts.SetBlocked(ctx, b.account.Pub(), true); err != nil {
		t.Fatalf("拉黑对端: %v", err)
	}
	target := Target{
		PeerID:     b.svc.host.ID(),
		Addrs:      b.svc.host.Addrs(),
		AccountPub: b.account.Pub(),
	}
	if _, err := a.svc.SendText(ctx, target, "hi", ""); !errors.Is(err, ErrPeerBlocked) {
		t.Fatalf("拉黑后发送应返回 ErrPeerBlocked，实际 %v", err)
	}

	convID := ConversationID(a.account.Pub(), b.account.Pub())
	if n, err := a.dao.CountMessages(ctx, convID); err != nil || n != 0 {
		t.Fatalf("拉黑拦截后不应落库，实际 %d 条 (err=%v)", n, err)
	}
	if n, err := b.dao.CountMessages(ctx, convID); err != nil || n != 0 {
		t.Fatalf("对端不应收到消息，实际 %d 条 (err=%v)", n, err)
	}

	// 取消拉黑后恢复正常。
	if err := aContacts.SetBlocked(ctx, b.account.Pub(), false); err != nil {
		t.Fatalf("取消拉黑: %v", err)
	}
	if _, err := a.svc.SendText(ctx, target, "hi", ""); err != nil {
		t.Fatalf("取消拉黑后应可发送，实际 %v", err)
	}
	if n, err := b.dao.CountMessages(ctx, convID); err != nil || n != 1 {
		t.Fatalf("对端应收到 1 条，实际 %d 条 (err=%v)", n, err)
	}
}

// TestBlockedInboundRejected 校验被拉黑方发来的消息在本机侧被拒收：
// 不写消息表、不创建会话、不回未读，且发送方拿到 ACK 拒收。
func TestBlockedInboundRejected(t *testing.T) {
	var bContacts *contacts.Service
	a := newTestNode(t, "A")
	b := newTestNode(t, "B", withContacts(t, &bContacts))
	ctx := context.Background()

	if err := bContacts.SetBlocked(ctx, a.account.Pub(), true); err != nil {
		t.Fatalf("拉黑发送方: %v", err)
	}
	convID := ConversationID(a.account.Pub(), b.account.Pub())
	_, err := a.svc.SendText(ctx, Target{
		PeerID:     b.svc.host.ID(),
		Addrs:      b.svc.host.Addrs(),
		AccountPub: b.account.Pub(),
	}, "你已被拉黑", "")
	if !errors.Is(err, ErrPeerRejected) {
		t.Fatalf("被拉黑方发送应收到 ACK 拒收，实际 %v", err)
	}

	if n, err := b.dao.CountMessages(ctx, convID); err != nil || n != 0 {
		t.Fatalf("被拒收的消息不应入库，实际 %d 条 (err=%v)", n, err)
	}
	if _, err := b.dao.GetConversation(ctx, convID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("被拒收的消息不应创建会话，实际 %v", err)
	}

	// 发送方本地该消息标记为失败，也不应进入离线补发队列。
	msgs := listAscending(t, a.dao, convID)
	if len(msgs) != 1 || msgs[0].State != store.MessageStateFailed {
		t.Fatalf("发送方消息应为 failed，实际 %+v", msgs)
	}
	if n, err := a.dao.CountOutbox(ctx); err != nil || n != 0 {
		t.Fatalf("明确拒收不应进入补发队列，实际 %d 条 (err=%v)", n, err)
	}
}

// TestRemarkNotOnWire 校验本地备注不会随消息上行。
func TestRemarkNotOnWire(t *testing.T) {
	var aContacts *contacts.Service
	a := newTestNode(t, "A", withContacts(t, &aContacts))
	b := newTestNode(t, "B")
	ctx := context.Background()

	const note = "绝密备注专属标记"
	if err := aContacts.Remark(ctx, b.account.Pub(), note); err != nil {
		t.Fatalf("设置备注: %v", err)
	}
	if _, err := a.svc.SendText(ctx, Target{
		PeerID:     b.svc.host.ID(),
		Addrs:      b.svc.host.Addrs(),
		AccountPub: b.account.Pub(),
	}, "正文", ""); err != nil {
		t.Fatalf("发送消息: %v", err)
	}

	convID := ConversationID(a.account.Pub(), b.account.Pub())
	msgs := listAscending(t, b.dao, convID)
	if len(msgs) != 1 {
		t.Fatalf("对端应收到 1 条，实际 %d", len(msgs))
	}
	if bytes.Contains(msgs[0].Raw, []byte(note)) || bytes.Contains(msgs[0].BodyEnc, []byte(note)) {
		t.Fatalf("备注不应出现在上行报文或正文中")
	}

	// 备注只在本机可见且仍保留。
	local, err := aContacts.Get(ctx, b.account.Pub())
	if err != nil || local.Alias != note {
		t.Fatalf("本机备注应保留，实际 %+v (err=%v)", local, err)
	}
}

// TestBlockedOfflineObjectRejected 校验被拉黑对象的离线消息在拉取阶段即被丢弃。
func TestBlockedOfflineObjectRejected(t *testing.T) {
	inbox := newFakeInbox()
	var recvContacts *contacts.Service
	recv := newTestNode(t, "R", func(o *Options) {
		o.Inbox = inbox
		o.DisableAutoFetch = true
		withContacts(t, &recvContacts)(o)
	})
	sender := newTestNode(t, "A")
	ctx := context.Background()

	if err := recvContacts.SetBlocked(ctx, sender.account.Pub(), true); err != nil {
		t.Fatalf("拉黑发送方: %v", err)
	}
	key := blob.InboxPrefix(recv.account.Pub()) + "0001.msg"
	inbox.Put(key, buildOfflinePayload(t, sender.account, recv.account,
		"0192f3a0-0000-7000-8000-000000000001", "离线消息", time.Now(), 24), time.Now())

	rep, err := recv.svc.FetchOffline(ctx)
	if err != nil {
		t.Fatalf("拉取离线消息: %v", err)
	}
	if rep.Imported != 0 || rep.Skipped != 1 {
		t.Fatalf("被拉黑对象的离线消息应被丢弃，实际 %+v", rep)
	}
	convID := ConversationID(sender.account.Pub(), recv.account.Pub())
	if n, err := recv.dao.CountMessages(ctx, convID); err != nil || n != 0 {
		t.Fatalf("丢弃对象不应入库，实际 %d 条 (err=%v)", n, err)
	}
}
