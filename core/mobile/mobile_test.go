package mobile

import (
	"encoding/json"
	"fmt"
	"sync"
	"testing"
)

type recordingSink struct {
	mu       sync.Mutex
	payloads []string
}

func (s *recordingSink) OnEvent(payload string) {
	s.mu.Lock()
	s.payloads = append(s.payloads, payload)
	s.mu.Unlock()
}

func (s *recordingSink) frames() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, len(s.payloads))
	copy(out, s.payloads)
	return out
}

func decodeResp(t *testing.T, raw string) map[string]any {
	t.Helper()
	var resp map[string]any
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("响应不是合法 JSON: %v (%q)", err, raw)
	}
	return resp
}

func TestCallPing(t *testing.T) {
	h, err := New(nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer h.Close()

	resp := decodeResp(t, h.Call(`{"id":1,"method":"core.ping","params":{}}`))
	if resp["ok"] != true {
		t.Fatalf("core.ping 未成功: %v", resp)
	}
	data, _ := resp["data"].(map[string]any)
	if data["pong"] != true {
		t.Fatalf("缺少 pong: %v", resp)
	}
}

func TestUnknownMethodAndEmptyRequest(t *testing.T) {
	h, err := New(nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer h.Close()

	if got := h.Call(""); got != "" {
		t.Fatalf("空请求应返回空串，实际 %q", got)
	}
	resp := decodeResp(t, h.Call(`{"id":2,"method":"no.such.method","params":{}}`))
	if resp["ok"] != false {
		t.Fatalf("未知方法应失败: %v", resp)
	}
	errObj, _ := resp["error"].(map[string]any)
	if errObj["code"] != "INVALID_ARG" {
		t.Fatalf("未知方法错误码应为 INVALID_ARG，实际 %v", resp)
	}
}

func TestStartEmitsEventsAndReplay(t *testing.T) {
	sink := &recordingSink{}
	h, err := New(sink)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer h.Close()

	dir := t.TempDir()
	req := fmt.Sprintf(`{"id":3,"method":"core.start","params":{"config":{"data_dir":%q}}}`, dir)
	resp := decodeResp(t, h.Call(req))
	if resp["ok"] != true {
		t.Fatalf("core.start 失败: %v", resp)
	}
	if len(sink.frames()) == 0 {
		t.Fatal("core.start 后应至少回传一条事件")
	}
	if h.LastSeq() <= 0 {
		t.Fatalf("事件序号应大于 0，实际 %d", h.LastSeq())
	}
	if got := h.ReplaySince(0); got != "[]" {
		t.Fatalf("since=0 不应重放历史，实际 %s", got)
	}
	var replayed []map[string]any
	if err := json.Unmarshal([]byte(h.ReplaySince(1)), &replayed); err != nil {
		t.Fatalf("重放结果不是 JSON 数组: %v", err)
	}
	if len(replayed) == 0 {
		t.Fatal("since=1 应能补齐 core.start 期间的事件")
	}
	if replayed[0]["type"] == "resync_required" {
		t.Fatalf("缓冲内仍有事件时不应要求全量重新同步: %v", replayed[0])
	}

	stop := decodeResp(t, h.Call(`{"id":4,"method":"core.stop","params":{}}`))
	if stop["ok"] != true {
		t.Fatalf("core.stop 失败: %v", stop)
	}
}

func TestReplayGapRequestsResync(t *testing.T) {
	h, err := New(nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer h.Close()

	dir := t.TempDir()
	req := fmt.Sprintf(`{"id":5,"method":"core.start","params":{"config":{"data_dir":%q}}}`, dir)
	if resp := decodeResp(t, h.Call(req)); resp["ok"] != true {
		t.Fatalf("core.start 失败: %v", resp)
	}
	// 前置补足事件数，再用极小容量淘汰历史，构造无法补齐的缺口。
	for i := 0; i < 3; i++ {
		h.emitter.Emit("test.tick", map[string]any{"i": i})
	}
	h.emitter.SetBufferSize(1)
	if h.LastSeq() < 3 {
		t.Fatalf("事件数量不足，无法构造缺口: %d", h.LastSeq())
	}
	var frames []map[string]any
	if err := json.Unmarshal([]byte(h.ReplaySince(1)), &frames); err != nil {
		t.Fatalf("重放结果不是 JSON 数组: %v", err)
	}
	if len(frames) == 0 || frames[0]["type"] != "resync_required" {
		t.Fatalf("缺口应返回 resync_required: %v", frames)
	}
	if seq, _ := frames[0]["seq"].(float64); seq != 0 {
		t.Fatalf("resync_required 不占序号，实际 %v", frames[0]["seq"])
	}
}

func TestCloseIsIdempotent(t *testing.T) {
	h, err := New(nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	h.Close()
	h.Close()
	if got := h.Call(`{"id":6,"method":"core.ping","params":{}}`); got == "" {
		t.Fatal("Close 后网关仍应可独立响应 core.ping")
	}
}
