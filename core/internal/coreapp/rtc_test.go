package coreapp

import (
	"bytes"
	"context"
	"encoding/base64"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/dm"
)

// eventData 返回最近一条指定名称事件的数据。
func eventData(l *eventLog, name string) any {
	l.mu.Lock()
	defer l.mu.Unlock()
	for i := len(l.events) - 1; i >= 0; i-- {
		if l.events[i].name == name {
			return l.events[i].data
		}
	}
	return nil
}

// TestRTCSignalEventRoundTrip 覆盖 rtc.sendSignal 透传与接收端 rtc.signal 事件。
func TestRTCSignalEventRoundTrip(t *testing.T) {
	root := t.TempDir()
	var mu sync.Mutex
	var appB *App
	var pubB []byte
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if appB != nil && bytes.Equal(pubB, accountPub) {
			return targetOf(appB), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	gwA, appA, _ := startApp(t, filepath.Join(root, "a"), resolver)
	_, startedB, logB := startApp(t, filepath.Join(root, "b"), nil)
	mu.Lock()
	appB = startedB
	pubB = startedB.Account().Pub()
	mu.Unlock()

	payload := []byte(`{"type":"answer","sdp":"v=0","mid":"audio"}`)
	call(t, gwA, "rtc.sendSignal", map[string]any{
		"peer":        base64.RawURLEncoding.EncodeToString(pubB),
		"payload_b64": base64.StdEncoding.EncodeToString(payload),
	})
	waitFor(t, 3*time.Second, func() bool { return logB.has("rtc.signal") })

	data, ok := eventData(logB, "rtc.signal").(map[string]any)
	if !ok {
		t.Fatalf("rtc.signal 事件载荷不是对象: %v", eventData(logB, "rtc.signal"))
	}
	if data["peer"] != base64.RawURLEncoding.EncodeToString(appA.Account().Pub()) {
		t.Fatalf("事件 peer 不是发送方账号: %v", data["peer"])
	}
	raw, err := base64.StdEncoding.DecodeString(data["payload_b64"].(string))
	if err != nil {
		t.Fatalf("事件载荷不是合法 base64: %v", err)
	}
	if !bytes.Equal(raw, payload) {
		t.Fatalf("事件载荷被改动: %q", raw)
	}
}

// TestRTCSignalRejectsBadPayload 覆盖网关层的载荷与对端校验。
func TestRTCSignalRejectsBadPayload(t *testing.T) {
	gw, app, _ := startApp(t, t.TempDir(), nil)
	peer := base64.RawURLEncoding.EncodeToString(app.Account().Pub())

	if code := callErr(t, gw, "rtc.sendSignal", map[string]any{
		"peer": peer, "payload_b64": "###",
	}).Code; code != gateway.CodeInvalidArg {
		t.Fatalf("非法 base64 应返回 INVALID_ARG，实际 %s", code)
	}
	oversize := base64.StdEncoding.EncodeToString(make([]byte, dm.MaxRTCSignalSize+1))
	if code := callErr(t, gw, "rtc.sendSignal", map[string]any{
		"peer": peer, "payload_b64": oversize,
	}).Code; code != gateway.CodeInvalidArg {
		t.Fatalf("超限载荷应返回 INVALID_ARG，实际 %s", code)
	}
	unknown := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	if code := callErr(t, gw, "rtc.sendSignal", map[string]any{
		"peer": unknown, "payload_b64": base64.StdEncoding.EncodeToString([]byte("x")),
	}).Code; code != gateway.CodePeerUnreachable {
		t.Fatalf("对端不可解析应返回 PEER_UNREACHABLE，实际 %s", code)
	}
}
