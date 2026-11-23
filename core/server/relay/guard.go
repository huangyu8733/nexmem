// Package relay 为自建与官方兜底 Circuit Relay v2 节点提供单节点带宽限额与告警。
//
// Guard 同时实现 relay.ACLFilter 与 relay.MetricsTracer：
// 通过 MetricsTracer 采集中继转发字节数，按固定窗口累计；达到告警比例时上报
// 一次 warn 告警，达到上限后置为超限状态，并在 ACL 中拒绝新的预约与中继连接。
package relay

import (
	"sync"
	"time"

	"github.com/libp2p/go-libp2p/core/peer"
	pbv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/pb"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	ma "github.com/multiformats/go-multiaddr"
)

const (
	// DefaultWindow 是默认的带宽统计窗口。
	DefaultWindow = time.Hour
	// DefaultWarnRatio 是默认的告警阈值比例。
	DefaultWarnRatio = 0.8
)

// AlertLevel 表示告警级别。
type AlertLevel int

const (
	// AlertWarn 表示用量达到告警比例，尚未超限。
	AlertWarn AlertLevel = iota + 1
	// AlertExceeded 表示用量达到或超过上限，新预约将被拒绝。
	AlertExceeded
)

// String 返回告警级别的稳定字符串。
func (l AlertLevel) String() string {
	switch l {
	case AlertWarn:
		return "warn"
	case AlertExceeded:
		return "exceeded"
	default:
		return "unknown"
	}
}

// Alert 是一次限额告警。同一窗口内每个级别最多上报一次。
type Alert struct {
	Level        AlertLevel
	Used         int64
	Limit        int64
	WindowStart  time.Time
	Reservations int
	Circuits     int
	Time         time.Time
}

// Config 是 Guard 的配置。
type Config struct {
	// BandwidthLimit 是单节点每个窗口允许转发的字节上限；<=0 表示不限额。
	BandwidthLimit int64
	// Window 是统计窗口，<=0 时取 DefaultWindow。
	Window time.Duration
	// WarnRatio 是告警阈值比例，须在 (0,1) 内，否则取 DefaultWarnRatio。
	WarnRatio float64
	// Now 便于测试注入时钟，为 nil 时使用 time.Now。
	Now func() time.Time
	// OnAlert 接收告警回调；回调不持有 Guard 内部锁，可安全调用 Stats。
	OnAlert func(Alert)
}

// Stats 是 Guard 的即时快照。
type Stats struct {
	BandwidthLimit   int64
	Window           time.Duration
	WindowStart      time.Time
	Used             int64
	Total            int64
	Warned           bool
	Exceeded         bool
	Reservations     int
	Circuits         int
	ReserveRequests  uint64
	ConnectRequests  uint64
	DeniedReserves   uint64
	DeniedConnects   uint64
	ServiceActivated bool
}

// Guard 采集中继转发流量并在超限后拒绝新的预约与中继连接。
type Guard struct {
	limit     int64
	window    time.Duration
	warnRatio float64
	now       func() time.Time
	onAlert   func(Alert)

	mu               sync.Mutex
	windowStart      time.Time
	used             int64
	total            int64
	warned           bool
	exceeded         bool
	reservations     int
	circuits         int
	reserveRequests  uint64
	connectRequests  uint64
	deniedReserves   uint64
	deniedConnects   uint64
	serviceActivated bool
}

// New 按配置创建 Guard。
func New(cfg Config) *Guard {
	if cfg.Window <= 0 {
		cfg.Window = DefaultWindow
	}
	if cfg.WarnRatio <= 0 || cfg.WarnRatio >= 1 {
		cfg.WarnRatio = DefaultWarnRatio
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	g := &Guard{
		limit:     cfg.BandwidthLimit,
		window:    cfg.Window,
		warnRatio: cfg.WarnRatio,
		now:       cfg.Now,
		onAlert:   cfg.OnAlert,
	}
	g.windowStart = cfg.Now()
	return g
}

// Options 返回中继服务所需的 ACL 与指标采集选项。
func (g *Guard) Options() []relayv2.Option {
	return []relayv2.Option{
		relayv2.WithACL(g),
		relayv2.WithMetricsTracer(g),
	}
}

// AllowReserve 在超限后拒绝新的预约（含续约）。
func (g *Guard) AllowReserve(p peer.ID, a ma.Multiaddr) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.rollLocked(g.now())
	g.reserveRequests++
	if g.limit > 0 && g.exceeded {
		g.deniedReserves++
		return false
	}
	return true
}

