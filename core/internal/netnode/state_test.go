package netnode

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/peer"
)

// switchProbe 是可在测试中切换结果的探测函数。
type switchProbe struct {
	ok    atomic.Bool
	calls atomic.Int64
}

func (p *switchProbe) probe(ctx context.Context) error {
	p.calls.Add(1)
	if err := ctx.Err(); err != nil {
		return err
	}
	if !p.ok.Load() {
		return ErrNoReachablePeer
	}
	return nil
}

func waitState(t *testing.T, m *StateMachine, want State, timeout time.Duration) time.Duration {
	t.Helper()
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if err := m.WaitState(ctx, want); err != nil {
		t.Fatalf("等待状态 %s 超时（当前 %s）: %v", want, m.State(), err)
	}
	return time.Since(start)
}

func TestStateMachineDefaultTimingsMatchAcceptance(t *testing.T) {
	if got := DefaultStateInterval + DefaultProbeTimeout + DefaultDegradeAfter; got > 10*time.Second {
		t.Fatalf("断网判定最坏耗时 %s 超过验收 10s", got)
	}
	if got := DefaultStateInterval + DefaultProbeTimeout + DefaultRecoverAfter; got > 15*time.Second {
		t.Fatalf("恢复判定最坏耗时 %s 超过验收 15s", got)
	}
}

func TestStateMachineTransitions(t *testing.T) {
	probe := &switchProbe{}
	probe.ok.Store(true)

	var mu sync.Mutex
	var changes []State
	sm := NewStateMachine(StateOptions{
		Probe:        probe.probe,
		Interval:     10 * time.Millisecond,
		DegradeAfter: 50 * time.Millisecond,
		RecoverAfter: 30 * time.Millisecond,
		ProbeTimeout: 500 * time.Millisecond,
		OnChange: func(s State) {
			mu.Lock()
			changes = append(changes, s)
			mu.Unlock()
		},
	})

	if sm.State() != StateInit {
		t.Fatalf("初始状态 = %s，期望 init", sm.State())
	}
	// 启动前不允许等待到 online，验证 WaitState 的阻塞语义。
	waitCtx, waitCancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	if err := sm.WaitState(waitCtx, StateOnline); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("未启动时 WaitState 应超时，实际 %v", err)
	}
	waitCancel()

	if err := sm.Start(context.Background()); err != nil {
		t.Fatalf("启动状态机: %v", err)
	}
	defer sm.Stop()

	waitState(t, sm, StateOnline, 2*time.Second)

	probe.ok.Store(false)
	waitState(t, sm, StateDegraded, 2*time.Second)
	if sm.State() != StateDegraded {
		t.Fatalf("断网后状态 = %s，期望 degraded", sm.State())
	}

	probe.ok.Store(true)
	waitState(t, sm, StateOnline, 2*time.Second)

	sm.Stop()
	if sm.State() != StateStopped {
		t.Fatalf("停止后状态 = %s，期望 stopped", sm.State())
	}

	mu.Lock()
	got := append([]State(nil), changes...)
	mu.Unlock()
	want := []State{StateStarting, StateOnline, StateDegraded, StateOnline, StateStopped}
	if len(got) != len(want) {
		t.Fatalf("状态变化序列 = %v，期望 %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("状态变化序列 = %v，期望 %v", got, want)
		}
	}
}

func TestStateMachineTransientFailureDoesNotDegrade(t *testing.T) {
	var calls atomic.Int64
	probe := func(ctx context.Context) error {
		// 仅第 2 次探测失败一次，随后恢复。
		if calls.Add(1) == 2 {
			return ErrNoReachablePeer
		}
		return nil
	}
	sm := NewStateMachine(StateOptions{
		Probe:        probe,
		Interval:     10 * time.Millisecond,
		DegradeAfter: 200 * time.Millisecond,
		RecoverAfter: 20 * time.Millisecond,
		ProbeTimeout: 500 * time.Millisecond,
	})
	if err := sm.Start(context.Background()); err != nil {
		t.Fatalf("启动状态机: %v", err)
	}
	defer sm.Stop()

	waitState(t, sm, StateOnline, 2*time.Second)
	time.Sleep(300 * time.Millisecond)
	if got := sm.State(); got != StateOnline {
		t.Fatalf("单次失败后状态 = %s，期望保持 online", got)
	}
	if calls.Load() < 5 {
		t.Fatalf("探测次数 = %d，状态机未持续探测", calls.Load())
	}
}

