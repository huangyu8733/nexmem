package webd

import (
	"encoding/json"
	"time"

	"github.com/nexmem/core/gateway"
)

// DefaultEventBufferSize 是每个网关保留的事件条数，与方案 §6.7 的 512 一致。
// 超出后丢弃最旧事件；客户端若请求已丢弃的区间，服务端下发 resync_required。
const DefaultEventBufferSize = 512

// bufferedEvent 是环形缓冲中的一条已编码事件帧。
type bufferedEvent struct {
	seq     uint64
	payload []byte
}

// eventBuffer 是按 seq 有序的定长事件缓冲，只保留最近 max 条。
// 所有访问都在 Server.mu 保护下进行。
type eventBuffer struct {
	max   int
	items []bufferedEvent
}

func newEventBuffer(max int) *eventBuffer {
	if max <= 0 {
		max = DefaultEventBufferSize
	}
	return &eventBuffer{max: max, items: make([]bufferedEvent, 0, max)}
}

// append 追加一条事件；超出容量时丢弃最旧的一条，绝不阻塞调用方。
func (b *eventBuffer) append(seq uint64, payload []byte) {
	if b.max <= 0 {
		return
	}
	if len(b.items) == b.max {
		copy(b.items, b.items[1:])
		b.items = b.items[:len(b.items)-1]
	}
	b.items = append(b.items, bufferedEvent{seq: seq, payload: payload})
}

// latest 返回缓冲内最新序号；空缓冲返回 0。
func (b *eventBuffer) latest() uint64 {
	if len(b.items) == 0 {
		return 0
	}
	return b.items[len(b.items)-1].seq
}

// oldest 返回缓冲内最旧序号；空缓冲返回 0。
func (b *eventBuffer) oldest() uint64 {
	if len(b.items) == 0 {
		return 0
	}
	return b.items[0].seq
}

// replay 返回 seq 严格大于 since 的事件，按 seq 升序。
// ok=false 表示缺口无法补齐（请求区间已被淘汰，或客户端序号超前），
// 调用方应改为下发 resync_required，由客户端重新拉取首页数据。
func (b *eventBuffer) replay(since uint64) (items []bufferedEvent, ok bool) {
	if since == 0 {
		// 全新客户端不重放历史，只从当前时点开始接收。
		return nil, true
	}
	if len(b.items) == 0 {
		return nil, false
	}
	if since > b.latest() {
		// 客户端水位超前于服务端：网关进程重启后 seq 从 0 重新计数，
		// 若按"已追平"处理，客户端会用旧水位把后续新事件误判为重复丢弃。
		// 返回 false 让上层下发 resync_required，客户端据 latest_seq 纠正水位。
		return nil, false
	}
	if since == b.latest() {
		// 没有遗漏：客户端恰好追平，等待新事件。
		return nil, true
	}
	if since+1 < b.oldest() {
		return nil, false
	}
	start := 0
	for start < len(b.items) && b.items[start].seq <= since {
		start++
	}
	out := make([]bufferedEvent, len(b.items)-start)
	copy(out, b.items[start:])
	return out, true
}

// resyncEvent 构造一条 resync_required 事件。它不占用服务端 seq（seq=0），
// 客户端必须先处理该事件类型再做去重判断。
func resyncEvent(reason string, since uint64, oldest, latest uint64) ([]byte, error) {
	data, err := json.Marshal(map[string]any{
		"reason":     reason,
		"since":      since,
		"oldest_seq": oldest,
		"latest_seq": latest,
	})
	if err != nil {
		return nil, err
	}
	return json.Marshal(gateway.Event{
		Type: "resync_required",
		TS:   time.Now().UnixMilli(),
		Data: data,
	})
}