// AllowConnect 在超限后拒绝新的中继连接。
func (g *Guard) AllowConnect(src peer.ID, srcAddr ma.Multiaddr, dest peer.ID) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.rollLocked(g.now())
	g.connectRequests++
	if g.limit > 0 && g.exceeded {
		g.deniedConnects++
		return false
	}
	return true
}

// BytesTransferred 由中继服务在每次转发数据后回调。
func (g *Guard) BytesTransferred(cnt int) {
	if cnt <= 0 {
		return
	}
	g.mu.Lock()
	now := g.now()
	g.rollLocked(now)
	g.total += int64(cnt)
	var alert *Alert
	if g.limit > 0 {
		g.used += int64(cnt)
		if g.used >= g.limit {
			if !g.exceeded {
				g.exceeded = true
				alert = g.newAlertLocked(AlertExceeded, now)
			}
		} else if !g.warned && float64(g.used) >= g.warnRatio*float64(g.limit) {
			g.warned = true
			alert = g.newAlertLocked(AlertWarn, now)
		}
	}
	cb := g.onAlert
	g.mu.Unlock()
	if alert != nil && cb != nil {
		cb(*alert)
	}
}

// ReservationAllowed 跟踪当前预约数；续约不计新增。
func (g *Guard) ReservationAllowed(isRenewal bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !isRenewal {
		g.reservations++
	}
}

// ReservationClosed 跟踪过期或撤销的预约数。
func (g *Guard) ReservationClosed(cnt int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.reservations -= cnt
	if g.reservations < 0 {
		g.reservations = 0
	}
}

// ConnectionOpened 跟踪活跃中继连接数。
func (g *Guard) ConnectionOpened() {
	g.mu.Lock()
	g.circuits++
	g.mu.Unlock()
}

// ConnectionClosed 跟踪活跃中继连接数。
func (g *Guard) ConnectionClosed(d time.Duration) {
	g.mu.Lock()
	if g.circuits > 0 {
		g.circuits--
	}
	g.mu.Unlock()
}

// ConnectionRequestHandled 仅用于实现 MetricsTracer。
func (g *Guard) ConnectionRequestHandled(status pbv2.Status) {}

// ReservationRequestHandled 仅用于实现 MetricsTracer。
func (g *Guard) ReservationRequestHandled(status pbv2.Status) {}

// RelayStatus 记录中继服务是否已激活。
func (g *Guard) RelayStatus(enabled bool) {
	g.mu.Lock()
	g.serviceActivated = enabled
	g.mu.Unlock()
}

// Stats 返回当前用量快照。
func (g *Guard) Stats() Stats {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.rollLocked(g.now())
	return Stats{
		BandwidthLimit:   g.limit,
		Window:           g.window,
		WindowStart:      g.windowStart,
		Used:             g.used,
		Total:            g.total,
		Warned:           g.warned,
		Exceeded:         g.exceeded,
		Reservations:     g.reservations,
		Circuits:         g.circuits,
		ReserveRequests:  g.reserveRequests,
		ConnectRequests:  g.connectRequests,
		DeniedReserves:   g.deniedReserves,
		DeniedConnects:   g.deniedConnects,
		ServiceActivated: g.serviceActivated,
	}
}

// rollLocked 在跨窗口时重置用量与告警状态。
func (g *Guard) rollLocked(now time.Time) {
	if now.Before(g.windowStart.Add(g.window)) {
		return
	}
	windows := now.Sub(g.windowStart) / g.window
	g.windowStart = g.windowStart.Add(windows * g.window)
	g.used = 0
	g.warned = false
	g.exceeded = false
}

func (g *Guard) newAlertLocked(level AlertLevel, now time.Time) *Alert {
	return &Alert{
		Level:        level,
		Used:         g.used,
		Limit:        g.limit,
		WindowStart:  g.windowStart,
		Reservations: g.reservations,
		Circuits:     g.circuits,
		Time:         now,
	}
}
