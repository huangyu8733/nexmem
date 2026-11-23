package webd

import (
	"strings"
	"testing"

	"github.com/nexmem/core/gateway"
)

func TestEventBufferReplay(t *testing.T) {
	buf := newEventBuffer(4)
	for i := uint64(1); i <= 3; i++ {
		buf.append(i, []byte(`{}`))
	}
	items, ok := buf.replay(1)
	if !ok || len(items) != 2 || items[0].seq != 2 || items[1].seq != 3 {
		t.Fatalf("重放 seq>1 失败: ok=%v items=%v", ok, items)
	}
	if items, ok := buf.replay(3); !ok || len(items) != 0 {
		t.Fatalf("已追平时应返回空重放: ok=%v items=%v", ok, items)
	}
	if _, ok := buf.replay(0); !ok {
		t.Fatal("since=0 表示全新客户端，不应触发 resync")
	}
}

func TestEventBufferOverflowDropsOldest(t *testing.T) {
	buf := newEventBuffer(2)
	for i := uint64(1); i <= 4; i++ {
		buf.append(i, []byte(`{}`))
	}
	if buf.oldest() != 3 || buf.latest() != 4 {
		t.Fatalf("缓冲应只保留 3/4，实际 %d/%d", buf.oldest(), buf.latest())
	}
	if _, ok := buf.replay(1); ok {
		t.Fatal("请求已被淘汰的区间应判定为缺口")
	}
	if items, ok := buf.replay(2); !ok || len(items) != 2 {
		t.Fatalf("seq>2 应可补齐: ok=%v len=%d", ok, len(items))
	}
}

func TestResumeReplaysMissedEvents(t *testing.T) {
	srv, ts := newServer(t, Config{})
	live := mustDial(t, ts, "?token="+testToken, nil)
	if _, err := srv.Broadcast("message.new", map[string]any{"msg_uuid": "u-1"}); err != nil {
		t.Fatalf("广播 1: %v", err)
	}
	first := readEvent(t, live)
	if first["seq"].(float64) != 1 {
		t.Fatalf("在线连接应收到 seq=1: %v", first)
	}

	// 断线期间产生两条事件。
	if _, err := srv.Broadcast("message.new", map[string]any{"msg_uuid": "u-2"}); err != nil {
		t.Fatalf("广播 2: %v", err)
	}
	if _, err := srv.Broadcast("message.new", map[string]any{"msg_uuid": "u-3"}); err != nil {
		t.Fatalf("广播 3: %v", err)
	}

	// 客户端带 lastSeq=1 重连，应补收 2/3 且不重复 1。
	resumed := mustDial(t, ts, "?token="+testToken+"&since=1", nil)
	for _, want := range []float64{2, 3} {
		ev := readEvent(t, resumed)
		if ev["seq"].(float64) != want {
			t.Fatalf("重放序号 = %v，期望 %v", ev["seq"], want)
		}
	}
}

func TestResumeGapRequestsResync(t *testing.T) {
	srv, ts := newServer(t, Config{EventBufferSize: 2})
	conn := mustDial(t, ts, "?token="+testToken, nil)
	for i := 0; i < 4; i++ {
		if _, err := srv.Broadcast("message.new", map[string]any{"i": i}); err != nil {
			t.Fatalf("广播 %d: %v", i, err)
		}
	}
	_ = conn.Close()

	// 缓冲只剩 3/4，lastSeq=1 无法补齐，应收到 resync_required。
	resumed := mustDial(t, ts, "?token="+testToken+"&since=1", nil)
	ev := readEvent(t, resumed)
	if ev["type"] != "resync_required" {
		t.Fatalf("缺口应下发 resync_required: %v", ev)
	}
	data, _ := ev["data"].(map[string]any)
	if data["reason"] != "gap" {
		t.Fatalf("resync 载荷 = %v", data)
	}
	if data["latest_seq"].(float64) != 4 || data["oldest_seq"].(float64) != 3 {
		t.Fatalf("resync 序号窗口 = %v", data)
	}
}

func TestResyncEventTypeIsStable(t *testing.T) {
	if gateway.APIVersion == "" {
		t.Fatal("契约版本为空")
	}
	payload, err := resyncEvent("gap", 1, 5, 9)
	if err != nil {
		t.Fatalf("构造 resync: %v", err)
	}
	for _, sub := range []string{`"type":"resync_required"`, `"seq":0`, `"reason":"gap"`} {
		if !strings.Contains(string(payload), sub) {
			t.Fatalf("resync 事件负载缺少 %s: %s", sub, payload)
		}
	}
}
