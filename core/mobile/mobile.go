// Package mobile 是移动端 gomobile 导出层。
//
// 与桌面 ffi/capi 保持同一契约语义：请求/响应均为 4 字节长度前缀之外的原样
// JSON 信封，业务逻辑全部在 core/gateway 与 internal/coreapp；本层只负责
// 字符串搬运、事件缓冲与热重启重放。gomobile 只暴露 Handle 与 EventSink
// 两个类型，导出面尽可能小（R-02 应对）。
package mobile

import (
	"context"
	"sync"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/coreapp"
	"github.com/nexmem/core/internal/eventbuf"
)

// EventSink 由 Android（Kotlin）/iOS（Swift）侧实现，用于接收内核事件。
// payload 是完整的事件信封 JSON：{"seq":N,"type":"...","ts":...,"data":{...}}。
// 回调运行在 Go 的任意 goroutine，实现方必须立即返回，不得阻塞。
type EventSink interface {
	OnEvent(payload string)
}

// Handle 是一个已装配的内核实例。同一进程内只应创建一个；
// 请求并发安全，事件先写入环形缓冲再投递 sink。
type Handle struct {
	gw      *gateway.Gateway
	app     *coreapp.App
	emitter *eventbuf.Emitter
	ctx     context.Context
	cancel  context.CancelFunc

	sinkMu sync.RWMutex
	sink   EventSink

	closeOnce sync.Once
}

// New 创建内核句柄；sink 可为 nil，之后用 SetSink 注册。
func New(sink EventSink) (*Handle, error) {
	h := &Handle{
		gw:      gateway.New(),
		emitter: eventbuf.NewEmitter(),
		sink:    sink,
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	h.emitter.SetSink(handleSink{h: h})
	app, err := coreapp.New(h.gw, coreapp.EventSinkFunc(func(eventType string, data any) {
		h.emitter.Emit(eventType, data)
	}))
	if err != nil {
		h.cancel()
		return nil, err
	}
	h.app = app
	return h, nil
}

// handleSink 把 eventbuf 的字节载荷转交移动端 sink（保持 Handle 导出面最小）。
type handleSink struct {
	h *Handle
}

func (s handleSink) Emit(eventType string, payload []byte) {
	s.h.emit(payload)
}

func (h *Handle) emit(payload []byte) {
	h.sinkMu.RLock()
	sink := h.sink
	h.sinkMu.RUnlock()
	if sink == nil {
		return
	}
	sink.OnEvent(string(payload))
}

// SetSink 替换事件出口；传 nil 表示暂停外发（事件仍入环形缓冲）。
func (h *Handle) SetSink(sink EventSink) {
	h.sinkMu.Lock()
	h.sink = sink
	h.sinkMu.Unlock()
}

// Call 处理一条完整请求信封并返回响应信封；空请求返回空串。
func (h *Handle) Call(request string) string {
	if request == "" {
		return ""
	}
	resp := h.gw.Serve(h.ctx, []byte(request))
	if len(resp) == 0 {
		return ""
	}
	return string(resp)
}

// ReplaySince 返回 seq 严格大于 since 的事件 JSON 数组；缺口时首元素为
// seq=0 的 resync_required。since<=0 表示新客户端不重放历史。
func (h *Handle) ReplaySince(since int64) string {
	if since < 0 {
		return "[]"
	}
	return string(h.emitter.ReplayFrame(uint64(since)))
}

// LastSeq 返回已分配的最大事件序号，供客户端持久化水位。
func (h *Handle) LastSeq() int64 {
	return int64(h.emitter.LastSeq())
}

// Close 关闭内核并释放资源；可重复调用。
func (h *Handle) Close() {
	h.closeOnce.Do(func() {
		h.emitter.SetSink(nil)
		h.sinkMu.Lock()
		h.sink = nil
		h.sinkMu.Unlock()
		h.cancel()
		if h.app != nil {
			_ = h.app.Close()
		}
	})
}
