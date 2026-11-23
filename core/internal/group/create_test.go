package group

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"
)

// TestCreateGroupDistributesKey 验收 P1-20 群聊装配：
// 创建群后本机登记管理员与成员表，各成员经密钥信封拿到同一把 v1 群密钥，
// group.members 能读出成员与群盘状态，重启后 SubscribeAll 可恢复订阅。
func TestCreateGroupDistributesKey(t *testing.T) {
	ctx := context.Background()
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	admin := newKeyTestNode(t, mn, cluster)
	m1 := newKeyTestNode(t, mn, cluster)
	m2 := newKeyTestNode(t, mn, cluster)
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	targets := []KeyTarget{
		{PeerID: m1.host.ID(), Addrs: m1.host.Addrs(), AccountPub: m1.account.Pub(), XPub: m1.account.XPub()},
		{PeerID: m2.host.ID(), Addrs: m2.host.Addrs(), AccountPub: m2.account.Pub(), XPub: m2.account.XPub()},
	}
	key, reports, err := admin.svc.CreateGroup(ctx, " 研发群 ", targets)
	if err != nil {
		t.Fatalf("创建群: %v", err)
	}
	if len(key.GroupID) != GroupIDSize || key.Version != KeyVersionInitial {
		t.Fatalf("群密钥非法: %+v", key)
	}
	for _, rep := range reports {
		if rep.Err != nil {
			t.Fatalf("投递成员 %x 失败: %v", rep.AccountPub, rep.Err)
		}
	}

	for name, node := range map[string]*keyTestNode{"m1": m1, "m2": m2} {
		got := waitGroupKey(t, node.svc, key.GroupID)
		if !bytes.Equal(got, key.Key) {
			t.Fatalf("%s 解出的群密钥与管理员不一致", name)
		}
	}

	info, err := admin.svc.GroupInfo(ctx, key.GroupID)
	if err != nil {
		t.Fatalf("读取群信息: %v", err)
	}
	if info.Title != "研发群" {
		t.Fatalf("群名称 %q，期望去除首尾空白后的 研发群", info.Title)
	}
	if len(info.Members) != 3 {
		t.Fatalf("成员数 %d，期望 3", len(info.Members))
	}
	if info.StorageConfigured {
		t.Fatal("新建群不应预置群盘配置")
	}
	adminCount := 0
	for _, m := range info.Members {
		if m.Role == KeyRoleAdmin {
			adminCount++
			if !bytes.Equal(m.AccountPub, admin.account.Pub()) {
				t.Fatal("管理员应为本机账号")
			}
		}
	}
	if adminCount != 1 {
		t.Fatalf("管理员数量 %d，期望 1", adminCount)
	}

	// 群密钥已落库：全新服务实例加载后可恢复订阅。
	restarted, err := New(Options{
		Host:    admin.host,
		Account: admin.account,
		DAO:     admin.dao,
		Members: MemberFunc(func(context.Context, []byte) ([][]byte, error) {
			return cluster.members, nil
		}),
		XPub: XPubFunc(func(context.Context, []byte) ([]byte, error) {
			return nil, errors.New("不应在恢复阶段解析 XPub")
		}),
		DisableAutoWarmup: true,
	})
	if err != nil {
		t.Fatalf("重建群聊服务: %v", err)
	}
	defer restarted.Close()
	if err := restarted.LoadKeys(ctx); err != nil {
		t.Fatalf("加载群密钥: %v", err)
	}
	if _, _, ok := restarted.keys.Latest(key.GroupID); !ok {
		t.Fatal("重启后密钥环应包含已落库的群密钥")
	}
	n, err := restarted.SubscribeAll(ctx)
	if err != nil {
		t.Fatalf("恢复群订阅: %v", err)
	}
	if n != 1 {
		t.Fatalf("恢复订阅群数量 %d，期望 1", n)
	}
}

// TestCreateGroupRejectsEmptyTitle 校验群名称必填。
func TestCreateGroupRejectsEmptyTitle(t *testing.T) {
	ctx := context.Background()
	mn := mocknet.New()
	defer mn.Close()
	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	node := newKeyTestNode(t, mn, cluster)
	if _, _, err := node.svc.CreateGroup(ctx, "   ", nil); !errors.Is(err, ErrTitleRequired) {
		t.Fatalf("期望 ErrTitleRequired，实际 %v", err)
	}
}

// waitGroupKey 等待成员经后台上报拿到群密钥。
func waitGroupKey(t *testing.T, svc *Service, groupID []byte) []byte {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, key, ok := svc.keys.Latest(groupID); ok {
			return key
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("群 %x 的密钥未在超时内到达", groupID)
	return nil
}
