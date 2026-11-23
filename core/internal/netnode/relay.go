package netnode

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/event"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/host/autorelay"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/multiformats/go-multiaddr"

	nrelay "github.com/nexmem/core/server/relay"
)

const (
	// RelayReservationDeadline 是「开启中继后完成预约」的验收时限。
	RelayReservationDeadline = 30 * time.Second
	// DefaultRelayBootDelay 是候选中继不足时的等待上限；配合静态候选可保证
	// 开启后远早于 RelayReservationDeadline 完成预约。
	DefaultRelayBootDelay = 10 * time.Second
	// DefaultRelayBackoff 是单个中继预约失败后的退避时间。
	DefaultRelayBackoff = time.Minute
)

// ErrRelayReservationTimeout 表示在时限内没有拿到任何中继预约。
var ErrRelayReservationTimeout = errors.New("中继预约超时")

// RelayPolicy 描述中继客户端与 AutoRelay 策略。零值表示关闭（项目默认）。
//
// 关闭时不启用 Relay 客户端、不消费任何中继候选，也不会改写对外地址；
// 开启后由 AutoRelay 在探测到非公网可达时向 Relays 预约中继槽位。
type RelayPolicy struct {
	// Enabled 控制中继能力总开关，默认 false。
	Enabled bool
	// Relays 是中继候选，来自自建中继或官方兜底列表。
	Relays []peer.AddrInfo
	// NumRelays 是期望达成的预约数；<=0 时取候选数。
	NumRelays int
	// BootDelay 是候选不足时的等待上限，<=0 时取 DefaultRelayBootDelay。
	BootDelay time.Duration
	// Backoff 是预约失败后的退避，<=0 时取 DefaultRelayBackoff。
	Backoff time.Duration
	// ForcePrivate 强制本机视为 NAT 后的私网节点，使 AutoRelay 立即启动预约。
	// 仅用于本地联调与无 AutoNAT 探测条件的环境，生产环境应保持 false。
	ForcePrivate bool
}

// normalized 返回填充默认值并裁剪候选数后的策略副本。
func (p RelayPolicy) normalized() RelayPolicy {
	if p.BootDelay <= 0 {
		p.BootDelay = DefaultRelayBootDelay
	}
	if p.Backoff <= 0 {
		p.Backoff = DefaultRelayBackoff
	}
	if p.NumRelays <= 0 || p.NumRelays > len(p.Relays) {
		p.NumRelays = len(p.Relays)
	}
	return p
}

// hostOptions 把中继策略翻译为 libp2p 选项。关闭时返回空列表。
func (p RelayPolicy) hostOptions() []libp2p.Option {
	if !p.Enabled {
		return nil
	}
	p = p.normalized()
	// Relay 传输默认开启，这里显式打开客户端能力，避免上游默认值变化影响语义。
	opts := []libp2p.Option{libp2p.EnableRelay()}
	if p.ForcePrivate {
		opts = append(opts, libp2p.ForceReachabilityPrivate())
	}
	if len(p.Relays) == 0 {
		// 没有候选时只保留中继传输能力，等运行期由上层补充候选。
		return opts
	}
	autoOpts := []autorelay.Option{
		autorelay.WithBootDelay(p.BootDelay),
		autorelay.WithBackoff(p.Backoff),
		autorelay.WithNumRelays(p.NumRelays),
	}
	opts = append(opts, libp2p.EnableAutoRelayWithStaticRelays(p.Relays, autoOpts...))
	return opts
}

// RelayServicePolicy 描述中继服务开关与资源限额。零值表示关闭（项目默认）。
type RelayServicePolicy struct {
	// Enabled 控制是否对外提供 Circuit Relay v2 服务，默认 false。
	Enabled bool
	// AllowPrivate 允许为内网地址的节点保留槽位，仅用于本地联调。
	AllowPrivate bool
	// ReservationTTL 是预约有效期，<=0 时使用 libp2p 默认值（1h）。
	ReservationTTL time.Duration
	// MaxReservations 是并发预约上限，<=0 时使用 libp2p 默认值（128）。
	MaxReservations int
	// MaxCircuits 是单 peer 并发中继连接上限，<=0 时使用 libp2p 默认值（16）。
	MaxCircuits int
	// MaxCircuitDuration 是单条中继连接的时长上限，<=0 时使用默认值（2m）。
	MaxCircuitDuration time.Duration
	// MaxCircuitData 是单条中继连接单向流量上限，<=0 时使用默认值（128KB）。
	MaxCircuitData int64
	// BandwidthLimit 是单节点每个统计窗口内的转发字节上限，<=0 表示不限额。
	BandwidthLimit int64
	// BandwidthWindow 是带宽统计窗口，<=0 时取 relay.DefaultWindow（1h）。
	BandwidthWindow time.Duration
	// BandwidthWarnRatio 是告警阈值比例，须在 (0,1) 内，默认 0.8。
	BandwidthWarnRatio float64
	// OnAlert 接收带宽限额告警；回调可能来自任意中继 goroutine，须立即返回。
	OnAlert func(nrelay.Alert)
}