func TestStateMachineStartupUnreachableDegrades(t *testing.T) {
	probe := &switchProbe{}
	sm := NewStateMachine(StateOptions{
		Probe:        probe.probe,
		Interval:     10 * time.Millisecond,
		DegradeAfter: 40 * time.Millisecond,
		RecoverAfter: 20 * time.Millisecond,
	})
	if err := sm.Start(context.Background()); err != nil {
		t.Fatalf("启动状态机: %v", err)
	}
	defer sm.Stop()

	waitState(t, sm, StateDegraded, 2*time.Second)
}

func TestStateMachineRequiresProbe(t *testing.T) {
	sm := NewStateMachine(StateOptions{})
	if err := sm.Start(context.Background()); !errors.Is(err, ErrProbeMissing) {
		t.Fatalf("缺少探测函数时应返回 ErrProbeMissing，实际 %v", err)
	}
	if sm.State() != StateInit {
		t.Fatalf("启动失败后状态 = %s，期望 init", sm.State())
	}
	sm.Stop()
	if sm.State() != StateStopped {
		t.Fatalf("未启动直接 Stop 后状态 = %s，期望 stopped", sm.State())
	}
}

func TestProbeAll(t *testing.T) {
	ok := func(context.Context) error { return nil }
	fail := func(context.Context) error { return ErrNoReachablePeer }

	if err := ProbeAll(ok, nil, ok)(context.Background()); err != nil {
		t.Fatalf("全部成功时返回 %v", err)
	}
	if err := ProbeAll(ok, fail)(context.Background()); !errors.Is(err, ErrNoReachablePeer) {
		t.Fatalf("任一失败时应返回该错误，实际 %v", err)
	}
}

func TestHostProbeTracksConnectivity(t *testing.T) {
	a := newTestHost(t, "probe-a", Config{})
	b := newTestHost(t, "probe-b", Config{})

	if err := HostProbe(a)(context.Background()); !errors.Is(err, ErrNoReachablePeer) {
		t.Fatalf("未连接时 HostProbe 应失败，实际 %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := a.Connect(ctx, peer.AddrInfo{ID: b.ID(), Addrs: b.Addrs()}); err != nil {
		t.Fatalf("连接对端: %v", err)
	}
	if err := HostProbe(a)(context.Background()); err != nil {
		t.Fatalf("连接后 HostProbe 应成功，实际 %v", err)
	}

	if err := a.Network().ClosePeer(b.ID()); err != nil {
		t.Fatalf("断开对端: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		err := HostProbe(a)(context.Background())
		if errors.Is(err, ErrNoReachablePeer) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("断开后 HostProbe 仍成功: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestStateMachineDisconnectWithinTenSeconds 是 P1-12 的验收用例：
// 真实双 host 建立连接后断开，须在 10s 内进入 degraded，重连后 15s 内回到 online。
func TestStateMachineDisconnectWithinTenSeconds(t *testing.T) {
	if testing.Short() {
		t.Skip("依赖真实监听端口，short 模式跳过")
	}

	a := newTestHost(t, "state-a", Config{})
	b := newTestHost(t, "state-b", Config{})

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	target := peer.AddrInfo{ID: b.ID(), Addrs: b.Addrs()}
	if err := a.Connect(ctx, target); err != nil {
		t.Fatalf("连接对端: %v", err)
	}

	sm := NewStateMachine(StateOptions{Probe: HostProbe(a)})
	if err := sm.Start(ctx); err != nil {
		t.Fatalf("启动状态机: %v", err)
	}
	defer sm.Stop()
	waitState(t, sm, StateOnline, 5*time.Second)

	// 模拟断网：断开与对端的全部连接。
	disconnectAt := time.Now()
	if err := a.Network().ClosePeer(b.ID()); err != nil {
		t.Fatalf("断开对端: %v", err)
	}
	degraded := waitState(t, sm, StateDegraded, 10*time.Second)
	if elapsed := time.Since(disconnectAt); elapsed > 10*time.Second {
		t.Fatalf("断网后 %s 才进入 degraded，超过 10s", elapsed)
	}
	t.Logf("断网后 %s 进入 degraded（上限 10s，等待耗时 %s）", time.Since(disconnectAt).Round(time.Millisecond), degraded.Round(time.Millisecond))

	reconnectAt := time.Now()
	if err := a.Connect(ctx, target); err != nil {
		t.Fatalf("重连对端: %v", err)
	}
	waitState(t, sm, StateOnline, 15*time.Second)
	if elapsed := time.Since(reconnectAt); elapsed > 15*time.Second {
		t.Fatalf("重连后 %s 才回到 online，超过 15s", elapsed)
	}
	t.Logf("重连后 %s 回到 online（上限 15s）", time.Since(reconnectAt).Round(time.Millisecond))
}
