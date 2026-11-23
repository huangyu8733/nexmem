package dm

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
)

// resumeNode 是可在同一目录上重建的可控节点，用于模拟断网 / 重连。
type resumeNode struct {
	dir     string
	account *identity.Account
	host    host.Host
	db      *sql.DB
	dao     *store.DAO
	svc     *Service
	once    sync.Once
}

type resumeNodeConfig struct {
	ackTimeout     time.Duration
	maxAttempts    int
	disableAuto    bool
	resumeInterval time.Duration
	retryDelay     time.Duration
}

func startResumeNode(t *testing.T, dir string, account *identity.Account, cfg resumeNodeConfig) *resumeNode {
	t.Helper()
	ctx := context.Background()

	db, err := store.Open(filepath.Join(dir, "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库: %v", err)
	}
	if err := store.Migrate(ctx, db); err != nil {
		db.Close()
		t.Fatalf("迁移: %v", err)
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(dir, "device.key"))
	if err != nil {
		db.Close()
		t.Fatalf("加载设备密钥: %v", err)
	}
	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey: priv,
		Listen:     []string{"/ip4/127.0.0.1/tcp/0"},
		UserAgent:  "nexmem-resume-test/0.1.0",
	})
	if err != nil {
		db.Close()
		t.Fatalf("启动 host: %v", err)
	}
	dao := store.NewDAO(db)
	svc, err := New(Options{
		Host:              h,
		DeviceKey:         priv,
		DAO:               dao,
		Account:           account,
		AckTimeout:        cfg.ackTimeout,
		MaxAttempts:       cfg.maxAttempts,
		ResumeInterval:    cfg.resumeInterval,
		ResumeRetryDelay:  cfg.retryDelay,
		DisableAutoResume: cfg.disableAuto,
	})
	if err != nil {
		h.Close()
		db.Close()
		t.Fatalf("创建单聊服务: %v", err)
	}

	n := &resumeNode{dir: dir, account: account, host: h, db: db, dao: dao, svc: svc}
	t.Cleanup(n.stop)
	return n
}

func (n *resumeNode) stop() {
	n.once.Do(func() {
		n.svc.Close()
		_ = n.host.Close()
		_ = n.db.Close()
	})
}

func (n *resumeNode) target() Target {
	return Target{PeerID: n.host.ID(), Addrs: n.host.Addrs(), AccountPub: n.account.Pub()}
}

func (n *resumeNode) waitOutboxEmpty(t *testing.T, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		c, err := n.dao.CountOutbox(context.Background())
		if err != nil {
			t.Fatalf("统计离线队列: %v", err)
		}
		if c == 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	c, _ := n.dao.CountOutbox(context.Background())
	t.Fatalf("离线队列在 %s 内未清空，剩余 %d 条", within, c)
}

// TestResumeOutboxAfterReconnect 验证 P2-03：
// 断网期间消息进入离线队列，对端以同一设备密钥重新上线后补发成功，
// 双方消息集合完全一致且不产生重复。
func TestResumeOutboxAfterReconnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	dirA := t.TempDir()
	dirB := t.TempDir()
	accA, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成 A 账号: %v", err)
	}
	accB, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成 B 账号: %v", err)
	}

	// ACK 超时需覆盖满载 CI 下的握手与往返抖动：原 300ms 在 go test ./... 并发
	// 跑时偶发让 1 条消息被 deferOutbox 保留（Delivered 4/5、Retained 1），
	// 单独跑却稳定通过；这里只放宽本用例的窗口，仍保持 maxAttempts=1 以验证
	// 单次补发路径本身，其它刻意测超时/重试的用例沿用原配置。
	cfg := resumeNodeConfig{ackTimeout: 3 * time.Second, maxAttempts: 1, disableAuto: true}
	b := startResumeNode(t, dirB, accB, cfg)
	offlineTarget := b.target()
	b.stop() // 模拟对方断网下线

	a := startResumeNode(t, dirA, accA, cfg)
	const count = 5
	for i := 0; i < count; i++ {
		msgID, err := a.svc.SendText(ctx, offlineTarget, fmt.Sprintf("offline-%d", i), "")
		if err == nil {
			t.Fatalf("对端离线时第 %d 条发送应失败", i)
		}
		if msgID == "" {
			t.Fatalf("失败消息仍应返回 msg_uuid")
		}
	}
	if n, err := a.dao.CountOutbox(ctx); err != nil || n != count {
		t.Fatalf("离线队列应有 %d 条，实际 %d (err=%v)", count, n, err)
	}

	// 对端以同一设备密钥重启：PeerID 不变，监听端口变化。
	b2 := startResumeNode(t, dirB, accB, cfg)
	a.svc.SetResolver(PeerResolverFunc(func(_ context.Context, accountPub []byte) (Target, error) {
		if !bytes.Equal(accountPub, accB.Pub()) {
			return Target{}, fmt.Errorf("未知对端")
		}
		return b2.target(), nil
	}))

	rep, err := a.svc.ResumeOutbox(ctx)
	if err != nil {
		t.Fatalf("补发失败: %v", err)
	}
	if rep.Delivered != count || rep.Retained != 0 || rep.Dropped != 0 {
		t.Fatalf("补发结果不符: %+v", rep)
	}
	if n, err := a.dao.CountOutbox(ctx); err != nil || n != 0 {
		t.Fatalf("补发后离线队列应为空，实际 %d 条 (err=%v)", n, err)
	}

	convID := ConversationID(accA.Pub(), accB.Pub())
	sent := listAscending(t, a.dao, convID)
	if len(sent) != count {
		t.Fatalf("A 本地消息应为 %d 条，实际 %d 条", count, len(sent))
	}
	for i, m := range sent {
		if m.State != store.MessageStateSent {
			t.Fatalf("第 %d 条补发后状态应为 sent，实际 %d", i, m.State)
		}
	}

	received := listAscending(t, b2.dao, convID)
	if len(received) != count {
		t.Fatalf("B 应收到 %d 条，实际 %d 条", count, len(received))
	}
	for i, m := range received {
		var inner nexmemv1.InnerMessage
		if err := proto.Unmarshal(m.BodyEnc, &inner); err != nil {
			t.Fatalf("第 %d 条正文解析失败: %v", i, err)
		}
		if want := fmt.Sprintf("offline-%d", i); inner.GetText() != want {
			t.Fatalf("第 %d 条顺序或内容错误：收到 %q，期望 %q", i, inner.GetText(), want)
		}
	}
	conv, err := b2.dao.GetConversation(ctx, convID)
	if err != nil {
		t.Fatalf("读取 B 会话: %v", err)
	}
	if conv.Unread != count {
		t.Fatalf("B 未读数应为 %d，实际 %d", count, conv.Unread)
	}

	// 重复补发不应产生重复消息。
	rep, err = a.svc.ResumeOutbox(ctx)
	if err != nil {
		t.Fatalf("二次补发失败: %v", err)
	}
	if rep.Scanned != 0 {
		t.Fatalf("二次补发不应扫描到条目: %+v", rep)
	}
	if n, err := b2.dao.CountMessages(ctx, convID); err != nil || n != count {
		t.Fatalf("重复补发后 B 仍应只有 %d 条，实际 %d (err=%v)", count, n, err)
	}
}

