package group

import (
	"context"
	"testing"
	"time"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"
)

// TestPendingMessagesBounded 覆盖暂存队列的单版本上限与 TTL 过期。
func TestPendingMessagesBounded(t *testing.T) {
	p := newPendingMessages()
	now := time.Now()
	groupID := []byte("pending-cap")

	for i := 0; i < pendingMaxPerVersion+3; i++ {
		dropped := p.Add(pendingEnvelope{
			GroupID:    groupID,
			MsgUUID:    string(rune('a' + i%26)),
			KeyVersion: 1,
			Since:      now,
		}, now)
		if i < pendingMaxPerVersion && dropped != 0 {
			t.Fatalf("第 %d 条不应被丢弃，实际丢弃 %d", i, dropped)
		}
	}
	if got := p.Len(); got != pendingMaxPerVersion {
		t.Fatalf("暂存条数 %d，期望 %d", got, pendingMaxPerVersion)
	}

	// 超过 TTL 的消息在下次写入时清理。
	if dropped := p.Add(pendingEnvelope{
		GroupID:    []byte("pending-other"),
		MsgUUID:    "late",
		KeyVersion: 2,
		Since:      now.Add(pendingTTL + time.Minute),
	}, now.Add(pendingTTL+time.Minute)); dropped != pendingMaxPerVersion {
		t.Fatalf("过期清理 %d 条，期望 %d", dropped, pendingMaxPerVersion)
	}
	if got := p.Len(); got != 1 {
		t.Fatalf("清理后暂存条数 %d，期望 1", got)
	}
	if items := p.Take(groupID, 1); len(items) != 0 {
		t.Fatalf("过期桶应已清空，实际 %d 条", len(items))
	}
	if items := p.Take([]byte("pending-other"), 2); len(items) != 1 {
		t.Fatalf("未过期消息应可取出，实际 %d 条", len(items))
	}
	if got := p.Len(); got != 0 {
		t.Fatalf("取出后暂存条数 %d，期望 0", got)
	}
}

// TestPendingMessageDeliveredAfterKeyArrives 复现 R-15：轮换后的加密消息先于新版本密钥到达时，
// 消息先暂存，密钥受理后补解交付，不静默丢失。
func TestPendingMessageDeliveredAfterKeyArrives(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-pending-group")
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	sender := newKeyTestNode(t, mn, cluster)
	receiver := newKeyTestNode(t, mn, cluster)
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	delivered := make(chan Received, 8)
	receiver.svc.onMsg = func(ev Received) { delivered <- ev }

	// 接收端持有 v1 密钥并已订阅，但尚未收到 v2 轮换信封。
	keyV1, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	if err := receiver.svc.keys.Put(keyV1); err != nil {
		t.Fatalf("写入接收端 v1 密钥: %v", err)
	}
	if err := receiver.svc.Subscribe(ctx, groupID); err != nil {
		t.Fatalf("订阅群主题: %v", err)
	}
	keyV2, err := NewGroupKey(groupID, KeyVersionInitial+1)
	if err != nil {
		t.Fatal(err)
	}
	if err := sender.svc.keys.Put(keyV2); err != nil {
		t.Fatalf("写入发送端 v2 密钥: %v", err)
	}
	if err := sender.svc.Subscribe(ctx, groupID); err != nil {
		t.Fatalf("发送端订阅: %v", err)
	}

	// 反复发布直到接收端暂存成功，避免 mesh 尚未形成导致的误判。
	deadline := time.Now().Add(5 * time.Second)
	for receiver.svc.PendingCount() == 0 && time.Now().Before(deadline) {
		if _, err := sender.svc.PublishEncrypted(ctx, groupID, "先发后到"); err != nil {
			t.Fatalf("发布群消息: %v", err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if n := receiver.svc.PendingCount(); n == 0 {
		t.Fatal("接收端未暂存任何消息")
	}
	select {
	case ev := <-delivered:
		t.Fatalf("缺少密钥时不应交付明文: %+v", ev)
	case <-time.After(200 * time.Millisecond):
	}

	// v2 密钥信封到达后，暂存消息应补解并交付。
	env, err := BuildKeyEnvelope(sender.account, keyV2, receiver.account.Pub(), receiver.account.XPub(), GroupMeta{
		GroupID:    groupID,
		Title:      "R15 群",
		Members:    append([][]byte(nil), cluster.members...),
		KeyVersion: keyV2.Version,
	})
	if err != nil {
		t.Fatalf("构建密钥信封: %v", err)
	}
	if _, _, err := receiver.svc.AcceptKeyEnvelope(ctx, env); err != nil {
		t.Fatalf("受理密钥信封: %v", err)
	}
	if n := receiver.svc.PendingCount(); n != 0 {
		t.Fatalf("补解后暂存条数 %d，期望 0", n)
	}

	waitDelivered := time.After(2 * time.Second)
	for {
		select {
		case ev := <-delivered:
			if string(ev.Plaintext) != "先发后到" {
				t.Fatalf("补解明文不符: %q", ev.Plaintext)
			}
			if ev.KeyVersion != keyV2.Version {
				t.Fatalf("密钥版本 %d，期望 %d", ev.KeyVersion, keyV2.Version)
			}
			return
		case <-waitDelivered:
			t.Fatal("密钥到达后未交付暂存消息")
		}
	}
}
