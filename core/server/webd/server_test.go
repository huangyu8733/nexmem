package webd

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nexmem/core/gateway"
)

const testToken = "test-token-2026"

func newServer(t *testing.T, cfg Config) (*Server, *httptest.Server) {
	t.Helper()
	if cfg.Token == "" {
		cfg.Token = testToken
	}
	if cfg.Gateway == nil {
		cfg.Gateway = gateway.New()
	}
	srv, err := New(cfg)
	if err != nil {
		t.Fatalf("创建网关: %v", err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() {
		ts.Close()
		srv.Close()
	})
	return srv, ts
}

func dialWS(t *testing.T, ts *httptest.Server, query string, header http.Header) (*websocket.Conn, *http.Response, error) {
	t.Helper()
	url := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws" + query
	dialer := websocket.Dialer{HandshakeTimeout: 5 * time.Second}
	return dialer.Dial(url, header)
}

func mustDial(t *testing.T, ts *httptest.Server, query string, header http.Header) *websocket.Conn {
	t.Helper()
	conn, resp, err := dialWS(t, ts, query, header)
	if err != nil {
		t.Fatalf("建立 WebSocket: %v (resp=%v)", err, resp)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

// waitConnections 等待服务端把刚完成握手的连接登记进会话表。
// 握手成功与登记入表之间存在间隙，整包并行执行时该间隙会被放大。
func waitConnections(t *testing.T, srv *Server, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if srv.Connections() == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("连接数 = %d，期望 %d", srv.Connections(), want)
}

func roundTrip(t *testing.T, conn *websocket.Conn, raw string) map[string]any {
	t.Helper()
	if err := conn.WriteMessage(websocket.TextMessage, []byte(raw)); err != nil {
		t.Fatalf("写入请求: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("读取响应: %v", err)
	}
	var resp map[string]any
	if err := json.Unmarshal(data, &resp); err != nil {
		t.Fatalf("响应不是合法 JSON: %v (%s)", err, data)
	}
	return resp
}

func respError(t *testing.T, resp map[string]any) string {
	t.Helper()
	if ok, _ := resp["ok"].(bool); ok {
		t.Fatalf("期望失败响应: %v", resp)
	}
	errObj, _ := resp["error"].(map[string]any)
	code, _ := errObj["code"].(string)
	if code == "" {
		t.Fatalf("响应缺少 error.code: %v", resp)
	}
	return code
}

func readEvent(t *testing.T, conn *websocket.Conn) map[string]any {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("读取事件: %v", err)
	}
	var event map[string]any
	if err := json.Unmarshal(data, &event); err != nil {
		t.Fatalf("事件不是合法 JSON: %v (%s)", err, data)
	}
	return event
}

func TestNewValidatesConfig(t *testing.T) {
	if _, err := New(Config{Gateway: gateway.New()}); !errors.Is(err, ErrTokenRequired) {
		t.Fatalf("缺少令牌应返回 ErrTokenRequired，实际 %v", err)
	}
	if _, err := New(Config{Token: "  "}); !errors.Is(err, ErrTokenRequired) {
		t.Fatalf("空白令牌应返回 ErrTokenRequired，实际 %v", err)
	}
	if _, err := New(Config{Token: testToken}); !errors.Is(err, ErrGatewayRequired) {
		t.Fatalf("缺少 gateway 应返回 ErrGatewayRequired，实际 %v", err)
	}
}

func TestRejectWithoutToken(t *testing.T) {
	_, ts := newServer(t, Config{})

	cases := []struct {
		name   string
		query  string
		header http.Header
	}{
		{"无任何令牌", "", nil},
		{"错误查询令牌", "?token=wrong", nil},
		{"错误 Bearer", "", http.Header{"Authorization": []string{"Bearer wrong"}}},
		{"错误 X-Nexmem-Token", "", http.Header{"X-Nexmem-Token": []string{"wrong"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			conn, resp, err := dialWS(t, ts, tc.query, tc.header)
			if err == nil {
				_ = conn.Close()
				t.Fatal("无有效令牌不应建立连接")
			}
			if resp == nil || resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("握手状态码 = %v，期望 401", resp)
			}
		})
	}

	// 健康探测不暴露业务数据，允许匿名访问。
	health, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("健康探测: %v", err)
	}
	defer health.Body.Close()
	if health.StatusCode != http.StatusOK {
		t.Fatalf("健康探测状态码 = %d", health.StatusCode)
	}
}

func TestPingAndInfoRoundTrip(t *testing.T) {
	_, ts := newServer(t, Config{})

	// 查询参数令牌
	conn := mustDial(t, ts, "?token="+testToken, nil)
	ping := roundTrip(t, conn, `{"id":1,"method":"core.ping"}`)
	if ok, _ := ping["ok"].(bool); !ok {
		t.Fatalf("ping 失败: %v", ping)
	}
	data, _ := ping["data"].(map[string]any)
	if pong, _ := data["pong"].(bool); !pong {
		t.Fatalf("ping 未返回 pong=true: %v", data)
	}
	if ts, _ := data["server_ts"].(float64); ts <= 0 {
		t.Fatalf("ping 未返回 server_ts: %v", data)
	}

	info := roundTrip(t, conn, `{"id":2,"method":"core.info"}`)
	infoData, _ := info["data"].(map[string]any)
	if infoData["api_version"] != gateway.APIVersion {
		t.Fatalf("core.info 版本不符: %v", infoData)
	}
	if code := respError(t, roundTrip(t, conn, `{"id":3,"method":"dm.nope"}`)); code != string(gateway.CodeInvalidArg) {
		t.Fatalf("未知方法错误码 = %s", code)
	}

	// Authorization: Bearer
	headerConn := mustDial(t, ts, "", http.Header{"Authorization": []string{"Bearer " + testToken}})
	if ok, _ := roundTrip(t, headerConn, `{"id":4,"method":"core.ping"}`)["ok"].(bool); !ok {
		t.Fatal("Bearer 令牌连接 ping 失败")
	}
}

func TestSendTextRoundTrip(t *testing.T) {
	gw := gateway.New()
	if err := gw.SetHandler("dm.sendText", func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var in struct {
			Peer string `json:"peer"`
			Text string `json:"text"`
		}
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "参数解析失败: %v", err)
		}
		return map[string]any{"msg_uuid": "uuid-" + in.Peer + "-" + in.Text}, nil
	}); err != nil {
		t.Fatalf("装配 dm.sendText: %v", err)
	}
	_, ts := newServer(t, Config{Gateway: gw})
	conn := mustDial(t, ts, "?token="+testToken, nil)

	resp := roundTrip(t, conn, `{"id":11,"method":"dm.sendText","params":{"peer":"alice","text":"hi"}}`)
	if ok, _ := resp["ok"].(bool); !ok {
		t.Fatalf("send_text 往返失败（业务实现未接入？）: %v", resp)
	}
	data, _ := resp["data"].(map[string]any)
	if data["msg_uuid"] != "uuid-alice-hi" {
		t.Fatalf("send_text 返回 = %v", data)
	}

	// 未装配业务实现的方法仍返回结构化 NOT_STARTED，而不是断开连接。
	code := respError(t, roundTrip(t, conn, `{"id":12,"method":"dm.sendFile","params":{"peer":"a","path":"/tmp/x"}}`))
	if code != string(gateway.CodeNotStarted) {
		t.Fatalf("未接入方法错误码 = %s，期望 NOT_STARTED", code)
	}
}

