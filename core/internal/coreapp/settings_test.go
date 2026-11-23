package coreapp

import (
	"context"
	"strings"
	"testing"

	"github.com/nexmem/core/gateway"
)

// TestSettingsRoundTrip 覆盖 P6-15：settings.get 未设置时 found=false，
// settings.set 写入后可读回；空串清除；键与值非法时返回 INVALID_ARG。
func TestSettingsRoundTrip(t *testing.T) {
	dir := t.TempDir()
	gw, _, _ := startApp(t, dir, nil)

	missing := call(t, gw, "settings.get", map[string]any{"key": "ui.theme_mode"}).(map[string]any)
	if missing["found"] != false || missing["value"] != "" || missing["key"] != "ui.theme_mode" {
		t.Fatalf("未设置时返回不符合预期: %v", missing)
	}

	call(t, gw, "settings.set", map[string]any{"key": "ui.theme_mode", "value": "dark"})
	got := call(t, gw, "settings.get", map[string]any{"key": "ui.theme_mode"}).(map[string]any)
	if got["found"] != true || got["value"] != "dark" {
		t.Fatalf("写入后读取不符合预期: %v", got)
	}

	// 覆盖写。
	call(t, gw, "settings.set", map[string]any{"key": "ui.theme_mode", "value": "light"})
	got = call(t, gw, "settings.get", map[string]any{"key": "ui.theme_mode"}).(map[string]any)
	if got["value"] != "light" {
		t.Fatalf("覆盖写后 value=%v", got["value"])
	}

	// 空串清除。
	call(t, gw, "settings.set", map[string]any{"key": "ui.theme_mode", "value": ""})
	got = call(t, gw, "settings.get", map[string]any{"key": "ui.theme_mode"}).(map[string]any)
	if got["found"] != false {
		t.Fatalf("清除后 found=%v", got["found"])
	}
	// 清除不存在的键是幂等的。
	call(t, gw, "settings.set", map[string]any{"key": "ui.theme_mode", "value": ""})
}

// TestSettingsPersistsAcrossRestart 覆盖设置随本地库持久化，重启后仍可读回。
func TestSettingsPersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	gw, app, _ := startApp(t, dir, nil)
	call(t, gw, "settings.set", map[string]any{"key": "ui.theme_mode", "value": "light"})
	if err := app.Stop(); err != nil {
		t.Fatalf("停止内核: %v", err)
	}

	gw2 := gateway.New()
	app2, err := New(gw2, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if _, err := app2.Start(context.Background(), Config{DataDir: dir, Listen: []string{"/ip4/127.0.0.1/tcp/0"}}); err != nil {
		t.Fatalf("重启内核: %v", err)
	}
	t.Cleanup(func() { _ = app2.Stop() })

	got := call(t, gw2, "settings.get", map[string]any{"key": "ui.theme_mode"}).(map[string]any)
	if got["found"] != true || got["value"] != "light" {
		t.Fatalf("重启后读取不符合预期: %v", got)
	}
}

// TestSettingsRejectsInvalidInput 覆盖键非法、值超限与内核未启动的错误码。
func TestSettingsRejectsInvalidInput(t *testing.T) {
	dir := t.TempDir()
	gw, _, _ := startApp(t, dir, nil)

	badKeys := []string{"", "  ", "UI.THEME", "ui theme", "ui..theme", strings.Repeat("a", maxSettingKeyLen+1)}
	for _, key := range badKeys {
		if gerr := callErr(t, gw, "settings.get", map[string]any{"key": key}); gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("key=%q 期望 INVALID_ARG，实际 %s", key, gerr.Code)
		}
		if gerr := callErr(t, gw, "settings.set", map[string]any{"key": key, "value": "x"}); gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("key=%q 写入期望 INVALID_ARG，实际 %s", key, gerr.Code)
		}
	}
	if gerr := callErr(t, gw, "settings.set", map[string]any{
		"key":   "ui.theme_mode",
		"value": strings.Repeat("x", maxSettingValueBytes+1),
	}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("超限值期望 INVALID_ARG，实际 %s", gerr.Code)
	}

	// 未启动的内核返回 NOT_STARTED。
	idle := gateway.New()
	if _, err := New(idle, &eventLog{}); err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if gerr := callErr(t, idle, "settings.get", map[string]any{"key": "ui.theme_mode"}); gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动期望 NOT_STARTED，实际 %s", gerr.Code)
	}
}
