package coreapp

import (
	"context"
	"crypto/rand"
	"fmt"
	"testing"

	lpcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"

	"github.com/nexmem/core/gateway"
)

// startRelayTestApp 以指定中继入参启动内核，返回网关与装配体；调用方负责 Stop。
func startRelayTestApp(t *testing.T, dir string, relayAddrs []string) (*gateway.Gateway, *App) {
	t.Helper()
	gw := gateway.New()
	app, err := New(gw, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if _, err := app.Start(context.Background(), Config{
		DataDir:    dir,
		Listen:     []string{"/ip4/127.0.0.1/tcp/0"},
		RelayAddrs: relayAddrs,
	}); err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	return gw, app
}

// relayAddrsOf 读取当前装配使用的中继地址（测试断言用）。
func relayAddrsOf(a *App) []string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return append([]string(nil), a.cfg.RelayAddrs...)
}

// relayTestAddr 生成一个合法 multiaddr，PeerID 随机但可解析。
func relayTestAddr(t *testing.T) string {
	t.Helper()
	key, _, err := lpcrypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		t.Fatalf("生成测试密钥: %v", err)
	}
	id, err := peer.IDFromPrivateKey(key)
	if err != nil {
		t.Fatalf("推导 PeerID: %v", err)
	}
	return fmt.Sprintf("/ip4/127.0.0.1/tcp/4001/p2p/%s", id.String())
}

// P6-20 验收：设置页开启中继并填写地址后，重启内核按设置启用；默认关闭。
func TestRelaySettingsAppliedOnRestart(t *testing.T) {
	dir := t.TempDir()
	addr := relayTestAddr(t)

	gw, app := startRelayTestApp(t, dir, nil)
	if got := relayAddrsOf(app); len(got) != 0 {
		_ = app.Stop()
		t.Fatalf("默认应关闭中继，实际 %v", got)
	}
	call(t, gw, "settings.set", map[string]any{"key": relayEnabledSettingKey, "value": "true"})
	call(t, gw, "settings.set", map[string]any{"key": relayAddrsSettingKey, "value": addr + "\n" + addr})
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}

	gw2, app2 := startRelayTestApp(t, dir, nil)
	defer func() { _ = app2.Stop() }()
	got := relayAddrsOf(app2)
	if len(got) != 1 || got[0] != addr {
		t.Fatalf("重启后应启用 1 个去重后的中继，实际 %v", got)
	}
	policy := relayPolicy(got)
	if !policy.Enabled || len(policy.Relays) != 1 {
		t.Fatalf("中继策略未启用: %+v", policy)
	}
	_ = gw2
}

// 关闭开关时即使留有地址也不启用。
func TestRelaySettingsDisabledKeepsRelayOff(t *testing.T) {
	dir := t.TempDir()
	addr := relayTestAddr(t)

	gw, app := startRelayTestApp(t, dir, nil)
	call(t, gw, "settings.set", map[string]any{"key": relayEnabledSettingKey, "value": "false"})
	call(t, gw, "settings.set", map[string]any{"key": relayAddrsSettingKey, "value": addr})
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}

	_, app2 := startRelayTestApp(t, dir, nil)
	defer func() { _ = app2.Stop() }()
	if got := relayAddrsOf(app2); len(got) != 0 {
		t.Fatalf("开关关闭时不应启用中继，实际 %v", got)
	}
}

// 中继地址非法时忽略并保持关闭，不影响内核启动。
func TestRelaySettingsIgnoresInvalidAddrs(t *testing.T) {
	dir := t.TempDir()

	gw, app := startRelayTestApp(t, dir, nil)
	call(t, gw, "settings.set", map[string]any{"key": relayEnabledSettingKey, "value": "true"})
	call(t, gw, "settings.set", map[string]any{"key": relayAddrsSettingKey, "value": "not-a-multiaddr,\n/ip4/1.2.3.4/tcp/1"})
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}

	_, app2 := startRelayTestApp(t, dir, nil)
	defer func() { _ = app2.Stop() }()
	if got := relayAddrsOf(app2); len(got) != 0 {
		t.Fatalf("非法地址不应启用中继，实际 %v", got)
	}
}

// 显式入参优先于设置页保存的地址。
func TestRelaySettingsExplicitConfigWins(t *testing.T) {
	dir := t.TempDir()
	stored := relayTestAddr(t)
	explicit := relayTestAddr(t)

	gw, app := startRelayTestApp(t, dir, nil)
	call(t, gw, "settings.set", map[string]any{"key": relayEnabledSettingKey, "value": "true"})
	call(t, gw, "settings.set", map[string]any{"key": relayAddrsSettingKey, "value": stored})
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}

	_, app2 := startRelayTestApp(t, dir, []string{explicit})
	defer func() { _ = app2.Stop() }()
	got := relayAddrsOf(app2)
	if len(got) != 1 || got[0] != explicit {
		t.Fatalf("显式入参应优先，实际 %v", got)
	}
}

// splitRelayAddrs 拆分换行/逗号、去空白、去重。
func TestSplitRelayAddrs(t *testing.T) {
	raw := " /ip4/127.0.0.1/tcp/1/p2p/x \r\n/ip4/127.0.0.1/tcp/2/p2p/y,/ip4/127.0.0.1/tcp/1/p2p/x\n\n"
	got := splitRelayAddrs(raw)
	want := []string{"/ip4/127.0.0.1/tcp/1/p2p/x", "/ip4/127.0.0.1/tcp/2/p2p/y"}
	if len(got) != len(want) {
		t.Fatalf("拆分结果 %v，期望 %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("拆分结果 %v，期望 %v", got, want)
		}
	}
}
