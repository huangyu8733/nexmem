package main

import "github.com/nexmem/core/internal/eventbuf"

// 桌面导出层的事件缓冲与移动 gomobile 导出层共用 internal/eventbuf 实现，
// 这里只保留 FFI 侧使用的类型别名，避免两套语义漂移。

// DefaultEventBufferSize 是 FFI 事件环形缓冲的默认容量，与 webd 保持一致（方案 §6.7）。
const DefaultEventBufferSize = eventbuf.DefaultSize

// EventSink 接收网关事件。实现方必须立即返回：回调运行在任意 goroutine，
// 内部只允许做「分配 seq + 入缓冲」，禁止同步等待 UI 线程。
type EventSink = eventbuf.EventSink

// Emitter 为事件分配全局递增 seq 并序列化为契约信封后交给 sink。
type Emitter = eventbuf.Emitter

// NewEmitter 创建事件发射器。
func NewEmitter() *Emitter { return eventbuf.NewEmitter() }
