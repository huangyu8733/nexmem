// Package main 是桌面端 c-shared 导出层：只做 C 字符串编解码与字节搬运，
// 业务语义全部由 core/gateway 提供，与移动端 gomobile 导出层共用同一套契约。
package main

/*
#include <stdint.h>
#include <stdlib.h>

typedef void (*nexmem_event_cb)(const char* event_type, const char* payload, int payload_len);

static void nexmem_invoke_cb(nexmem_event_cb cb, const char* t, const char* p, int n) {
	if (cb != NULL) {
		cb(t, p, n);
	}
}
*/
import "C"

import (
	"context"
	"sync"
	"unsafe"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/coreapp"
)

var (
	gw      = gateway.New()
	emitter = NewEmitter()

	appOnce sync.Once
	app     *coreapp.App

	cbMu    sync.RWMutex
	eventCB C.nexmem_event_cb
)

// main 是 c-shared 产物的必需入口，不承载逻辑。
func main() {}

// coreApp 惰性装配内核；事件以 JSON 载荷写入事件缓冲，供 Dart 侧消费。
func coreApp() *coreapp.App {
	appOnce.Do(func() {
		a, err := coreapp.New(gw, coreapp.EventSinkFunc(func(eventType string, data any) {
			// data 必须是原始对象：Emitter 会自行序列化；若在这里先 Marshal 成
			// []byte，Data 就会被二次编码成 base64 字符串，Dart 侧解析不到字段。
			emitter.Emit(eventType, data)
		}))
		if err != nil {
			panic("coreapp: " + err.Error())
		}
		app = a
	})
	return app
}

// handleRaw 是 nexmem_call 的纯 Go 内核，便于单元测试直接复用。
// 空请求返回 nil；其余情况始终返回响应信封字节。
func handleRaw(raw []byte) []byte {
	if len(raw) == 0 {
		return nil
	}
	coreApp()
	return gw.Serve(context.Background(), raw)
}

// nexmem_call 处理一条完整请求信封，成功时返回 0 并把响应写入 out/outLen；
// 调用方必须用 nexmem_free 释放 out，否则每次请求泄漏一块内存。
//
//export nexmem_call
func nexmem_call(req *C.char, reqLen C.int, out **C.char, outLen *C.int) C.int {
	if req == nil || reqLen <= 0 || out == nil || outLen == nil {
		return -1
	}
	*out = nil
	*outLen = 0
	resp := handleRaw(C.GoBytes(unsafe.Pointer(req), reqLen))
	if len(resp) == 0 {
		return -1
	}
	// 多分配 1 字节并补 0，Dart/C 侧既可按长度读取，也可直接当 C 字符串使用。
	mem := C.malloc(C.size_t(len(resp) + 1))
	if mem == nil {
		return -1
	}
	dst := unsafe.Slice((*byte)(mem), len(resp)+1)
	copy(dst, resp)
	dst[len(resp)] = 0
	*out = (*C.char)(mem)
	*outLen = C.int(len(resp))
	return 0
}

// nexmem_replay_events 重放热重启期间缺失的事件：返回 seq 严格大于 since 的
// 事件 JSON 数组（按 seq 升序）。缓冲无法补齐缺口时，数组首元素为
// seq=0 的 resync_required 事件，应用应先做全量重新同步再消费后续事件。
// 返回的缓冲同样必须由调用方经 nexmem_free 释放。
//
//export nexmem_replay_events
func nexmem_replay_events(since C.uint64_t, out **C.char, outLen *C.int) C.int {
	if out == nil || outLen == nil {
		return -1
	}
	*out = nil
	*outLen = 0
	frame := emitter.ReplayFrame(uint64(since))
	mem := C.malloc(C.size_t(len(frame) + 1))
	if mem == nil {
		return -1
	}
	dst := unsafe.Slice((*byte)(mem), len(frame)+1)
	copy(dst, frame)
	dst[len(frame)] = 0
	*out = (*C.char)(mem)
	*outLen = C.int(len(frame))
	return 0
}

// nexmem_last_event_seq 返回已分配的最大事件序号，便于调用方持久化水位。
//
//export nexmem_last_event_seq
func nexmem_last_event_seq() C.uint64_t {
	return C.uint64_t(emitter.LastSeq())
}

// nexmem_free 释放 nexmem_call 分配的响应缓冲；传 nil 安全。
//
//export nexmem_free
func nexmem_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// nexmem_set_event_cb 注册事件回调；传 NULL 取消注册。
// 回调运行在 Go 的任意 goroutine 上，必须立即返回。
// 回调收到的 event_type/payload 所有权归接收方，须用 nexmem_free 释放。
//
//export nexmem_set_event_cb
func nexmem_set_event_cb(cb C.nexmem_event_cb) {
	cbMu.Lock()
	eventCB = cb
	cbMu.Unlock()
	if cb == nil {
		emitter.SetSink(nil)
		return
	}
	emitter.SetSink(cgoSink{})
}

// cgoSink 把事件转发给 C 函数指针。
//
// 事件缓冲的所有权随回调移交接收方：Dart 侧的回调是异步投递的，回调返回后
// 指针仍必须可读，因此这里不能立即释放。接收方解码完成后必须调用
// nexmem_free 释放 event_type 与 payload（均按 C 分配），否则每次事件泄漏。
type cgoSink struct{}

func (cgoSink) Emit(eventType string, payload []byte) {
	cbMu.RLock()
	cb := eventCB
	cbMu.RUnlock()
	if cb == nil {
		return
	}
	cType := C.CString(eventType)
	var cPayload unsafe.Pointer
	if len(payload) > 0 {
		cPayload = C.CBytes(payload)
	}
	C.nexmem_invoke_cb(cb, cType, (*C.char)(cPayload), C.int(len(payload)))
}
