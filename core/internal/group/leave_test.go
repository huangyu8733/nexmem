package group

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/internal/store"
)

// TestLeaveGroupCleansLocalState 验收 P4-12 退群：本地群记录、密钥、暂存消息
// 与主题订阅全部清理，群不存在时返回 ErrGroupKeyNotFound。
func TestLeaveGroupCleansLocalState(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-leave-group")
	mn := mocknet.New()
	defer mn.Close()

	admin := newRotNode(t, mn)
	member := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}

	seedGroup(t, admin, []*rotNode{member}, groupID, "P4 退群群")
	if err := member.svc.Subscribe(ctx, groupID); err != nil {
		t.Fatalf("订阅群主题: %v", err)
	}
	member.svc.pendingMsgs.Add(pendingEnvelope{GroupID: groupID, KeyVersion: 99}, time.Now())

	if err := member.svc.LeaveGroup(ctx, groupID); err != nil {
		t.Fatalf("退群: %v", err)
	}
	if _, err := member.dao.GetGroup(ctx, groupID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("退群后群记录应删除，实际 %v", err)
	}
	if _, _, ok := member.svc.keys.Latest(groupID); ok {
		t.Fatal("退群后不应保留群密钥")
	}
	if member.svc.Subscribed(groupID) {
		t.Fatal("退群后不应保持主题订阅")
	}
	if member.svc.pendingMsgs.Len() != 0 {
		t.Fatal("退群后应清空该群暂存消息")
	}
	if _, err := admin.dao.GetGroup(ctx, groupID); err != nil {
		t.Fatalf("管理员侧群记录不应受影响: %v", err)
	}
	if err := member.svc.LeaveGroup(ctx, groupID); !errors.Is(err, ErrGroupKeyNotFound) {
		t.Fatalf("重复退群应返回 ErrGroupKeyNotFound，实际 %v", err)
	}
}

// TestDissolveGroup 验收 P4-12 解散：非管理员被拒绝；管理员解散后本机群清理，
// 在线成员收到解散控制帧并据此清理自己的本地群。
func TestDissolveGroup(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-dissolve-group")
	mn := mocknet.New()
	defer mn.Close()

	admin := newRotNode(t, mn)
	memberCh := make(chan Received, 4)
	member := newRotNodeWith(t, mn, func(o *Options) {
		o.OnMessage = func(r Received) {
			if bytes.Equal(r.GroupID, groupID) {
				memberCh <- r
			}
		}
	})
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}

	seedGroup(t, admin, []*rotNode{member}, groupID, "P4 解散群")
	for _, n := range []*rotNode{admin, member} {
		if err := n.svc.Subscribe(ctx, groupID); err != nil {
			t.Fatalf("订阅群主题: %v", err)
		}
	}
	waitMesh(t, []*Service{admin.svc, member.svc}, groupID, 2)

	if ok, err := admin.svc.IsGroupAdmin(ctx, groupID, admin.account.Pub()); err != nil || !ok {
		t.Fatalf("管理员识别失败: ok=%v err=%v", ok, err)
	}
	if ok, err := member.svc.IsGroupAdmin(ctx, groupID, member.account.Pub()); err != nil || ok {
		t.Fatalf("普通成员不应识别为管理员: ok=%v err=%v", ok, err)
	}
	if err := member.svc.DissolveGroup(ctx, groupID); !errors.Is(err, ErrNotGroupAdmin) {
		t.Fatalf("非管理员解散应返回 ErrNotGroupAdmin，实际 %v", err)
	}
	if _, err := member.dao.GetGroup(ctx, groupID); err != nil {
		t.Fatalf("非管理员解散失败后群记录应保留: %v", err)
	}

	if err := admin.svc.DissolveGroup(ctx, groupID); err != nil {
		t.Fatalf("管理员解散: %v", err)
	}
	if _, err := admin.dao.GetGroup(ctx, groupID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("解散后本机群记录应删除，实际 %v", err)
	}
	if admin.svc.Subscribed(groupID) {
		t.Fatal("解散后不应保持主题订阅")
	}

	// 成员应收到解散控制帧。
	deadline := time.After(30 * time.Second)
	for {
		select {
		case ev := <-memberCh:
			if !IsDissolveNotice(ev.Plaintext) {
				continue
			}
			if !bytes.Equal(ev.SenderAccount, admin.account.Pub()) {
				t.Fatalf("解散帧发送方不符: %x", ev.SenderAccount)
			}
			if ok, err := member.svc.IsGroupAdmin(ctx, groupID, ev.SenderAccount); err != nil || !ok {
				t.Fatalf("成员侧管理员校验失败: ok=%v err=%v", ok, err)
			}
			if err := member.svc.LeaveGroup(ctx, groupID); err != nil {
				t.Fatalf("成员按解散帧清理: %v", err)
			}
			if _, err := member.dao.GetGroup(ctx, groupID); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("成员收到解散帧后应删除群记录，实际 %v", err)
			}
			return
		case <-deadline:
			t.Fatal("30s 内未收到解散控制帧")
		}
	}
}

// TestDissolveNoticeFrame 覆盖解散控制帧的编码与识别。
func TestDissolveNoticeFrame(t *testing.T) {
	if !IsDissolveNotice([]byte(DissolveNotice())) {
		t.Fatal("解散控制帧应被识别")
	}
	if IsDissolveNotice([]byte("普通群消息")) {
		t.Fatal("普通文本不应识别为解散帧")
	}
	if !IsControlFrame([]byte(DissolveNotice())) {
		t.Fatal("解散帧应属于控制帧")
	}
	if frame, err := EncodeRecallNotice("aabbccddeeff00112233445566778899"); err != nil {
		t.Fatalf("撤回帧编码失败: %v", err)
	} else if !IsControlFrame([]byte(frame)) || IsDissolveNotice([]byte(frame)) {
		t.Fatal("撤回帧应为控制帧但不是解散帧")
	}
}
