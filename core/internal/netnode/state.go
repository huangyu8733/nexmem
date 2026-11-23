package netnode

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
)

// State 是内核对外暴露的运行状态，取值与契约 event `state.changed` 一致。
type State string

const (
	StateInit     State = "init"
	StateStarting State = "starting"
	StateOnline   State = "online"
	StateDegraded State = "degraded"
	// StateOffline 预留给「网络栈完全关闭」的场景；本状态机不主动产生。
	StateOffline State = "offline"
	StateStopped State = "stopped"
)

// 默认时间参数按 P1-12 验收口径选取：
// 断网后最迟 interval + probeTimeout + degradeAfter = 9s 进入 degraded（<10s）；
// 恢复后最迟 interval + probeTimeout + recoverAfter = 7s 回到 online（<15s）。
const (
	DefaultStateInterval = 1 * time.Second
	DefaultDegradeAfter  = 6 * time.Second
	DefaultRecoverAfter  = 4 * time.Second
	DefaultProbeTimeout  = 2 * time.Second
)

var (
	// ErrNoReachablePeer 表示本机没有可用（非受限）的对端连接。
	ErrNoReachablePeer = errors.New("没有可达对端")
	// ErrProbeMissing 表示未提供可用性探测函数。
	ErrProbeMissing = errors.New("缺少可用性探测函数")
)

// Probe 是单次可用性探测，返回 nil 视为网络可用。
// 实现应有界返回：调用方会额外套一层超时，但探测自身也应尽快结束。
type Probe func(ctx context.Context) error

// StateOptions 是状态机参数，零值字段使用默认值。
type StateOptions struct {
	Probe Probe
	// Interval 是探测间隔。
	Interval time.Duration
	// DegradeAfter 是持续失败多久后判定为 degraded。
	DegradeAfter time.Duration
	// RecoverAfter 是恢复后需要稳定多久才回到 online。
	RecoverAfter time.Duration
	// ProbeTimeout 是单次探测的超时。
	ProbeTimeout time.Duration
	// OnChange 在状态真正变化时同步调用，可能来自后台协程；回调必须立即返回。
	OnChange func(State)
}

// StateEventData 是 `state.changed` 事件的数据载荷。
type StateEventData struct {
	State State `json:"state"`
}

// StateMachine 依据周期性探测维护 init → starting → online ⇄ degraded → stopped 状态机。
type StateMachine struct {
	probe        Probe
	interval     time.Duration
	degradeAfter time.Duration
	recoverAfter time.Duration
	probeTimeout time.Duration
	onChange     func(State)

	mu           sync.Mutex
	state        State
	started      bool
	failingSince time.Time
	healthySince time.Time
	changed      chan struct{}
	cancel       context.CancelFunc
	done         chan struct{}
}

// NewStateMachine 创建状态机；未调用 Start 时状态为 init。
func NewStateMachine(opt StateOptions) *StateMachine {
	m := &StateMachine{
		probe:        opt.Probe,
		interval:     opt.Interval,
		degradeAfter: opt.DegradeAfter,
		recoverAfter: opt.RecoverAfter,
		probeTimeout: opt.ProbeTimeout,
		onChange:     opt.OnChange,
		state:        StateInit,
		changed:      make(chan struct{}),
	}
	if m.interval <= 0 {
		m.interval = DefaultStateInterval
	}
	if m.degradeAfter <= 0 {
		m.degradeAfter = DefaultDegradeAfter
	}
	if m.recoverAfter <= 0 {
		m.recoverAfter = DefaultRecoverAfter
	}
	if m.probeTimeout <= 0 {
		m.probeTimeout = DefaultProbeTimeout
	}
	return m
}