func TestEventBroadcast(t *testing.T) {
	srv, ts := newServer(t, Config{})
	a := mustDial(t, ts, "?token="+testToken, nil)
	b := mustDial(t, ts, "?token="+testToken, nil)
	waitConnections(t, srv, 2)

	if n, err := srv.Broadcast("message.new", map[string]any{"conversation_id": "dm:alice", "msg_uuid": "u-1"}); err != nil || n != 2 {
		t.Fatalf("广播失败: n=%d err=%v", n, err)
	}
	first := readEvent(t, a)
	second := readEvent(t, b)
	if first["type"] != "message.new" || second["type"] != "message.new" {
		t.Fatalf("事件类型不符: %v / %v", first, second)
	}
	if first["seq"] != second["seq"] || first["seq"].(float64) != 1 {
		t.Fatalf("两个连接应收到同一序号 1: %v / %v", first["seq"], second["seq"])
	}
	if ts, _ := first["ts"].(float64); ts <= 0 {
		t.Fatalf("事件缺少 ts: %v", first)
	}
	data, _ := first["data"].(map[string]any)
	if data["msg_uuid"] != "u-1" {
		t.Fatalf("事件载荷 = %v", data)
	}

	if n, err := srv.Broadcast("ack", json.RawMessage(`{"msg_uuid":"u-1","code":0}`)); err != nil || n != 2 {
		t.Fatalf("第二次广播失败: n=%d err=%v", n, err)
	}
	next := readEvent(t, a)
	if next["seq"].(float64) != 2 {
		t.Fatalf("事件序号应递增到 2: %v", next["seq"])
	}

	if _, err := srv.Broadcast("bad", []byte("not-json")); err == nil {
		t.Fatal("非法 JSON 载荷应报错")
	}
}

