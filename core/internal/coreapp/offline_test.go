package coreapp

import (
	"bytes"
	"context"
	"encoding/hex"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/directory"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/identity"
	dirserver "github.com/nexmem/core/server/directory"
	"net/http/httptest"
)

// TestOfflineChannelAssembly 校验 core.start 把档案发布、票据交存与
// 单聊离线收发/拉取装配到一起（P3-06/P3-07 生产接线）。
func TestOfflineChannelAssembly(t *testing.T) {
	root := t.TempDir()
	srv, err := dirserver.New(filepath.Join(root, "directory.db"))
	if err != nil {
		t.Fatalf("启动索引服务: %v", err)
	}
	defer srv.Close()
	httpSrv := httptest.NewServer(srv.Handler())
	defer httpSrv.Close()

	gw := gateway.New()
	app, err := New(gw, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	enabled := true
	if _, err := app.Start(context.Background(), Config{
		DataDir:        filepath.Join(root, "data"),
		Listen:         []string{"/ip4/127.0.0.1/tcp/0"},
		DirectoryURL:   httpSrv.URL,
		OfflineEnabled: &enabled,
		DeviceName:     "test-device",
		Storage: &StorageConfig{
			Endpoint:  "http://127.0.0.1:1",
			Region:    "us-east-1",
			Bucket:    "inbox",
			AccessKey: "ak",
			SecretKey: "sk",
			PathStyle: true,
		},
	}); err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	defer app.Stop()

	app.mu.RLock()
	dmSvc := app.dmSvc
	app.mu.RUnlock()
	if dmSvc == nil {
		t.Fatal("单聊服务未装配")
	}
	if !dmSvc.OfflineEnabled() {
		t.Fatal("配置了存储与索引服务后应启用离线投递")
	}
	if !dmSvc.OfflineFetchEnabled() {
		t.Fatal("配置了存储后应启用离线拉取")
	}

	client, err := directory.New(directory.Config{BaseURL: httpSrv.URL, Signer: app.Account()})
	if err != nil {
		t.Fatalf("创建索引客户端: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// 档案与票据由后台协程异步发布，轮询等待。
	var profile *nexmemv1.PublicProfile
	deadline := time.Now().Add(8 * time.Second)
	for {
		p, err := client.GetProfile(ctx, app.Account().Pub())
		if err == nil {
			profile = p
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("公开档案未发布: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(profile.Devices) != 1 {
		t.Fatalf("档案应含 1 张设备证书，实际 %d", len(profile.Devices))
	}
	if err := identity.VerifyDeviceCert(profile.Devices[0], time.Now()); err != nil {
		t.Fatalf("设备证书无效: %v", err)
	}
	if profile.Devices[0].DeviceName != "test-device" {
		t.Fatalf("设备名应为 test-device，实际 %q", profile.Devices[0].DeviceName)
	}
	if !profile.OfflineEnabled {
		t.Fatal("公开档案应声明可接收离线消息")
	}
	if len(profile.AccountXPub) != 32 {
		t.Fatalf("档案 X25519 公钥长度应为 32，实际 %d", len(profile.AccountXPub))
	}

	// 票据在档案之后交存，需单独轮询，避免读到"档案已发布但票据未交存"的中间态。
	var tickets []blob.Ticket
	for {
		tickets, err = client.TakeTickets(ctx, app.Account().Pub(), 1)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("领取票据失败: %v", err)
		}
		// 低于票据接口 10/s 的账号配额，避免轮询本身触发 429。
		time.Sleep(150 * time.Millisecond)
	}
	prefix := blob.InboxPrefix(app.Account().Pub())
	if len(tickets) != 1 || !strings.HasPrefix(tickets[0].Key, prefix) {
		t.Fatalf("票据对象键应位于本机收件箱前缀下: %+v", tickets)
	}
}

// TestOfflineChannelDisabledWithoutStorage 校验未配置存储时不声明离线能力，
// 也不会向索引服务交存票据。
func TestOfflineChannelDisabledWithoutStorage(t *testing.T) {
	root := t.TempDir()
	srv, err := dirserver.New(filepath.Join(root, "directory.db"))
	if err != nil {
		t.Fatalf("启动索引服务: %v", err)
	}
	defer srv.Close()
	httpSrv := httptest.NewServer(srv.Handler())
	defer httpSrv.Close()

	gw := gateway.New()
	app, err := New(gw, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if _, err := app.Start(context.Background(), Config{
		DataDir:      filepath.Join(root, "data"),
		Listen:       []string{"/ip4/127.0.0.1/tcp/0"},
		DirectoryURL: httpSrv.URL,
	}); err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	defer app.Stop()

	app.mu.RLock()
	dmSvc := app.dmSvc
	app.mu.RUnlock()
	if dmSvc.OfflineEnabled() || dmSvc.OfflineFetchEnabled() {
		t.Fatal("未配置存储时不应启用离线通道")
	}

	client, err := directory.New(directory.Config{BaseURL: httpSrv.URL, Signer: app.Account()})
	if err != nil {
		t.Fatalf("创建索引客户端: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	deadline := time.Now().Add(8 * time.Second)
	for {
		p, err := client.GetProfile(ctx, app.Account().Pub())
		if err == nil {
			if p.OfflineEnabled {
				t.Fatal("未配置存储时档案不应声明离线能力")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("公开档案未发布: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// TestOfflineDisabledPeerSurfacedToUI 是 P3-09 的生产链路用例：
// 对端在线时正常直连发送；对端下线且档案声明未开启离线存储时，
// message.updated 必须带 OFFLINE_STORAGE_DISABLED 原因码，
// 壳层据此常驻「仅支持在线发送」提示。
func TestOfflineDisabledPeerSurfacedToUI(t *testing.T) {
	root := t.TempDir()
	srv, err := dirserver.New(filepath.Join(root, "directory.db"))
	if err != nil {
		t.Fatalf("启动索引服务: %v", err)
	}
	defer srv.Close()
	httpSrv := httptest.NewServer(srv.Handler())
	defer httpSrv.Close()

	var (
		mu   sync.Mutex
		appB *App
		pubB []byte
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if appB != nil && bytes.Equal(pubB, accountPub) {
			return targetOf(appB), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	// 发送端必须配置存储才会启用离线投递；端点不可达不影响本用例（不会走到上传）。
	gwA := gateway.New()
	logA := &eventLog{}
	appA, err := New(gwA, logA)
	if err != nil {
		t.Fatalf("创建发送端装配体: %v", err)
	}
	appA.SetPeerResolver(resolver)
	if _, err := appA.Start(context.Background(), Config{
		DataDir:      filepath.Join(root, "a"),
		Listen:       []string{"/ip4/127.0.0.1/tcp/0"},
		DirectoryURL: httpSrv.URL,
		Storage: &StorageConfig{
			Endpoint:  "http://127.0.0.1:1",
			Region:    "us-east-1",
			Bucket:    "inbox",
			AccessKey: "ak",
			SecretKey: "sk",
			PathStyle: true,
		},
	}); err != nil {
		t.Fatalf("启动发送端内核: %v", err)
	}
	defer appA.Stop()

	// 接收端不配置存储：公开档案声明「未开启离线存储」。
	_, appBStarted, logB := startGateApp(t, filepath.Join(root, "b"), httpSrv.URL, nil)
	mu.Lock()
	appB = appBStarted
	pubB = appBStarted.Account().Pub()
	mu.Unlock()

	// 等待接收端档案发布，避免落到「档案尚未发布」的中间态。
	client, err := directory.New(directory.Config{BaseURL: httpSrv.URL, Signer: appB.Account()})
	if err != nil {
		t.Fatalf("创建索引客户端: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	deadline := time.Now().Add(8 * time.Second)
	for {
		p, perr := client.GetProfile(ctx, pubB)
		if perr == nil {
			if p.OfflineEnabled {
				t.Fatal("未配置存储时档案不应声明离线能力")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("接收端档案未发布: %v", perr)
		}
		time.Sleep(50 * time.Millisecond)
	}

	peerID := hex.EncodeToString(pubB)
	send := func(text string) string {
		t.Helper()
		data, ok := call(t, gwA, "dm.sendText", map[string]any{
			"peer": peerID,
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

	// 在线：直连送达，事件无原因码。
	onlineUUID := send("在线可达")
	if !hasUpdate(t, logA, onlineUUID, "sent", "") {
		t.Fatal("在线发送应上报无原因码的 sent 事件")
	}
	waitFor(t, propagationWait, func() bool { return logB.count("message.new") == 1 })

	// 下线：对端档案未开启离线存储，只能等其上线后补发。
	if err := appB.Stop(); err != nil {
		t.Fatalf("停止接收端内核: %v", err)
	}
	offlineUUID := send("离线不可达")
	if !hasUpdate(t, logA, offlineUUID, "failed", dm.ReasonOfflineStorageDisabled) {
		t.Fatalf("应上报带 %s 原因码的 failed 事件，实际 %v",
			dm.ReasonOfflineStorageDisabled, updatesOf(logA))
	}
}

// hasUpdate 判断事件日志里是否存在指定状态与原因码的 message.updated。
func hasUpdate(t *testing.T, log *eventLog, msgUUID, state, reason string) bool {
	t.Helper()
	for _, data := range updatesOf(log) {
		reasonGot, _ := data["reason"].(string)
		if data["msg_uuid"] == msgUUID && data["state"] == state && reasonGot == reason {
			return true
		}
	}
	return false
}

// updatesOf 取出全部 message.updated 事件的数据体，供断言失败时打印。
func updatesOf(log *eventLog) []map[string]any {
	log.mu.Lock()
	defer log.mu.Unlock()
	var out []map[string]any
	for _, e := range log.events {
		if e.name != "message.updated" {
			continue
		}
		if data, ok := e.data.(map[string]any); ok {
			out = append(out, data)
		}
	}
	return out
}
