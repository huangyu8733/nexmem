package group

import (
	"bytes"
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/internal/identity"
)

// TestWarmupConnectsMembersOnJoin 验收 P4-02：新成员入群后 10s 内 mesh 连通。
func TestWarmupConnectsMembersOnJoin(t *testing.T) {
	groupID := []byte("p4-warmup-group")
	mn := mocknet.New()
	defer mn.Close()

	const nodeCount = 3
	accounts := make([]*identity.Account, nodeCount)
	members := make([][]byte, nodeCount)
	nodeHosts := make([]host.Host, nodeCount)
	for i := 0; i < nodeCount; i++ {
		acc, err := identity.GenerateAccount()
		if err != nil {
			t.Fatalf("生成账号 %d: %v", i, err)
		}
		accounts[i] = acc
		members[i] = acc.Pub()
	}
	source := MemberFunc(func(context.Context, []byte) ([][]byte, error) {
		return members, nil
	})

	services := make([]*Service, nodeCount)
	received := make([]atomic.Int32, nodeCount)

	resolver := PeerResolverFunc(func(_ context.Context, accountPub []byte) ([]peer.AddrInfo, error) {
		for j := 0; j < nodeCount; j++ {
			if bytes.Equal(members[j], accountPub) {
				return []peer.AddrInfo{{ID: nodeHosts[j].ID(), Addrs: nodeHosts[j].Addrs()}}, nil
			}
		}
		return nil, errors.New("未知成员")
	})

	for i := 0; i < nodeCount; i++ {
		h, err := mn.GenPeer()
		if err != nil {
			t.Fatalf("创建节点 %d: %v", i, err)
		}
		nodeHosts[i] = h
		opt := Options{
			Host:    h,
			Account: accounts[i],
			Members: source,
		}
		idx := i
		opt.OnMessage = func(Received) { received[idx].Add(1) }
		// 只有新成员（最后一个节点）配置地址解析器，模拟入群后拿到成员地址。
		if i == nodeCount-1 {
			opt.PeerResolver = resolver
		}
		svc, err := New(opt)
		if err != nil {
			t.Fatalf("创建群服务 %d: %v", i, err)
		}
		t.Cleanup(svc.Close)
		services[i] = svc
	}

	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	// 老成员之间先连通，新成员不预连任何人，只靠预热拨号。
	if err := nodeHosts[0].Connect(context.Background(), peer.AddrInfo{
		ID:    nodeHosts[1].ID(),
		Addrs: nodeHosts[1].Addrs(),
	}); err != nil {
		t.Fatalf("连通老成员: %v", err)
	}
	if err := services[0].Subscribe(context.Background(), groupID); err != nil {
		t.Fatalf("订阅老成员 0: %v", err)
	}
	if err := services[1].Subscribe(context.Background(), groupID); err != nil {
		t.Fatalf("订阅老成员 1: %v", err)
	}

	start := time.Now()
	if err := services[2].Subscribe(context.Background(), groupID); err != nil {
		t.Fatalf("新成员订阅: %v", err)
	}

	meshDeadline := start.Add(DefaultWarmupWindow)
	for {
		connected := 0
		for j := 0; j < nodeCount-1; j++ {
			if nodeHosts[2].Network().Connectedness(nodeHosts[j].ID()) == network.Connected {
				connected++
			}
		}
		if connected == nodeCount-1 && services[2].Peers(groupID) > 0 {
			break
		}
		if time.Now().After(meshDeadline) {
			t.Fatalf("新成员未在 %s 内连通 mesh（已连通 %d，mesh 邻居 %d）",
				DefaultWarmupWindow, connected, services[2].Peers(groupID))
		}
		time.Sleep(50 * time.Millisecond)
	}
	if elapsed := time.Since(start); elapsed >= DefaultWarmupWindow {
		t.Fatalf("预热耗时 %s 超出窗口", elapsed)
	}

	report, err := services[2].Warmup(context.Background(), groupID)
	if err != nil {
		t.Fatalf("重复预热报错: %v", err)
	}
	if report.Members != nodeCount || report.Attempted != nodeCount-1 || report.Skipped != 1 {
		t.Fatalf("预热统计异常: %+v", report)
	}
	if report.Connected != nodeCount-1 {
		t.Fatalf("应全部连通，实际 %+v", report)
	}
	if report.Peers == 0 {
		t.Fatal("预热后 mesh 邻居应大于 0")
	}

	// mesh 连通后老成员的消息应送达新成员。
	time.Sleep(2 * time.Second)
	if _, err := services[0].Publish(context.Background(), groupID, []byte("hello"), 1); err != nil {
		t.Fatalf("发布: %v", err)
	}
	msgDeadline := time.Now().Add(15 * time.Second)
	for received[2].Load() == 0 {
		if time.Now().After(msgDeadline) {
			t.Fatal("预热后的群消息未送达新成员")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// TestWarmupWithoutResolver 校验未配置解析器时明确报错且不影响订阅。
func TestWarmupWithoutResolver(t *testing.T) {
	mn := mocknet.New()
	defer mn.Close()
	h, err := mn.GenPeer()
	if err != nil {
		t.Fatal(err)
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	svc, err := New(Options{
		Host:    h,
		Account: acc,
		Members: MemberFunc(func(context.Context, []byte) ([][]byte, error) {
			return [][]byte{acc.Pub()}, nil
		}),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()

	if _, err := svc.Warmup(context.Background(), []byte("g")); !errors.Is(err, ErrNoPeerResolver) {
		t.Fatalf("未配置解析器应返回 ErrNoPeerResolver，实际 %v", err)
	}
	if _, err := svc.Warmup(context.Background(), nil); !errors.Is(err, ErrGroupIDRequired) {
		t.Fatalf("空群 ID 应返回 ErrGroupIDRequired，实际 %v", err)
	}
	if err := svc.Subscribe(context.Background(), []byte("g")); err != nil {
		t.Fatalf("未配置解析器不应阻止订阅: %v", err)
	}
}

// TestWarmupRetriesUntilReachable 校验对端暂时解析失败时会按间隔重试。
func TestWarmupRetriesUntilReachable(t *testing.T) {
	groupID := []byte("p4-warmup-retry")
	mn := mocknet.New()
	defer mn.Close()

	accA, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	accB, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	members := [][]byte{accA.Pub(), accB.Pub()}
	source := MemberFunc(func(context.Context, []byte) ([][]byte, error) {
		return members, nil
	})

	hA, err := mn.GenPeer()
	if err != nil {
		t.Fatal(err)
	}
	hB, err := mn.GenPeer()
	if err != nil {
		t.Fatal(err)
	}
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}

	svcA, err := New(Options{Host: hA, Account: accA, Members: source})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(svcA.Close)
	if err := svcA.Subscribe(context.Background(), groupID); err != nil {
		t.Fatal(err)
	}

	var calls atomic.Int32
	resolver := PeerResolverFunc(func(_ context.Context, accountPub []byte) ([]peer.AddrInfo, error) {
		if !bytes.Equal(accountPub, accA.Pub()) {
			return nil, errors.New("未知成员")
		}
		if calls.Add(1) < 3 {
			return nil, errors.New("索引服务暂不可用")
		}
		return []peer.AddrInfo{{ID: hA.ID(), Addrs: hA.Addrs()}}, nil
	})

	svcB, err := New(Options{
		Host:           hB,
		Account:        accB,
		Members:        source,
		PeerResolver:   resolver,
		WarmupInterval: 100 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(svcB.Close)

	start := time.Now()
	if err := svcB.Subscribe(context.Background(), groupID); err != nil {
		t.Fatal(err)
	}
	deadline := start.Add(DefaultWarmupWindow)
	for svcB.Peers(groupID) == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("重试预热未在窗口内连通 mesh（解析调用 %d 次）", calls.Load())
		}
		time.Sleep(50 * time.Millisecond)
	}
	if calls.Load() < 3 {
		t.Fatalf("应至少重试到第 3 次，实际 %d 次", calls.Load())
	}
}
