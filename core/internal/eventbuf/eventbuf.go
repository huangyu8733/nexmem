// Package eventbuf 提供带环形缓冲的网关事件发射器。
//
// 桌面 c-shared（ffi/capi）与移动 gomobile（mobile）导出层共用同一实现：
// 事件分配全局单调 seq、编码为契约信封、写入容量固定的环形缓冲，
// 热重启后客户端凭 seq 水位重放；无法补齐缺口时下发 seq=0 的
// resync_required，语义与 server/webd 的事件缓冲保持一致。
package eventbuf

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nexmem/core/gateway"
)

// DefaultSize 是事件环形缓冲的默认容量（方案 §6.7 的 512 条）。
const DefaultSize = 512

// EventSink 接收已编码的事件载荷。实现方必须立即返回：
// 回调运行在任意 goroutine，内部只允许做「入缓冲 + 投递 UI 线程」。
type EventSink interface {
	Emit(eventType string, payload []byte)
}

type frame struct {
	seq     uint64
	payload []byte
}

// Emitter 为事件分配全局递增 seq 并序列化为契约信封后交给 sink。
// 未设置 sink 时仍然推进 seq，保证事件序号不因订阅时机而回退。
type Emitter struct {
	seq  atomic.Uint64
	mu   sync.RWMutex
	sink EventSink
	buf  []frame
	max  int
}

// NewEmitter 创建事件发射器。
func NewEmitter() *Emitter {
	return &Emitter{max: DefaultSize, buf: make([]frame, 0, DefaultSize)}
}

// SetSink 替换事件出口；传 nil 表示暂停外发。
func (e *Emitter) SetSink(sink EventSink) {
	e.mu.Lock()
	e.sink = sink
	e.mu.Unlock()
}

// Sink 返回当前事件出口，未设置时为 nil。
func (e *Emitter) Sink() EventSink {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.sink
}

// SetBufferSize 调整环形缓冲容量；调用后只保留最新的 n 条事件。
// n <= 0 时恢复默认容量。
func (e *Emitter) SetBufferSize(n int) {
	if n <= 0 {
		n = DefaultSize
	}
	e.mu.Lock()
	if len(e.buf) > n {
		trimmed := make([]frame, n)
		copy(trimmed, e.buf[len(e.buf)-n:])
		e.buf = trimmed
	}
	e.max = n
	e.mu.Unlock()
}

// LastSeq 返回已分配的最大事件序号；无事件时为 0。
func (e *Emitter) LastSeq() uint64 {
	return e.seq.Load()
}

// Emit 构造 Event 信封并投递，返回写入 seq 的事件本身。
func (e *Emitter) Emit(eventType string, data any) gateway.Event {
	var raw json.RawMessage
	if data != nil {
		if b, err := json.Marshal(data); err == nil {
			raw = b
		}
	}
	ev := gateway.Event{
		Seq:  e.seq.Add(1),
		Type: eventType,
		TS:   time.Now().UnixMilli(),
		Data: raw,
	}
	payload, err := json.Marshal(ev)
	if err != nil {
		return ev
	}
	e.mu.Lock()
	if e.max > 0 {
		if len(e.buf) >= e.max {
			copy(e.buf, e.buf[1:])
			e.buf = e.buf[:len(e.buf)-1]
		}
		e.buf = append(e.buf, frame{seq: ev.Seq, payload: payload})
	}
	sink := e.sink
	e.mu.Unlock()
	if sink != nil {
		sink.Emit(eventType, payload)
	}
	return ev
}

// ReplaySince 返回 seq 严格大于 since 的事件，按 seq 升序。
// ok=false 表示缺口无法补齐（请求区间已淘汰，或客户端序号超前），
// 调用方应改为下发 resync_required。
func (e *Emitter) ReplaySince(since uint64) (events [][]byte, ok bool) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if since == 0 {
		// 全新客户端不重放历史，只从当前时点开始接收。
		return nil, true
	}
	if len(e.buf) == 0 {
		return nil, false
	}
	latest := e.buf[len(e.buf)-1].seq
	oldest := e.buf[0].seq
	if since >= latest {
		return nil, true
	}
	if since+1 < oldest {
		return nil, false
	}
	start := 0
	for start < len(e.buf) && e.buf[start].seq <= since {
		start++
	}
	out := make([][]byte, len(e.buf)-start)
	for i := start; i < len(e.buf); i++ {
		out[i-start] = e.buf[i].payload
	}
	return out, true
}

// BufferRange 返回环形缓冲内最旧与最新序号；空缓冲返回 0/0。
func (e *Emitter) BufferRange() (oldest, latest uint64) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if len(e.buf) == 0 {
		return 0, 0
	}
	return e.buf[0].seq, e.buf[len(e.buf)-1].seq
}

// ReplayFrame 返回可直接下发给客户端的 JSON 数组：正常时为缺失事件，
// 缺口时首元素为不占序号的 resync_required 事件。
func (e *Emitter) ReplayFrame(since uint64) []byte {
	events, ok := e.ReplaySince(since)
	oldest, latest := e.BufferRange()
	frames := make([]json.RawMessage, 0, len(events)+1)
	if !ok {
		resync, err := json.Marshal(gateway.Event{
			Type: "resync_required",
			TS:   time.Now().UnixMilli(),
			Data: mustJSON(map[string]any{
				"reason":     "gap",
				"since":      since,
				"oldest_seq": oldest,
				"latest_seq": latest,
			}),
		})
		if err == nil {
			frames = append(frames, resync)
		}
	}
	for _, payload := range events {
		frames = append(frames, json.RawMessage(payload))
	}
	out, err := json.Marshal(frames)
	if err != nil {
		return []byte("[]")
	}
	return out
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return b
}
