package coreapp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/directory"
	"github.com/nexmem/core/internal/identity"
	dirserver "github.com/nexmem/core/server/directory"
)

func storageConfigDir(t *testing.T) string {
	t.Helper()
	return t.TempDir()
}

// TestOfflineStorageConfigureRoundTrip 覆盖 P6-04：保存配置后凭证密文落盘、
// storage.get 回显不含 sk、下次启动在未显式传 storage 时自动启用。
func TestOfflineStorageConfigureRoundTrip(t *testing.T) {
	dir := storageConfigDir(t)
	gw, app, _ := startApp(t, dir, nil)

	before := call(t, gw, "storage.get", map[string]any{}).(map[string]any)
	if before["configured"] != false {
		t.Fatalf("初始 configured=%v，期望 false", before["configured"])
	}

	saved := call(t, gw, "storage.configure", map[string]any{
		"endpoint":          "http://127.0.0.1:9010",
		"bucket":            "nexmem",
		"prefix":            "im_offline",
		"region":            "us-east-1",
		"ak":                "minioadmin",
		"sk":                "minioadmin",
		"path_style":        true,
		"delete_after_read": true, // C-02
	}).(map[string]any)
	if saved["configured"] != true || saved["enabled"] != true || saved["restart_required"] != true {
		t.Fatalf("保存返回不符合预期: %v", saved)
	}
	if saved["public"] != true {
		t.Fatalf("首次保存应默认对外公开: %v", saved)
	}

	raw, err := os.ReadFile(filepath.Join(dir, offlineStorageFile))
	if err != nil {
		t.Fatalf("读取配置文件: %v", err)
	}
	if bytes.Contains(raw, []byte("minioadmin")) {
		t.Fatal("配置文件中出现明文凭证")
	}

	got := call(t, gw, "storage.get", map[string]any{}).(map[string]any)
	if got["configured"] != true || got["enabled"] != true || got["public"] != true {
		t.Fatalf("回显不符合预期: %v", got)
	}
	if got["bucket"] != "nexmem" || got["endpoint"] != "http://127.0.0.1:9010" || got["path_style"] != true {
		t.Fatalf("回显字段不正确: %v", got)
	}
	if got["ak"] != "minioadmin" {
		t.Fatalf("回显 ak=%v", got["ak"])
	}
	if _, ok := got["sk"]; ok {
		t.Fatal("storage.get 不应回传 sk")
	}
	if got["delete_after_read"] != true {
		t.Fatalf("delete_after_read 回显 = %v，期望 true", got["delete_after_read"])
	}

	// 重启：不显式传 storage，应从落盘配置启用。
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}
	if err := restartApp(t, dir); err != nil {
		t.Fatalf("重启内核: %v", err)
	}
}

// restartApp 关闭当前内核并用同一数据目录、不传 storage 重新启动，返回新装配体。
func restartApp(t *testing.T, dir string) error {
	t.Helper()
	gw := gateway.New()
	app, err := New(gw, &eventLog{})
	if err != nil {
		return err
	}
	if _, err := app.Start(context.Background(), Config{
		DataDir: dir,
		Listen:  []string{"/ip4/127.0.0.1/tcp/0"},
	}); err != nil {
		return err
	}
	t.Cleanup(func() { _ = app.Stop() })

	app.mu.RLock()
	storage := app.cfg.Storage
	offline := offlineEnabled(app.cfg)
	app.mu.RUnlock()
	if storage == nil {
		t.Fatal("重启后未套用落盘存储配置")
	}
	if !offline {
		t.Fatal("重启后未声明可接收离线消息")
	}
	if storage.Bucket != "nexmem" || storage.AccessKey != "minioadmin" || storage.SecretKey != "minioadmin" || !storage.PathStyle {
		t.Fatalf("重启后存储配置不正确: %+v", *storage)
	}
	if !storage.DeleteAfterRead {
		t.Fatal("重启后 delete_after_read 应为 true（C-02）")
	}
	ks := identity.NewKeyStore(filepath.Join(dir, "keystore.master"))
	state, err := loadOfflineStorage(dir, ks)
	if err != nil || state == nil {
		t.Fatalf("读取落盘配置: state=%v err=%v", state, err)
	}
	if state.Prefix != "im_offline" || state.Region != "us-east-1" {
		t.Fatalf("落盘字段不正确: %+v", *state)
	}
	return nil
}

