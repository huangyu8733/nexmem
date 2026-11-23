package netnode

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/peerstore"
	"github.com/libp2p/go-libp2p/core/protocol"
	"github.com/multiformats/go-multiaddr"

	nrelay "github.com/nexmem/core/server/relay"
)

// relayCircuitAddr 用中继节点的真实监听地址拼出指向 target 的 circuit 地址。
func relayCircuitAddr(t *testing.T, relayHost host.Host, target peer.ID) multiaddr.Multiaddr {
	t.Helper()
	for _, a := range relayHost.Addrs() {
		if !strings.Contains(a.String(), "/tcp/") {
			continue
		}
		circ, err := multiaddr.NewMultiaddr(a.String() + "/p2p/" + relayHost.ID().String() + "/p2p-circuit/p2p/" + target.String())
		if err == nil {
			return circ
		}
	}
	t.Fatal("无法构造中继 circuit 地址")
	return nil
}

// TestRelayServicePolicyQuotaOptions 校验配置带宽上限后会追加 ACL 与指标采集选项。
func TestRelayServicePolicyQuotaOptions(t *testing.T) {
	opts := (RelayServicePolicy{Enabled: true, BandwidthLimit: 1 << 20}).options()
	if len(opts) != 3 {
		t.Fatalf("含带宽限额的选项数 = %d，期望 3（资源 + ACL + 指标）", len(opts))
	}
	if (RelayServicePolicy{Enabled: true}).QuotaGuard() != nil {
		t.Fatal("未配置带宽上限时不应创建限额守卫")
	}
	if (RelayServicePolicy{Enabled: true, BandwidthLimit: 1}).QuotaGuard() == nil {
		t.Fatal("配置带宽上限后应创建限额守卫")
	}
}

// TestRelayQuotaRejectsNewReservation 端到端验证：真实中继转发流量超过单节点
// 带宽上限并触发 exceeded 告警后，新客户端的预约被拒绝。
func TestRelayQuotaRejectsNewReservation(t *testing.T) {
	if testing.Short() {
		t.Skip("中继限额验收依赖真实监听端口与中继流量，跳过 short 模式")
	}

	const limit = 8 << 10 // 8 KiB / 小时
	alerts := make(chan nrelay.Alert, 16)
	relayHost := newTestHost(t, "relay-quota", Config{
		RelayService: RelayServicePolicy{
			Enabled:            true,
			AllowPrivate:       true,
			BandwidthLimit:     limit,
			BandwidthWindow:    time.Hour,
			BandwidthWarnRatio: 0.5,
			OnAlert: func(a nrelay.Alert) {
				select {
				case alerts <- a:
				default:
				}
			},
		},
		ForcePublic: true,
	})
	relay := withPublicAddr(t, relayAddrInfo(t, relayHost))

	// A 先完成预约，并在中继通道上提供回显服务。
	clientA := newTestHost(t, "quota-a", Config{
		Relay: RelayPolicy{Enabled: true, Relays: []peer.AddrInfo{relay}, ForcePrivate: true},
	})
	ctxA, cancelA := context.WithTimeout(context.Background(), RelayReservationDeadline)
	defer cancelA()
	if _, err := WaitRelayReservation(ctxA, clientA, RelayReservationDeadline); err != nil {
		t.Fatalf("首台客户端未完成预约: %v", err)
	}

	pid := protocol.ID("/nexmem/relay-quota-test/1.0.0")
	clientA.SetStreamHandler(pid, func(s network.Stream) {
		defer s.Close()
		_, _ = io.Copy(s, s)
	})

	// B 经中继 circuit 与 A 建流并传输 16 KiB，双向流量超过限额。
	clientB := newTestHost(t, "quota-b", Config{Relay: RelayPolicy{Enabled: true}})
	clientB.Peerstore().AddAddr(clientA.ID(), relayCircuitAddr(t, relayHost, clientA.ID()), peerstore.TempAddrTTL)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// 中继连接的 Connectedness 为 Limited，开流需显式允许。
	stream, err := clientB.NewStream(network.WithAllowLimitedConn(ctx, "relay-quota-test"), clientA.ID(), pid)
	if err != nil {
		t.Fatalf("经中继建立流失败: %v", err)
	}
	payload := make([]byte, 16<<10)
	if _, err := stream.Write(payload); err != nil {
		t.Fatalf("经中继写入失败: %v", err)
	}
	echo := make([]byte, len(payload))
	if _, err := io.ReadFull(stream, echo); err != nil {
		t.Fatalf("经中继回显读取失败: %v", err)
	}
	_ = stream.Close()

	// 等待中继侧累计流量触发 exceeded 告警。
	sawWarn := false
	sawExceeded := false
	for !sawExceeded {
		select {
		case a := <-alerts:
			if a.Level == nrelay.AlertWarn {
				sawWarn = true
			}
			if a.Level == nrelay.AlertExceeded {
				sawExceeded = true
				if a.Used < limit || a.Limit != limit {
					t.Fatalf("超限告警用量不符: %+v", a)
				}
			}
		case <-time.After(15 * time.Second):
			t.Fatal("中继转发超过上限后未收到 exceeded 告警")
		}
	}
	if !sawWarn {
		t.Log("未观察到 warn 告警（短流量可能直接跨过告警线）")
	}

	// C 在超限后发起预约，必须被拒绝。
	clientC := newTestHost(t, "quota-c", Config{
		Relay: RelayPolicy{Enabled: true, Relays: []peer.AddrInfo{relay}, ForcePrivate: true},
	})
	start := time.Now()
	ctxC, cancelC := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancelC()
	addrs, err := WaitRelayReservation(ctxC, clientC, 3*time.Second)
	if err == nil {
		t.Fatalf("超限后新预约应被拒绝，实际得到 %v", addrs)
	}
	if !errors.Is(err, ErrRelayReservationTimeout) && !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("预期预约超时，实际 error = %v", err)
	}
	if HasRelayReservation(clientC) {
		t.Fatal("超限后不应产生中继地址")
	}
	t.Logf("超限后预约被拒绝，耗时 %s，error=%v", time.Since(start), err)
}
