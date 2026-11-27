package coreapp

import (
	"strings"
	"testing"

	"github.com/nexmem/core/gateway"
)

// TestSettingsSnapshotRoundTrip 覆盖 P6-41：settings.exportSnapshot 导出，
// 清空后 importSnapshot 恢复；dry_run 不写入；篡改快照被拒绝。
func TestSettingsSnapshotRoundTrip(t *testing.T) {
	dir := t.TempDir()
	gw, _, _ := startApp(t, dir, nil)

	call(t, gw, "settings.set", map[string]any{"key": "ui.theme_mode", "value": "dark"})
	call(t, gw, "settings.set", map[string]any{"key": "relay.enabled", "value": "true"})
	// 内核内部 KV 不得进入设置快照。
	call(t, gw, "settings.set", map[string]any{"key": "net.peerbook", "value": "secret"})
	call(t, gw, "settings.set", map[string]any{"key": "fs.shares", "value": "secret"})

	exported := call(t, gw, "settings.exportSnapshot", map[string]any{}).(map[string]any)
	snapshot, _ := exported["snapshot"].(string)
	if snapshot == "" {
		t.Fatal("导出快照为空")
	}
	if exported["count"] != 2 {
		t.Fatalf("导出条目数 = %v，期望 2（内部 KV 不应导出）", exported["count"])
	}
	for _, internal := range []string{"peerbook", "fs.shares"} {
		if strings.Contains(snapshot, internal) {
			t.Fatalf("快照包含内部键 %s: %s", internal, snapshot)
		}
	}

	// dry_run：仅校验不写入，applied=0。
	dr := call(t, gw, "settings.importSnapshot", map[string]any{
		"snapshot": snapshot, "dry_run": true,
	}).(map[string]any)
	if dr["applied"] != 0 || dr["dry_run"] != true {
		t.Fatalf("dry_run 返回 = %v，期望 applied=0/dry_run=true", dr)
	}

	// 清除后导入恢复。
	call(t, gw, "settings.set", map[string]any{"key": "ui.theme_mode", "value": ""})
	call(t, gw, "settings.set", map[string]any{"key": "relay.enabled", "value": ""})
	before := call(t, gw, "settings.get", map[string]any{"key": "ui.theme_mode"}).(map[string]any)
	if before["found"] != false {
		t.Fatal("清除后仍 found=true")
	}
	imported := call(t, gw, "settings.importSnapshot", map[string]any{
		"snapshot": snapshot,
	}).(map[string]any)
	if imported["applied"] != 2 {
		t.Fatalf("导入条目数 = %v，期望 2", imported["applied"])
	}
	got := call(t, gw, "settings.get", map[string]any{"key": "ui.theme_mode"}).(map[string]any)
	if got["value"] != "dark" {
		t.Fatalf("恢复后 value=%v，期望 dark", got["value"])
	}

	// 篡改快照拒绝。
	alt := 'A'
	if snapshot[len(snapshot)-1] == 'A' {
		alt = 'B'
	}
	tampered := snapshot[:len(snapshot)-1] + string(alt)
	if gerr := callErr(t, gw, "settings.importSnapshot", map[string]any{
		"snapshot": tampered,
	}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("篡改快照错误码 = %s，期望 INVALID_ARG", gerr.Code)
	}
	// 缺参拒绝。
	if gerr := callErr(t, gw, "settings.importSnapshot", map[string]any{}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺参错误码 = %s，期望 INVALID_ARG", gerr.Code)
	}
}