// TestOfflineStoragePublicToggle 覆盖 P6-25：关闭「对外公开」后落盘生效，
// 重启后公开档案立即撤回离线能力且不再交存票据，随时阻断新的外部写入。
func TestOfflineStoragePublicToggle(t *testing.T) {
	root := t.TempDir()
	srv, err := dirserver.New(filepath.Join(root, "directory.db"))
	if err != nil {
		t.Fatalf("启动索引服务: %v", err)
	}
	defer srv.Close()
	httpSrv := httptest.NewServer(srv.Handler())
	defer httpSrv.Close()

	dir := filepath.Join(root, "data")
	gw, app, _ := startApp(t, dir, nil)
	call(t, gw, "storage.configure", map[string]any{
		"endpoint": "http://127.0.0.1:9010",
		"bucket":   "nexmem",
		"region":   "us-east-1",
		"ak":       "minioadmin",
		"sk":       "minioadmin",
		"public":   false,
	})
	got := call(t, gw, "storage.get", map[string]any{}).(map[string]any)
	if got["configured"] != true || got["public"] != false {
		t.Fatalf("关闭公开后回显不符合预期: %v", got)
	}
	raw, err := os.ReadFile(filepath.Join(dir, offlineStorageFile))
	if err != nil {
		t.Fatalf("读取配置文件: %v", err)
	}
	if !bytes.Contains(raw, []byte(`"public": false`)) {
		t.Fatalf("落盘配置未记录 public=false: %s", raw)
	}
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}

	// 用同一数据目录重启并接入索引服务：本机仍可接收离线消息，但对外声明必须撤回。
	gw2 := gateway.New()
	app2, err := New(gw2, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if _, err := app2.Start(context.Background(), Config{
		DataDir:      dir,
		Listen:       []string{"/ip4/127.0.0.1/tcp/0"},
		DirectoryURL: httpSrv.URL,
	}); err != nil {
		t.Fatalf("重启内核: %v", err)
	}
	t.Cleanup(func() { _ = app2.Stop() })

	app2.mu.RLock()
	storage, offline := app2.cfg.Storage, offlineEnabled(app2.cfg)
	app2.mu.RUnlock()
	if storage == nil || storage.Public == nil || *storage.Public {
		t.Fatalf("重启后 public 未落盘生效: %+v", storage)
	}
	if !offline {
		t.Fatal("关闭对外公开不应影响本机接收离线消息")
	}

	client, err := directory.New(directory.Config{BaseURL: httpSrv.URL, Signer: app2.Account()})
	if err != nil {
		t.Fatalf("创建索引客户端: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	deadline := time.Now().Add(8 * time.Second)
	for {
		profile, perr := client.GetProfile(ctx, app2.Account().Pub())
		if perr == nil {
			if profile.OfflineEnabled {
				t.Fatal("关闭对外公开后公开档案不应声明离线能力")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("公开档案未发布: %v", perr)
		}
		time.Sleep(50 * time.Millisecond)
	}
	// 票据交存发生在档案发布之后；留出窗口确认确实没有交存。
	time.Sleep(300 * time.Millisecond)
	tickets, err := client.TakeTickets(ctx, app2.Account().Pub(), 1)
	if err == nil && len(tickets) != 0 {
		t.Fatalf("关闭对外公开后不应交存票据，实际 %d 张", len(tickets))
	}
}

// TestOfflineStorageConfigureReusesCredentials 覆盖「只改开关、凭证沿用上次保存」。
func TestOfflineStorageConfigureReusesCredentials(t *testing.T) {
	dir := storageConfigDir(t)
	gw, app, _ := startApp(t, dir, nil)

	call(t, gw, "storage.configure", map[string]any{
		"endpoint": "http://127.0.0.1:9010",
		"bucket":   "nexmem",
		"region":   "us-east-1",
		"ak":       "minioadmin",
		"sk":       "minioadmin",
	})
	// 仅关闭开关，不重填凭证。
	call(t, gw, "storage.configure", map[string]any{
		"endpoint": "http://127.0.0.1:9010",
		"bucket":   "nexmem",
		"region":   "us-east-1",
		"enabled":  false,
	})
	got := call(t, gw, "storage.get", map[string]any{}).(map[string]any)
	if got["enabled"] != false {
		t.Fatalf("关闭后 enabled=%v", got["enabled"])
	}
	if got["ak"] != "minioadmin" {
		t.Fatalf("关闭后凭证应保留，ak=%v", got["ak"])
	}

	// 关闭期间启动不应启用离线存储。
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}
	if err := restartDisabled(t, dir); err != nil {
		t.Fatalf("重启内核: %v", err)
	}
}

func restartDisabled(t *testing.T, dir string) error {
	t.Helper()
	gw := gateway.New()
	app, err := New(gw, &eventLog{})
	if err != nil {
		return err
	}
	if _, err := app.Start(context.Background(), Config{
		DataDir: dir,
		Listen:  []string{"/ip4/127.0.0.1/tcp/0"},
	}); err != nil {
		return err
	}
	t.Cleanup(func() { _ = app.Stop() })
	app.mu.RLock()
	storage, offline := app.cfg.Storage, offlineEnabled(app.cfg)
	app.mu.RUnlock()
	if storage != nil || offline {
		t.Fatalf("关闭状态不应启用离线存储: storage=%v offline=%v", storage != nil, offline)
	}
	return nil
}

// TestOfflineStorageConfigureValidation 覆盖参数校验与未启动错误码。
func TestOfflineStorageConfigureValidation(t *testing.T) {
	gw := gateway.New()
	if _, err := New(gw, &eventLog{}); err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if gerr := callErr(t, gw, "storage.get", map[string]any{}); gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动 storage.get 错误码=%s", gerr.Code)
	}
	if gerr := callErr(t, gw, "storage.configure", map[string]any{
		"endpoint": "http://127.0.0.1:9010",
		"bucket":   "nexmem",
	}); gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动 storage.configure 错误码=%s", gerr.Code)
	}

	dir := storageConfigDir(t)
	started, _, _ := startApp(t, dir, nil)
	if gerr := callErr(t, started, "storage.configure", map[string]any{"endpoint": "http://127.0.0.1:9010"}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺少 bucket 错误码=%s", gerr.Code)
	}
	if gerr := callErr(t, started, "storage.configure", map[string]any{
		"endpoint": "http://127.0.0.1:9010",
		"bucket":   "nexmem",
	}); gerr.Code != gateway.CodeInvalidArg || !strings.Contains(gerr.Message, "ak") {
		t.Fatalf("首次保存缺少凭证错误码=%s message=%s", gerr.Code, gerr.Message)
	}
}

