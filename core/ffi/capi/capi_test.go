package main

import (
	"encoding/json"
	"testing"

	"github.com/nexmem/core/gateway"
)

func TestHandleRawCoreInfo(t *testing.T) {
	resp := handleRaw([]byte(`{"id":7,"method":"core.info","params":{}}`))
	var env struct {
		ID   uint64 `json:"id"`
		OK   bool   `json:"ok"`
		Data struct {
			APIVersion  string   `json:"api_version"`
			CoreVersion string   `json:"core_version"`
			Features    []string `json:"features"`
		} `json:"data"`
	}
	if err := json.Unmarshal(resp, &env); err != nil {
		t.Fatalf("响应不是合法 JSON: %v", err)
	}
	if !env.OK || env.ID != 7 {
		t.Fatalf("期望 ok=true 且 id=7，实际 %s", resp)
	}
	if env.Data.APIVersion != gateway.APIVersion || env.Data.CoreVersion != gateway.CoreVersion {
		t.Fatalf("版本信息不一致: %s", resp)
	}
	found := false
	for _, f := range env.Data.Features {
		if f == "core.info" {
			found = true
		}
	}
	if !found {
		t.Fatalf("features 缺少 core.info: %v", env.Data.Features)
	}
}

func TestHandleRawUnknownMethod(t *testing.T) {
	resp := handleRaw([]byte(`{"id":1,"method":"nope.method","params":{}}`))
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(resp, &env); err != nil {
		t.Fatalf("响应不是合法 JSON: %v", err)
	}
	if env.OK || env.Error.Code != string(gateway.CodeInvalidArg) {
		t.Fatalf("期望 INVALID_ARG，实际 %s", resp)
	}
}

func TestHandleRawEmptyAndMalformed(t *testing.T) {
	if resp := handleRaw(nil); resp != nil {
		t.Fatalf("空请求应返回 nil，实际 %s", resp)
	}
	resp := handleRaw([]byte("not-json"))
	if len(resp) == 0 {
		t.Fatal("非法 JSON 也必须返回错误信封")
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(resp, &env); err != nil {
		t.Fatalf("响应不是合法 JSON: %v", err)
	}
	if env.OK || env.Error.Code != string(gateway.CodeInvalidArg) {
		t.Fatalf("期望 INVALID_ARG，实际 %s", resp)
	}
}

type recordingSink struct {
	types    []string
	payloads [][]byte
}

func (r *recordingSink) Emit(eventType string, payload []byte) {
	r.types = append(r.types, eventType)
	r.payloads = append(r.payloads, append([]byte(nil), payload...))
}

func TestEmitterSeqAndPayload(t *testing.T) {
	em := NewEmitter()
	rec := &recordingSink{}
	em.SetSink(rec)

	first := em.Emit("state.changed", map[string]any{"state": "online"})
	second := em.Emit("message.new", map[string]any{"msg_uuid": "u1"})

	if first.Seq != 1 || second.Seq != 2 {
		t.Fatalf("seq 应单调递增，实际 %d / %d", first.Seq, second.Seq)
	}
	if first.TS <= 0 || second.TS <= 0 {
		t.Fatalf("事件缺少时间戳: %+v %+v", first, second)
	}
	if len(rec.types) != 2 || rec.types[0] != "state.changed" || rec.types[1] != "message.new" {
		t.Fatalf("sink 收到的事件类型不符: %v", rec.types)
	}
	var decoded gateway.Event
	if err := json.Unmarshal(rec.payloads[0], &decoded); err != nil {
		t.Fatalf("事件载荷不是合法 JSON: %v", err)
	}
	if decoded.Seq != 1 || decoded.Type != "state.changed" {
		t.Fatalf("事件信封字段不符: %+v", decoded)
	}
	var data map[string]string
	if err := json.Unmarshal(decoded.Data, &data); err != nil || data["state"] != "online" {
		t.Fatalf("事件 data 不符: %s", decoded.Data)
	}
}

func TestEmitterAdvancesSeqWithoutSink(t *testing.T) {
	em := NewEmitter()
	em.Emit("state.changed", nil)
	ev := em.Emit("state.changed", map[string]string{"state": "offline"})
	if ev.Seq != 2 {
		t.Fatalf("无 sink 时 seq 仍应推进，实际 %d", ev.Seq)
	}
	rec := &recordingSink{}
	em.SetSink(rec)
	if next := em.Emit("state.changed", nil); next.Seq != 3 {
		t.Fatalf("订阅后 seq 不得回退，实际 %d", next.Seq)
	}
	em.SetSink(nil)
	if em.Sink() != nil {
		t.Fatal("取消订阅后 Sink 应为 nil")
	}
}

func decodeReplay(t *testing.T, raw []byte) []gateway.Event {
	t.Helper()
	var events []gateway.Event
	if err := json.Unmarshal(raw, &events); err != nil {
		t.Fatalf("重放帧不是合法 JSON 数组: %v (%s)", err, raw)
	}
	return events
}

func TestEmitterReplaySince(t *testing.T) {
	em := NewEmitter()
	for i := 1; i <= 3; i++ {
		em.Emit("message.new", map[string]int{"i": i})
	}

	if events := decodeReplay(t, em.ReplayFrame(0)); len(events) != 0 {
		t.Fatalf("since=0 不应重放历史，实际 %d 条", len(events))
	}
	events := decodeReplay(t, em.ReplayFrame(1))
	if len(events) != 2 || events[0].Seq != 2 || events[1].Seq != 3 {
		t.Fatalf("since=1 应重放 seq 2/3，实际 %+v", events)
	}
	if events := decodeReplay(t, em.ReplayFrame(3)); len(events) != 0 {
		t.Fatalf("追平后不应重放，实际 %d 条", len(events))
	}
	if events := decodeReplay(t, em.ReplayFrame(9)); len(events) != 0 {
		t.Fatalf("序号超前时按追平处理，实际 %d 条", len(events))
	}
	if got := em.LastSeq(); got != 3 {
		t.Fatalf("LastSeq 应为 3，实际 %d", got)
	}
}

func TestEmitterReplayOverflowEmitsResync(t *testing.T) {
	em := NewEmitter()
	em.SetBufferSize(2)
	for i := 1; i <= 5; i++ {
		em.Emit("message.new", map[string]int{"i": i})
	}
	oldest, latest := em.BufferRange()
	if oldest != 4 || latest != 5 {
		t.Fatalf("容量 2 时应只保留 seq 4/5，实际 %d/%d", oldest, latest)
	}

	events := decodeReplay(t, em.ReplayFrame(1))
	if len(events) != 1 {
		t.Fatalf("缺口帧应只含 resync_required，实际 %+v", events)
	}
	if events[0].Type != "resync_required" || events[0].Seq != 0 {
		t.Fatalf("首元素应为 resync_required 且 seq=0，实际 %+v", events[0])
	}
	var reason map[string]any
	if err := json.Unmarshal(events[0].Data, &reason); err != nil {
		t.Fatalf("resync 载荷不是合法 JSON: %v", err)
	}
	if reason["reason"] != "gap" || reason["oldest_seq"] != float64(4) || reason["latest_seq"] != float64(5) {
		t.Fatalf("resync 载荷不符: %v", reason)
	}

	if events := decodeReplay(t, em.ReplayFrame(4)); len(events) != 1 || events[0].Seq != 5 {
		t.Fatalf("相邻序号不应判定缺口，实际 %+v", events)
	}
}
