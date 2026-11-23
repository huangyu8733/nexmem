package dm

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/network"

	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

// TestAckRetryThenOfflineQueue 验证 P2-01：
// 对端收到帧但不回 ACK 时，按 AckTimeout 重试 3 次，最终标记 failed 并写入离线队列。
func TestAckRetryThenOfflineQueue(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()

	// 静默对端：只读帧、不回 ACK。
	silentKey, err := netnode.LoadOrCreateKey(filepath.Join(dir, "silent.key"))
	if err != nil {
		t.Fatalf("生成对端设备密钥: %v", err)
	}
	silent, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey: silentKey,
		Listen:     []string{"/ip4/127.0.0.1/tcp/0"},
		UserAgent:  "nexmem-silent-test/0.1.0",
	})
	if err != nil {
		t.Fatalf("启动对端 host: %v", err)
	}
	t.Cleanup(func() { silent.Close() })

	var frames atomic.Int32
	silent.SetStreamHandler(wire.PIDDM, func(st network.Stream) {
		defer st.Close()
		frames.Add(1)
		_ = st.SetDeadline(time.Now().Add(2 * time.Second))
		_, _ = wire.ReadFrame(st)
	})

	peerAccount, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成对端账号: %v", err)
	}

	// 发送端。
	db, err := store.Open(filepath.Join(dir, "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if err := store.Migrate(ctx, db); err != nil {
		t.Fatalf("迁移: %v", err)
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成发送端账号: %v", err)
	}
	devKey, err := netnode.LoadOrCreateKey(filepath.Join(dir, "device.key"))
	if err != nil {
		t.Fatalf("生成发送端设备密钥: %v", err)
	}
	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey: devKey,
		Listen:     []string{"/ip4/127.0.0.1/tcp/0"},
		UserAgent:  "nexmem-ack-test/0.1.0",
	})
	if err != nil {
		t.Fatalf("启动发送端 host: %v", err)
	}
	dao := store.NewDAO(db)
	svc, err := New(Options{
		Host:        h,
		DeviceKey:   devKey,
		DAO:         dao,
		Account:     acc,
		AckTimeout:  100 * time.Millisecond,
		MaxAttempts: DefaultMaxAttempts,
	})
	if err != nil {
		h.Close()
		t.Fatalf("创建单聊服务: %v", err)
	}
	t.Cleanup(func() {
		svc.Close()
		h.Close()
	})

	msgID, err := svc.SendText(ctx, Target{
		PeerID:     silent.ID(),
		Addrs:      silent.Addrs(),
		AccountPub: peerAccount.Pub(),
	}, "hi", "")
	if err == nil {
		t.Fatalf("对端不回 ACK 时发送应失败")
	}
	if n := frames.Load(); n != DefaultMaxAttempts {
		t.Fatalf("对端应收到 %d 帧，实际 %d", DefaultMaxAttempts, n)
	}

	msg, err := dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取本地消息: %v", err)
	}
	if msg.State != store.MessageStateFailed {
		t.Fatalf("消息状态应为 failed，实际 %d", msg.State)
	}

	entry, err := dao.GetOutbox(ctx, msgID)
	if err != nil {
		t.Fatalf("失败消息应进入离线队列: %v", err)
	}
	if !bytes.Equal(entry.PeerAccount, peerAccount.Pub()) {
		t.Fatalf("离线队列对端账号不符")
	}
	if len(entry.Payload) == 0 {
		t.Fatalf("离线队列载荷不应为空")
	}
}

// TestAckSuccessNoOutbox 验证 ACK 成功后消息为 sent，且不产生离线队列条目。
func TestAckSuccessNoOutbox(t *testing.T) {
	a := newTestNode(t, "A")
	b := newTestNode(t, "B")
	ctx := context.Background()

	msgID, err := a.svc.SendText(ctx, Target{
		PeerID:     b.svc.host.ID(),
		Addrs:      b.svc.host.Addrs(),
		AccountPub: b.account.Pub(),
	}, "hello", "")
	if err != nil {
		t.Fatalf("发送失败: %v", err)
	}

	msg, err := a.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取本地消息: %v", err)
	}
	if msg.State != store.MessageStateSent {
		t.Fatalf("消息状态应为 sent，实际 %d", msg.State)
	}
	if n, err := a.dao.CountOutbox(ctx); err != nil || n != 0 {
		t.Fatalf("ACK 成功后离线队列应为空，实际 %d 条 (err=%v)", n, err)
	}
	if _, err := a.dao.GetOutbox(ctx, msgID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("不应存在离线队列条目，实际 %v", err)
	}
}

// TestDefaultAckTimeout 锁定 P2-01 的 8s ACK 口径。
func TestDefaultAckTimeout(t *testing.T) {
	if DefaultAckTimeout != 8*time.Second {
		t.Fatalf("默认 ACK 超时应为 8s，实际 %s", DefaultAckTimeout)
	}
	if DefaultMaxAttempts != 3 {
		t.Fatalf("默认重试次数应为 3，实际 %d", DefaultMaxAttempts)
	}
}
