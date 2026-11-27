package coreapp

import (
	"path/filepath"
	"testing"

	"github.com/nexmem/core/gateway"
)

// TestCoreDataDirAndAccountSwitch 验证多账号切换依赖的两个kernel能力：
// core.dataDir 回报当前数据目录，core.stop + core.start 可换目录并生成新账号。
func TestCoreDataDirAndAccountSwitch(t *testing.T) {
	root := t.TempDir()
	dirA := filepath.Join(root, "a")
	dirB := filepath.Join(root, "b")
	gw, _, _ := startApp(t, dirA, nil)

	info := call(t, gw, "core.dataDir", map[string]any{}).(map[string]any)
	if got := info["data_dir"]; got != dirA {
		t.Fatalf("core.dataDir=%v，期望 %s", got, dirA)
	}
	accountA := call(t, gw, "account.me", map[string]any{}).(map[string]any)

	call(t, gw, "core.stop", map[string]any{})
	if gerr := callErr(t, gw, "core.dataDir", map[string]any{}); gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("停止后 core.dataDir 错误码=%s，期望 NOT_STARTED", gerr.Code)
	}

	call(t, gw, "core.start", map[string]any{
		"config": map[string]any{
			"data_dir": dirB,
			"listen":   []string{"/ip4/127.0.0.1/tcp/0"},
		},
	})
	info = call(t, gw, "core.dataDir", map[string]any{}).(map[string]any)
	if got := info["data_dir"]; got != dirB {
		t.Fatalf("切换后 core.dataDir=%v，期望 %s", got, dirB)
	}
	accountB := call(t, gw, "account.me", map[string]any{}).(map[string]any)
	if accountA["account_id"] == accountB["account_id"] {
		t.Fatal("不同数据目录不应共用同一账号 ID")
	}
}