// QuotaGuard 按策略中的带宽配置创建限额守卫；未配置带宽上限时返回 nil。
func (p RelayServicePolicy) QuotaGuard() *nrelay.Guard {
	if p.BandwidthLimit <= 0 {
		return nil
	}
	return nrelay.New(nrelay.Config{
		BandwidthLimit: p.BandwidthLimit,
		Window:         p.BandwidthWindow,
		WarnRatio:      p.BandwidthWarnRatio,
		OnAlert:        p.OnAlert,
	})
}

// options 把中继服务策略翻译为 relayv2 选项。
func (p RelayServicePolicy) options() []relayv2.Option {
	res := relayv2.DefaultResources()
	if p.ReservationTTL > 0 {
		res.ReservationTTL = p.ReservationTTL
	}
	if p.MaxReservations > 0 {
		res.MaxReservations = p.MaxReservations
	}
	if p.MaxCircuits > 0 {
		res.MaxCircuits = p.MaxCircuits
	}
	if res.Limit == nil {
		res.Limit = relayv2.DefaultLimit()
	}
	if p.MaxCircuitDuration > 0 {
		res.Limit.Duration = p.MaxCircuitDuration
	}
	if p.MaxCircuitData > 0 {
		res.Limit.Data = p.MaxCircuitData
	}

	opts := []relayv2.Option{relayv2.WithResources(res)}
	if p.AllowPrivate {
		opts = append(opts, relayv2.WithReservationAddressFilter(
			func(multiaddr.Multiaddr) bool { return true },
		))
	}
	if guard := p.QuotaGuard(); guard != nil {
		opts = append(opts, guard.Options()...)
	}
	return opts
}

// RelayAddrs 返回 host 当前已预约的中继地址（含 p2p-circuit），按字符串排序。
func RelayAddrs(h host.Host) []string {
	var out []string
	for _, ma := range h.Addrs() {
		if hasProtocolName(ma, "p2p-circuit") {
			out = append(out, ma.String())
		}
	}
	sort.Strings(out)
	return out
}

// HasRelayReservation 判断 host 是否已完成至少一次中继预约。
func HasRelayReservation(h host.Host) bool {
	return len(RelayAddrs(h)) > 0
}

// WaitRelayReservation 在 timeout 内等待 AutoRelay 完成首次预约。
// timeout<=0 时使用 RelayReservationDeadline。返回预约到的中继地址。
func WaitRelayReservation(ctx context.Context, h host.Host, timeout time.Duration) ([]string, error) {
	if timeout <= 0 {
		timeout = RelayReservationDeadline
	}
	if addrs := RelayAddrs(h); len(addrs) > 0 {
		return addrs, nil
	}

	// AutoRelay 使用有状态 emitter，晚订阅也能拿到最近一次地址更新。
	sub, err := h.EventBus().Subscribe(new(event.EvtAutoRelayAddrsUpdated))
	if err != nil {
		return nil, fmt.Errorf("订阅 AutoRelay 地址事件: %w", err)
	}
	defer sub.Close()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
			if addrs := RelayAddrs(h); len(addrs) > 0 {
				return addrs, nil
			}
			return nil, ErrRelayReservationTimeout
		case e, ok := <-sub.Out():
			if !ok {
				return nil, ErrRelayReservationTimeout
			}
			evt, ok := e.(event.EvtAutoRelayAddrsUpdated)
			if !ok || len(evt.RelayAddrs) == 0 {
				continue
			}
			addrs := make([]string, 0, len(evt.RelayAddrs))
			for _, ma := range evt.RelayAddrs {
				addrs = append(addrs, ma.String())
			}
			sort.Strings(addrs)
			return addrs, nil
		}
	}
}