// TestResumeOutboxWithoutResolver 验证未配置解析器时给出明确错误且不动队列。
func TestResumeOutboxWithoutResolver(t *testing.T) {
	n := startResumeNode(t, t.TempDir(), mustAccount(t), resumeNodeConfig{
		ackTimeout:  100 * time.Millisecond,
		maxAttempts: 1,
		disableAuto: true,
	})
	if _, err := n.svc.ResumeOutbox(context.Background()); !errors.Is(err, ErrNoPeerResolver) {
		t.Fatalf("未配置解析器应返回 ErrNoPeerResolver，实际 %v", err)
	}
}

// TestResumeAutoAfterReconnect 验证 P2-03 的自动补发：
// 配置解析器后无需手动调用，后台扫描在对端重新上线后自动把队列清空。
func TestResumeAutoAfterReconnect(t *testing.T) {
	ctx := context.Background()
	dirA := t.TempDir()
	dirB := t.TempDir()
	accA := mustAccount(t)
	accB := mustAccount(t)

	b := startResumeNode(t, dirB, accB, resumeNodeConfig{
		ackTimeout:  200 * time.Millisecond,
		maxAttempts: 1,
		disableAuto: true,
	})
	offlineTarget := b.target()
	b.stop()

	// A 开启自动补发，扫描与退避都压到 50ms，便于在测试内观察。
	a := startResumeNode(t, dirA, accA, resumeNodeConfig{
		ackTimeout:     200 * time.Millisecond,
		maxAttempts:    1,
		disableAuto:    false,
		resumeInterval: 50 * time.Millisecond,
		retryDelay:     50 * time.Millisecond,
	})

	const count = 3
	for i := 0; i < count; i++ {
		if _, err := a.svc.SendText(ctx, offlineTarget, fmt.Sprintf("auto-%d", i), ""); err == nil {
			t.Fatalf("对端离线时第 %d 条发送应失败", i)
		}
	}

	// 先配置解析器（此时对端仍离线），随后对端上线，验证后台扫描自动补发。
	var live atomic.Pointer[Target]
	a.svc.SetResolver(PeerResolverFunc(func(_ context.Context, accountPub []byte) (Target, error) {
		if !bytes.Equal(accountPub, accB.Pub()) {
			return Target{}, fmt.Errorf("未知对端")
		}
		t2 := live.Load()
		if t2 == nil {
			return Target{}, fmt.Errorf("对端尚未上线")
		}
		return *t2, nil
	}))

	b2 := startResumeNode(t, dirB, accB, resumeNodeConfig{
		ackTimeout:  200 * time.Millisecond,
		maxAttempts: 1,
		disableAuto: true,
	})
	t2 := b2.target()
	live.Store(&t2)

	a.waitOutboxEmpty(t, 5*time.Second)

	convID := ConversationID(accA.Pub(), accB.Pub())
	if n, err := b2.dao.CountMessages(ctx, convID); err != nil || n != count {
		t.Fatalf("B 应自动收到 %d 条，实际 %d (err=%v)", count, n, err)
	}
}

func mustAccount(t *testing.T) *identity.Account {
	t.Helper()
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成账号: %v", err)
	}
	return acc
}