// Start 启动探测循环并进入 starting；重复调用是幂等的。
func (m *StateMachine) Start(ctx context.Context) error {
	if m.probe == nil {
		return ErrProbeMissing
	}
	m.mu.Lock()
	if m.started {
		m.mu.Unlock()
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	m.started = true
	_, changed := m.setStateLocked(StateStarting)
	loopCtx, cancel := context.WithCancel(ctx)
	m.cancel = cancel
	m.done = make(chan struct{})
	m.mu.Unlock()

	if changed {
		m.emit(StateStarting)
	}
	go m.loop(loopCtx)
	return nil
}

// Stop 终止探测循环并进入 stopped；未启动时直接置为 stopped。
func (m *StateMachine) Stop() {
	m.mu.Lock()
	cancel, done := m.cancel, m.done
	m.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if done != nil {
		<-done
	}

	m.mu.Lock()
	_, changed := m.setStateLocked(StateStopped)
	m.mu.Unlock()
	if changed {
		m.emit(StateStopped)
	}
}

// State 返回当前状态。
func (m *StateMachine) State() State {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.state
}

// WaitState 阻塞到状态变为 want 或 ctx 结束。
func (m *StateMachine) WaitState(ctx context.Context, want State) error {
	for {
		m.mu.Lock()
		if m.state == want {
			m.mu.Unlock()
			return nil
		}
		ch := m.changed
		m.mu.Unlock()

		select {
		case <-ch:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (m *StateMachine) loop(ctx context.Context) {
	defer close(m.done)
	m.evaluate(ctx)

	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.evaluate(ctx)
		}
	}
}

func (m *StateMachine) evaluate(ctx context.Context) {
	probeCtx, cancel := context.WithTimeout(ctx, m.probeTimeout)
	err := m.probe(probeCtx)
	cancel()

	now := time.Now()
	m.mu.Lock()
	if m.state != StateStarting && m.state != StateOnline && m.state != StateDegraded {
		m.mu.Unlock()
		return
	}

	next := m.state
	if err != nil {
		m.healthySince = time.Time{}
		if m.failingSince.IsZero() {
			m.failingSince = now
		}
		// 启动阶段就不可达时同样落到 degraded，避免长期停在 starting。
		if (m.state == StateStarting || m.state == StateOnline) &&
			!now.Before(m.failingSince.Add(m.degradeAfter)) {
			next = StateDegraded
		}
	} else {
		m.failingSince = time.Time{}
		switch m.state {
		case StateStarting:
			next = StateOnline
		case StateDegraded:
			if m.healthySince.IsZero() {
				m.healthySince = now
			}
			if !now.Before(m.healthySince.Add(m.recoverAfter)) {
				next = StateOnline
			}
		}
	}

	_, changed := m.setStateLocked(next)
	m.mu.Unlock()
	if changed {
		m.emit(next)
	}
}

func (m *StateMachine) setStateLocked(next State) (State, bool) {
	if m.state == next {
		return next, false
	}
	prev := m.state
	m.state = next
	m.failingSince = time.Time{}
	m.healthySince = time.Time{}
	close(m.changed)
	m.changed = make(chan struct{})
	return prev, true
}

func (m *StateMachine) emit(s State) {
	if m.onChange != nil {
		m.onChange(s)
	}
}

// HostProbe 以「至少一个已连接且非受限的对端」作为网络可用判据。
// 中继（p2p-circuit）连接在 libp2p 中标记为 Limited，会被过滤。
func HostProbe(h host.Host) Probe {
	return func(ctx context.Context) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		for _, p := range h.Network().Peers() {
			for _, c := range h.Network().ConnsToPeer(p) {
				if !c.Stat().Limited {
					return nil
				}
			}
		}
		return ErrNoReachablePeer
	}
}

// ProbeAll 依次执行多个探测，任一失败即返回该错误；nil 探测被忽略。
func ProbeAll(probes ...Probe) Probe {
	return func(ctx context.Context) error {
		for _, p := range probes {
			if p == nil {
				continue
			}
			if err := p(ctx); err != nil {
				return err
			}
		}
		return nil
	}
}