// TestOfflineStorageTamperedSealedCredential 覆盖密文被篡改时不启用且不阻塞启动。
func TestOfflineStorageTamperedSealedCredential(t *testing.T) {
	dir := storageConfigDir(t)
	gw, _, _ := startApp(t, dir, nil)
	call(t, gw, "storage.configure", map[string]any{
		"endpoint": "http://127.0.0.1:9010",
		"bucket":   "nexmem",
		"region":   "us-east-1",
		"ak":       "minioadmin",
		"sk":       "minioadmin",
	})
	path := filepath.Join(dir, offlineStorageFile)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取配置: %v", err)
	}
	// 翻转 sk 密文的最后一个字节，模拟落盘密文被篡改。
	var rec map[string]any
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatalf("解析配置: %v", err)
	}
	sealed, ok := rec["sk_sealed"].(string)
	if !ok || sealed == "" {
		t.Fatal("配置缺少 sk_sealed")
	}
	var blob map[string]any
	if err := json.Unmarshal([]byte(sealed), &blob); err != nil {
		t.Fatalf("解析 sk 密文信封: %v", err)
	}
	ctText, _ := blob["ciphertext"].(string)
	ct, err := base64.StdEncoding.DecodeString(ctText)
	if err != nil || len(ct) == 0 {
		t.Fatalf("解码 sk 密文: %v", err)
	}
	ct[len(ct)-1] ^= 0xff
	blob["ciphertext"] = base64.StdEncoding.EncodeToString(ct)
	tamperedBlob, err := json.Marshal(blob)
	if err != nil {
		t.Fatalf("重新序列化 sk 密文: %v", err)
	}
	rec["sk_sealed"] = string(tamperedBlob)
	tampered, err := json.Marshal(rec)
	if err != nil {
		t.Fatalf("序列化篡改配置: %v", err)
	}
	if err := os.WriteFile(path, tampered, 0o600); err != nil {
		t.Fatalf("写入篡改配置: %v", err)
	}

	gw2 := gateway.New()
	app, err := New(gw2, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if _, err := app.Start(context.Background(), Config{
		DataDir: dir,
		Listen:  []string{"/ip4/127.0.0.1/tcp/0"},
	}); err != nil {
		t.Fatalf("篡改配置不应阻塞启动: %v", err)
	}
	t.Cleanup(func() { _ = app.Stop() })
	app.mu.RLock()
	storage := app.cfg.Storage
	app.mu.RUnlock()
	if storage != nil {
		t.Fatal("篡改配置不应启用离线存储")
	}
}
