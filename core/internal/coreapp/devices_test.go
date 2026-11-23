package coreapp

import (
	"context"
	"crypto/rand"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	lpcrypto "github.com/libp2p/go-libp2p/core/crypto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/directory"
	"github.com/nexmem/core/internal/identity"
	dirserver "github.com/nexmem/core/server/directory"
)

// devicePub 生成一对设备密钥并返回 libp2p 公钥的 protobuf 编码。
func devicePub(t *testing.T) []byte {
	t.Helper()
	key, _, err := lpcrypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		t.Fatalf("生成设备密钥: %v", err)
	}
	raw, err := lpcrypto.MarshalPublicKey(key.GetPublic())
	if err != nil {
		t.Fatalf("编码设备公钥: %v", err)
	}
	return raw
}

// TestMergeProfileDevices 校验多设备档案合并：保留其它设备、覆盖同设备旧证书、
// 剔除过期证书并按签发时间倒序（P6-21）。
func TestMergeProfileDevices(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成账号: %v", err)
	}
	ownPub := devicePub(t)
	otherPub := devicePub(t)
	stalePub := devicePub(t)

	own, err := acc.IssueDeviceCert(ownPub, "本机", identity.DefaultDeviceCertTTL)
	if err != nil {
		t.Fatalf("签发本机证书: %v", err)
	}
	other, err := acc.IssueDeviceCert(otherPub, "平板", identity.DefaultDeviceCertTTL)
	if err != nil {
		t.Fatalf("签发其它设备证书: %v", err)
	}
	oldOwn, err := acc.IssueDeviceCert(ownPub, "旧名字", time.Minute)
	if err != nil {
		t.Fatalf("签发旧本机证书: %v", err)
	}
	stale, err := acc.IssueDeviceCert(stalePub, "离线一年", time.Second)
	if err != nil {
		t.Fatalf("签发短期证书: %v", err)
	}

	existing := &nexmemv1.PublicProfile{Devices: []*nexmemv1.DeviceCert{oldOwn, other, stale}}
	later := time.Now().Add(3 * time.Second)
	got := mergeProfileDevices(existing, own, later)
	if len(got) != 2 {
		t.Fatalf("合并后应剩 2 张有效证书，实际 %d", len(got))
	}
	names := make(map[string]bool, len(got))
	for _, cert := range got {
		names[cert.DeviceName] = true
	}
	if !names["本机"] {
		t.Fatalf("同设备应以本机新证书为准，实际保留: %v", names)
	}
	if !names["平板"] {
		t.Fatalf("应保留其它设备证书，实际保留: %v", names)
	}
	if names["旧名字"] || names["离线一年"] {
		t.Fatalf("同设备旧证书与过期证书都应剔除，实际保留: %v", names)
	}

	// 上限截断：签发超过上限的证书只保留最近的 profileDeviceLimit 张。
	certs := make([]*nexmemv1.DeviceCert, 0, profileDeviceLimit+4)
	for i := 0; i < profileDeviceLimit+4; i++ {
		cert, err := acc.IssueDeviceCert(devicePub(t), "批量设备", identity.DefaultDeviceCertTTL)
		if err != nil {
			t.Fatalf("批量签发: %v", err)
		}
		certs = append(certs, cert)
	}
	capped := mergeProfileDevices(&nexmemv1.PublicProfile{Devices: certs}, nil, time.Now())
	if len(capped) != profileDeviceLimit {
		t.Fatalf("合并结果应截断到 %d，实际 %d", profileDeviceLimit, len(capped))
	}
}

// TestAccountDevicesGateway 校验 account.devices 读取公开档案里的设备列表，
// 并验证发布器合并同账号其它设备证书、离线声明不被本机关闭（P6-21）。
func TestAccountDevicesGateway(t *testing.T) {
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
	disabled := false
	if _, err := app.Start(context.Background(), Config{
		DataDir:        filepath.Join(root, "data"),
		Listen:         []string{"/ip4/127.0.0.1/tcp/0"},
		DirectoryURL:   httpSrv.URL,
		OfflineEnabled: &disabled,
		DeviceName:     "本机",
	}); err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	defer app.Stop()

	client, err := directory.New(directory.Config{BaseURL: httpSrv.URL, Signer: app.Account()})
	if err != nil {
		t.Fatalf("创建索引客户端: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// 档案由后台协程异步发布，轮询等待。
	deadline := time.Now().Add(8 * time.Second)
	for {
		if _, err := client.GetProfile(ctx, app.Account().Pub()); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("公开档案未发布: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// 模拟同账号第二台设备发布档案：只带自己的证书且声明离线可用。
	second, err := app.Account().IssueDeviceCert(devicePub(t), "平板", identity.DefaultDeviceCertTTL)
	if err != nil {
		t.Fatalf("签发第二台设备证书: %v", err)
	}
	profile := &nexmemv1.PublicProfile{
		OfflineEnabled: true,
		UpdatedAt:      time.Now().Unix(),
		Devices:        []*nexmemv1.DeviceCert{second},
	}
	if err := app.Account().SignProfile(profile); err != nil {
		t.Fatalf("签发档案: %v", err)
	}
	if err := client.PutProfile(ctx, profile); err != nil {
		t.Fatalf("上传档案: %v", err)
	}

	// 本机再次发布后应合并且不抹掉第二台设备。
	app.mu.RLock()
	publisher := app.offline
	app.mu.RUnlock()
	if publisher == nil {
		t.Fatal("发布器未装配")
	}
	if err := publisher.Publish(ctx); err != nil {
		t.Fatalf("重新发布档案: %v", err)
	}
	merged, err := client.GetProfile(ctx, app.Account().Pub())
	if err != nil {
		t.Fatalf("读取合并后档案: %v", err)
	}
	if len(merged.Devices) != 2 {
		t.Fatalf("合并后应含 2 台设备，实际 %d", len(merged.Devices))
	}
	if !merged.OfflineEnabled {
		t.Fatal("同账号其它设备声明离线可用时不应被本机关闭")
	}

	// 本机设备列表：共 2 台，恰好一台标记 current。
	data, ok := call(t, gw, "account.devices", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("account.devices 返回类型错误")
	}
	if data["found"] != true || data["self"] != true {
		t.Fatalf("found/self 应为 true: %v", data)
	}
	items, ok := data["items"].([]map[string]any)
	if !ok {
		if arr, ok2 := data["items"].([]any); ok2 {
			items = make([]map[string]any, 0, len(arr))
			for _, v := range arr {
				items = append(items, v.(map[string]any))
			}
		} else {
			t.Fatalf("items 类型错误: %T", data["items"])
		}
	}
	if len(items) != 2 {
		t.Fatalf("设备列表应有 2 项，实际 %d", len(items))
	}
	current := 0
	for _, item := range items {
		if item["current"] == true {
			current++
		}
		if item["device_id"] == "" {
			t.Fatalf("设备条目缺少 PeerID: %v", item)
		}
	}
	if current != 1 {
		t.Fatalf("应恰好一台本机设备，实际 %d", current)
	}

	// 显式传入本机账号与非法账号。
	selfData, ok := call(t, gw, "account.devices", map[string]any{"peer": app.Account().ID()}).(map[string]any)
	if !ok || selfData["self"] != true {
		t.Fatalf("本机账号查询应标记 self=true: %v", selfData)
	}
	if gerr := callErr(t, gw, "account.devices", map[string]any{"peer": "not-a-key"}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非法 peer 应返回 INVALID_ARG，实际 %s", gerr.Code)
	}
}
