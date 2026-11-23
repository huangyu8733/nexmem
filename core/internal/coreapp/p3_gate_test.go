package coreapp

// P3 阶段门禁的本地回归用例（索引服务宕机不影响在线聊天）。

import (
	"context"
	"encoding/hex"
	"fmt"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/server/directory"
)

// startGateApp 启动一个配置了索引服务、可注入解析器的装配体，并返回事件日志。
func startGateApp(t *testing.T, dir, directoryURL string, resolver dm.PeerResolver) (*gateway.Gateway, *App, *eventLog) {
	t.Helper()
	gw := gateway.New()
	log := &eventLog{}
	app, err := New(gw, log)
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if resolver != nil {
		app.SetPeerResolver(resolver)
	}
	if _, err := app.Start(context.Background(), Config{
		DataDir:      dir,
		Listen:       []string{"/ip4/127.0.0.1/tcp/0"},
		DirectoryURL: directoryURL,
		DisplayName:  "gate",
	}); err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	t.Cleanup(func() { _ = app.Stop() })
	return gw, app, log
}

// TestP3GateIndexOutageKeepsOnlineChat 是 P3 门禁的本地可复现项：
// 索引服务宕机后，已建立直连的在线聊天必须 100% 不受影响（无丢消息、无失败态）。
func TestP3GateIndexOutageKeepsOnlineChat(t *testing.T) {
	dirSrv, err := directory.New(filepath.Join(t.TempDir(), "directory.db"))
	if err != nil {
		t.Fatalf("启动索引服务: %v", err)
	}
	httpSrv := httptest.NewServer(dirSrv.Handler())
	var closeOnce sync.Once
	stopDirectory := func() {
		closeOnce.Do(func() {
			httpSrv.Close()
			_ = dirSrv.Close()
		})
	}
	t.Cleanup(stopDirectory)

	var (
		mu sync.Mutex
		a  *App
		b  *App
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if a != nil && string(a.Account().Pub()) == string(accountPub) {
			return targetOf(a), nil
		}
		if b != nil && string(b.Account().Pub()) == string(accountPub) {
			return targetOf(b), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	gwA, appA, logA := startGateApp(t, filepath.Join(t.TempDir(), "a"), httpSrv.URL, resolver)
	gwB, appB, logB := startGateApp(t, filepath.Join(t.TempDir(), "b"), httpSrv.URL, resolver)
	mu.Lock()
	a, b = appA, appB
	mu.Unlock()

	conv := dm.ConversationID(appA.Account().Pub(), appB.Account().Pub())
	send := func(text string) string {
		t.Helper()
		data, ok := call(t, gwA, "dm.sendText", map[string]any{
			"peer": hex.EncodeToString(appB.Account().Pub()),
			"text": text,
		}).(map[string]any)
		if !ok {
			t.Fatalf("dm.sendText 返回值不是对象: %v", data)
		}
		uuid, _ := data["msg_uuid"].(string)
		if uuid == "" {
			t.Fatalf("dm.sendText 未返回 msg_uuid: %v", data)
		}
		return uuid
	}

	// 预热：先完成一次直连收发，确保索引服务宕机时连接已就绪。
	send("warmup")
	waitFor(t, 10*time.Second, func() bool { return logB.has("message.new") })
	waitFor(t, 10*time.Second, func() bool { return logA.has("message.updated") })

	// 索引服务宕机（进程内直接关闭 HTTP 服务与数据库）。
	stopDirectory()

	const total = 100
	uuids := make(map[string]struct{}, total)
	for i := 0; i < total; i++ {
		uuid := send(fmt.Sprintf("outage-%03d", i))
		if _, dup := uuids[uuid]; dup {
			t.Fatalf("重复的 msg_uuid: %s", uuid)
		}
		uuids[uuid] = struct{}{}
	}

	history := func(gw *gateway.Gateway) []map[string]any {
		t.Helper()
		data, ok := call(t, gw, "msg.list", map[string]any{
			"conversation_id": conv, "limit": 200,
		}).(map[string]any)
		if !ok {
			t.Fatal("msg.list 返回值不是对象")
		}
		out := make([]map[string]any, 0, len(listItems(t, data)))
		for _, raw := range listItems(t, data) {
			item, ok := raw.(map[string]any)
			if !ok {
				t.Fatalf("msg.list 条目不是对象: %v", raw)
			}
			out = append(out, item)
		}
		return out
	}

	want := total + 1 // 含预热消息
	waitFor(t, 60*time.Second, func() bool { return len(history(gwB)) == want })

	itemsB := history(gwB)
	seen := make(map[string]struct{}, want)
	for _, item := range itemsB {
		uuid, _ := item["msg_uuid"].(string)
		if _, dup := seen[uuid]; dup {
			t.Fatalf("接收端出现重复消息: %s", uuid)
		}
		seen[uuid] = struct{}{}
		if item["direction"] != "in" {
			t.Fatalf("接收端方向应为 in: %v", item)
		}
		if item["text"] == "" {
			t.Fatalf("接收端缺少正文: %v", item)
		}
	}
	// 倒序历史：第 i 条（从新到旧）应为 outage-(total-1-i)，最后一条为预热消息。
	for i, item := range itemsB {
		expect := "warmup"
		if i < total {
			expect = fmt.Sprintf("outage-%03d", total-1-i)
		}
		if item["text"] != expect {
			t.Fatalf("第 %d 条历史正文 %v，期望 %q", i, item["text"], expect)
		}
	}

	itemsA := history(gwA)
	if len(itemsA) != want {
		t.Fatalf("发送端历史 %d 条，期望 %d", len(itemsA), want)
	}
	for _, item := range itemsA {
		if item["state"] == "failed" || item["state"] == "unknown" {
			t.Fatalf("索引服务宕机不应影响在线收发，出现异常状态: %v", item)
		}
	}

	// P3 门禁的观测面：桶用量与票据消耗字段必须可读（未配存储时保持 0）。
	snap, ok := call(t, gwA, "diag.snapshot", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("diag.snapshot 返回值不是对象")
	}
	for _, key := range []string{"offline_uploads", "offline_upload_bytes", "offline_upload_failures", "tickets_taken"} {
		if _, exists := snap[key]; !exists {
			t.Fatalf("diag.snapshot 缺少字段 %s: %v", key, snap)
		}
	}
	for _, key := range []string{"offline_uploads", "tickets_taken"} {
		switch v := snap[key].(type) {
		case int:
			if v != 0 {
				t.Fatalf("未配置存储时 %s 应为 0: %v", key, snap)
			}
		case int64:
			if v != 0 {
				t.Fatalf("未配置存储时 %s 应为 0: %v", key, snap)
			}
		case float64:
			if v != 0 {
				t.Fatalf("未配置存储时 %s 应为 0: %v", key, snap)
			}
		default:
			t.Fatalf("%s 数值类型异常: %T", key, snap[key])
		}
	}
}