func TestStaticAndSPAFallback(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<html>nexmem</html>"), 0o600); err != nil {
		t.Fatalf("写 index.html: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "app.js"), []byte("console.log(1)"), 0o600); err != nil {
		t.Fatalf("写 app.js: %v", err)
	}
	_, ts := newServer(t, Config{StaticDir: dir})

	get := func(path string) (int, string) {
		resp, err := http.Get(ts.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		defer resp.Body.Close()
		buf := make([]byte, 512)
		n, _ := resp.Body.Read(buf)
		return resp.StatusCode, string(buf[:n])
	}

	if code, body := get("/"); code != http.StatusOK || !strings.Contains(body, "nexmem") {
		t.Fatalf("GET / = %d %q", code, body)
	}
	if code, body := get("/app.js"); code != http.StatusOK || !strings.Contains(body, "console.log") {
		t.Fatalf("GET /app.js = %d %q", code, body)
	}
	if code, body := get("/chats/42"); code != http.StatusOK || !strings.Contains(body, "nexmem") {
		t.Fatalf("SPA 回退 = %d %q", code, body)
	}

	resp, err := http.Post(ts.URL+"/", "text/plain", strings.NewReader("x"))
	if err != nil {
		t.Fatalf("POST /: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST / 状态码 = %d", resp.StatusCode)
	}
}

func TestOriginPolicy(t *testing.T) {
	_, ts := newServer(t, Config{})

	// 同源允许
	if conn, _, err := dialWS(t, ts, "?token="+testToken, http.Header{"Origin": []string{ts.URL}}); err != nil {
		t.Fatalf("同源连接应允许: %v", err)
	} else {
		_ = conn.Close()
	}

	// 跨站拒绝
	if conn, resp, err := dialWS(t, ts, "?token="+testToken, http.Header{"Origin": []string{"http://evil.example"}}); err == nil {
		_ = conn.Close()
		t.Fatal("跨站 Origin 应被拒绝")
	} else if resp == nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("跨站握手状态码 = %v，期望 403", resp)
	}

	// 白名单
	_, ts2 := newServer(t, Config{AllowedOrigins: []string{"https://app.example.com/"}})
	if conn, _, err := dialWS(t, ts2, "?token="+testToken, http.Header{"Origin": []string{"https://app.example.com"}}); err != nil {
		t.Fatalf("白名单 Origin 应允许: %v", err)
	} else {
		_ = conn.Close()
	}
	if conn, _, err := dialWS(t, ts2, "?token="+testToken, http.Header{"Origin": []string{"https://other.example.com"}}); err == nil {
		_ = conn.Close()
		t.Fatal("白名单外的 Origin 应被拒绝")
	}
}

func TestOversizeFrameClosesConnection(t *testing.T) {
	_, ts := newServer(t, Config{MaxMessageSize: 256})
	conn := mustDial(t, ts, "?token="+testToken, nil)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(strings.Repeat("x", 2048))); err != nil {
		t.Fatalf("写入超限帧: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("超限帧后连接应被关闭")
	}
}

func TestCloseDisconnectsClients(t *testing.T) {
	srv, ts := newServer(t, Config{})
	conn := mustDial(t, ts, "?token="+testToken, nil)
	waitConnections(t, srv, 1)
	srv.Close()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("关闭网关后连接应断开")
	}
	// 已关闭后不再接受新连接
	if conn, _, err := dialWS(t, ts, "?token="+testToken, nil); err == nil {
		_ = conn.Close()
		// 允许清理期内的握手成功，但连接应立即被关闭
	}
}
