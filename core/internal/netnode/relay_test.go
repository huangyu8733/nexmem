package netnode

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
)

// newTestHost 创建仅监听环回 TCP 的测试 host。
func newTestHost(t *testing.T, tag string, cfg Config) host.Host {
	t.Helper()
	priv, err := LoadOrCreateKey(filepath.Join(t.TempDir(), tag+".key"))
	if err != nil {
		t.Fatalf("%s 生成设备密钥: %v", tag, err)
	}
	cfg.PrivateKey = priv
	cfg.Listen = []string{"/ip4/127.0.0.1/tcp/0"}
	if cfg.UserAgent == "" {
		cfg.UserAgent = "nexmem-relay-test/0.1.0"
	}
	h, err := NewHost(context.Background(), cfg)
	if err != nil {
		t.Fatalf("%s 启动 host: %v", tag, err)
	}
	t.Cleanup(func() { h.Close() })
	return h
}

func relayAddrInfo(t *testing.T, h host.Host) peer.AddrInfo {
	t.Helper()
	ai := peer.AddrInfo{ID: h.ID()}
	ai.Addrs = append(ai.Addrs, h.Addrs()...)
	if len(ai.Addrs) == 0 {
		t.Fatalf("中继节点没有监听地址")
	}
	return ai
}

// withPublicAddr 为中继候选附加一个公网地址。
// AutoRelay 只把中继的公网地址拼进 p2p-circuit 地址，本地环回中继自身
// 不会出现在宣告地址里；附加公网地址用于在本地验证「预约完成」的可观测信号。
func withPublicAddr(t *testing.T, ai peer.AddrInfo) peer.AddrInfo {
	t.Helper()
	public, err := multiaddr.NewMultiaddr("/ip4/8.8.8.8/tcp/4001")
	if err != nil {
		t.Fatalf("构造公网中继地址: %v", err)
	}
	ai.Addrs = append(ai.Addrs, public)
	return ai
}

// waitAdvertised 等待 host 把中继地址合并进对外地址。
func waitAdvertised(h host.Host, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if HasRelayReservation(h) {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return HasRelayReservation(h)
}

func TestRelayPolicyDefaultsDisabled(t *testing.T) {
	var policy RelayPolicy
	if opts := policy.hostOptions(); len(opts) != 0 {
		t.Fatalf("默认策略应关闭，实际选项数 = %d", len(opts))
	}

	// 即使携带候选，未显式开启也不产生任何中继选项。
	relay := peer.AddrInfo{ID: peer.ID("12D3KooWTest")}
	if opts := (RelayPolicy{Relays: []peer.AddrInfo{relay}}).hostOptions(); len(opts) != 0 {
		t.Fatalf("未开启的候选策略应被忽略，实际选项数 = %d", len(opts))
	}

	// 开启但无候选时只保留中继传输能力。
	if opts := (RelayPolicy{Enabled: true}).hostOptions(); len(opts) != 1 {
		t.Fatalf("无候选时应只有 1 个选项，实际 = %d", len(opts))
	}

	norm := (RelayPolicy{Enabled: true, Relays: []peer.AddrInfo{relay}}).normalized()
	if norm.NumRelays != 1 {
		t.Fatalf("NumRelays 默认应取候选数，实际 = %d", norm.NumRelays)
	}
	if norm.BootDelay != DefaultRelayBootDelay || norm.Backoff != DefaultRelayBackoff {
		t.Fatalf("默认等待/退避未填充: %+v", norm)
	}
}

func TestRelayServicePolicyDefaultsDisabled(t *testing.T) {
	if (RelayServicePolicy{}).Enabled {
		t.Fatal("中继服务默认必须关闭")
	}
	if opts := (RelayServicePolicy{}).options(); len(opts) != 1 {
		t.Fatalf("默认资源选项数 = %d，期望 1", len(opts))
	}
	// 自定义限额与 AllowPrivate 会追加选项。
	opts := (RelayServicePolicy{
		Enabled:            true,
		AllowPrivate:       true,
		ReservationTTL:     time.Minute,
		MaxReservations:    8,
		MaxCircuits:        2,
		MaxCircuitDuration: time.Second,
		MaxCircuitData:     1024,
	}).options()
	if len(opts) != 2 {
		t.Fatalf("含 AllowPrivate 的选项数 = %d，期望 2", len(opts))
	}
}

func TestAutoRelayReservationWithinDeadline(t *testing.T) {
	if testing.Short() {
		t.Skip("中继预约依赖真实监听端口，跳过 short 模式")
	}

	relayHost := newTestHost(t, "relay", Config{
		RelayService: RelayServicePolicy{Enabled: true, AllowPrivate: true},
		ForcePublic:  true,
	})
	relay := withPublicAddr(t, relayAddrInfo(t, relayHost))

	client := newTestHost(t, "client", Config{
		Relay: RelayPolicy{Enabled: true, Relays: []peer.AddrInfo{relay}, ForcePrivate: true},
	})

	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), RelayReservationDeadline)
	defer cancel()

	addrs, err := WaitRelayReservation(ctx, client, RelayReservationDeadline)
	if err != nil {
		t.Fatalf("开启中继后未在 %s 内完成预约: %v", RelayReservationDeadline, err)
	}
	elapsed := time.Since(start)
	if elapsed > RelayReservationDeadline {
		t.Fatalf("预约耗时 %s 超过验收时限 %s", elapsed, RelayReservationDeadline)
	}
	if !waitAdvertised(client, 2*time.Second) {
		t.Fatal("预约完成后 host 未宣告中继地址")
	}

	want := "/p2p/" + relay.ID.String() + "/p2p-circuit"
	for _, addr := range addrs {
		if strings.Contains(addr, want) {
			t.Logf("预约完成，耗时 %s，中继地址 %s", elapsed, addr)
			return
		}
	}
	t.Fatalf("中继地址未包含 %s: %v", want, addrs)
}

func TestRelayReservationTimeoutWhenDisabled(t *testing.T) {
	relayHost := newTestHost(t, "relay", Config{
		RelayService: RelayServicePolicy{Enabled: true, AllowPrivate: true},
		ForcePublic:  true,
	})
	_ = relayAddrInfo(t, relayHost)

	// 策略关闭时不消费候选，也不会产生预约。
	client := newTestHost(t, "client-off", Config{})

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, err := WaitRelayReservation(ctx, client, 500*time.Millisecond)
	if !errors.Is(err, ErrRelayReservationTimeout) {
		t.Fatalf("关闭状态下应预约超时，实际 error = %v", err)
	}
	if HasRelayReservation(client) {
		t.Fatal("关闭状态下不应产生中继地址")
	}
	if got := RelayAddrs(client); len(got) != 0 {
		t.Fatalf("关闭状态下中继地址应为空，实际 %v", got)
	}
}
