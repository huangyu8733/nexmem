package relay

import (
	"sync"
	"testing"
	"time"

	pbv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/pb"
	ma "github.com/multiformats/go-multiaddr"
)

// fakeClock 是可手动推进的测试时钟。
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

func TestGuardAlertThresholdsOncePerWindow(t *testing.T) {
	clock := newFakeClock()
	var alerts []Alert
	g := New(Config{
		BandwidthLimit: 1000,
		Window:         time.Hour,
		WarnRatio:      0.8,
		Now:            clock.Now,
		OnAlert:        func(a Alert) { alerts = append(alerts, a) },
	})

	g.BytesTransferred(100)
	if len(alerts) != 0 {
		t.Fatalf("未达告警阈值不应告警，实际 %d 条", len(alerts))
	}
	g.BytesTransferred(700) // 800 达到 0.8 告警线
	if len(alerts) != 1 || alerts[0].Level != AlertWarn {
		t.Fatalf("应产生 1 条 warn 告警，实际 %+v", alerts)
	}
	g.BytesTransferred(100) // 900 仍在告警区间，不重复告警
	if len(alerts) != 1 {
		t.Fatalf("同一窗口 warn 只应告警一次，实际 %d 条", len(alerts))
	}
	g.BytesTransferred(100) // 1000 超限
	if len(alerts) != 2 || alerts[1].Level != AlertExceeded {
		t.Fatalf("应产生 exceeded 告警，实际 %+v", alerts)
	}
	g.BytesTransferred(500) // 仍超限，不重复告警
	if len(alerts) != 2 {
		t.Fatalf("同一窗口 exceeded 只应告警一次，实际 %d 条", len(alerts))
	}

	st := g.Stats()
	if !st.Exceeded || st.Used != 1500 || st.Total != 1500 {
		t.Fatalf("超限后统计不符: %+v", st)
	}

	// 跨窗口后用量与告警状态复位。
	clock.Advance(time.Hour + time.Second)
	st = g.Stats()
	if st.Exceeded || st.Warned || st.Used != 0 {
		t.Fatalf("跨窗口应重置用量与告警状态，实际 %+v", st)
	}
	if !st.WindowStart.Equal(clock.Now().Truncate(time.Hour)) {
		t.Fatalf("窗口起点未对齐: %s", st.WindowStart)
	}
	g.BytesTransferred(800)
	if len(alerts) != 3 || alerts[2].Level != AlertWarn {
		t.Fatalf("新窗口应重新告警，实际 %+v", alerts)
	}
}

func TestGuardRejectsReserveAndConnectWhenExceeded(t *testing.T) {
	clock := newFakeClock()
	g := New(Config{BandwidthLimit: 100, Window: time.Hour, Now: clock.Now})

	addr, err := ma.NewMultiaddr("/ip4/127.0.0.1/tcp/4001")
	if err != nil {
		t.Fatal(err)
	}
	if !g.AllowReserve("peer-a", addr) {
		t.Fatal("未超限时应允许预约")
	}
	if !g.AllowConnect("peer-a", addr, "peer-b") {
		t.Fatal("未超限时应允许中继连接")
	}

	g.BytesTransferred(100)
	if g.AllowReserve("peer-c", addr) {
		t.Fatal("超限后必须拒绝新预约")
	}
	if g.AllowConnect("peer-c", addr, "peer-d") {
		t.Fatal("超限后必须拒绝新的中继连接")
	}

	st := g.Stats()
	if st.DeniedReserves != 1 || st.DeniedConnects != 1 {
		t.Fatalf("拒绝计数不符: %+v", st)
	}
	if st.ReserveRequests != 2 || st.ConnectRequests != 2 {
		t.Fatalf("请求计数不符: %+v", st)
	}
}

func TestGuardUnlimitedNeverRejects(t *testing.T) {
	clock := newFakeClock()
	alerts := 0
	g := New(Config{BandwidthLimit: 0, Now: clock.Now, OnAlert: func(Alert) { alerts++ }})
	addr, _ := ma.NewMultiaddr("/ip4/127.0.0.1/tcp/4001")

	g.BytesTransferred(1 << 30)
	if alerts != 0 {
		t.Fatalf("不限额时不应告警，实际 %d 条", alerts)
	}
	if !g.AllowReserve("peer-a", addr) || !g.AllowConnect("peer-a", addr, "peer-b") {
		t.Fatal("不限额时必须始终放行")
	}
	if st := g.Stats(); st.Total != 1<<30 || st.Used != 0 {
		t.Fatalf("不限额统计不符: %+v", st)
	}
}

func TestGuardTracksReservationsAndCircuits(t *testing.T) {
	g := New(Config{BandwidthLimit: 1000})

	g.RelayStatus(true)
	g.ReservationAllowed(false)
	g.ReservationAllowed(false)
	g.ReservationAllowed(true) // 续约不新增
	g.ReservationClosed(1)
	g.ConnectionOpened()
	g.ConnectionOpened()
	g.ConnectionClosed(time.Second)
	g.ConnectionRequestHandled(pbv2.Status_OK)
	g.ReservationRequestHandled(pbv2.Status_OK)

	st := g.Stats()
	if st.Reservations != 1 || st.Circuits != 1 || !st.ServiceActivated {
		t.Fatalf("预约/连接跟踪不符: %+v", st)
	}
}

func TestGuardConcurrentTransfers(t *testing.T) {
	g := New(Config{BandwidthLimit: 1 << 20, OnAlert: func(Alert) {}})

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 500; j++ {
				g.BytesTransferred(10)
			}
		}()
	}
	wg.Wait()

	st := g.Stats()
	if st.Used != 40000 || st.Total != 40000 {
		t.Fatalf("并发累计不符: %+v", st)
	}
}

func TestGuardOptionsIncludeACLAndTracer(t *testing.T) {
	g := New(Config{BandwidthLimit: 1})
	if opts := g.Options(); len(opts) != 2 {
		t.Fatalf("应返回 ACL 与指标采集 2 个选项，实际 %d", len(opts))
	}
}
