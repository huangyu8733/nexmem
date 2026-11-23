package coreapp

import (
	"testing"

	"github.com/nexmem/core/gateway"
)

// TestQRPayloadParseRoundTrip 覆盖 P6-39：account.qrPayload 生成名片，
// account.qrParse 验签解析，字段一致；非法载荷与缺参均被拒绝。
func TestQRPayloadParseRoundTrip(t *testing.T) {
	dir := t.TempDir()
	gw, _, _ := startApp(t, dir, nil)

	me := call(t, gw, "account.me", map[string]any{}).(map[string]any)
	wantAccount, _ := me["account_id"].(string)
	wantDevice, _ := me["device_id"].(string)

	payload := call(t, gw, "account.qrPayload", map[string]any{}).(map[string]any)
	text, _ := payload["payload"].(string)
	if text == "" {
		t.Fatal("qrPayload 未返回 payload")
	}
	if payload["account_id"] != wantAccount {
		t.Fatalf("qrPayload account_id=%v，期望 %s", payload["account_id"], wantAccount)
	}

	card := call(t, gw, "account.qrParse", map[string]any{"payload": text}).(map[string]any)
	if card["account_id"] != wantAccount {
		t.Fatalf("qrParse account_id=%v，期望 %s", card["account_id"], wantAccount)
	}
	if card["device_id"] != wantDevice {
		t.Fatalf("qrParse device_id=%v，期望 %s", card["device_id"], wantDevice)
	}

	// 缺参拒绝。
	if gerr := callErr(t, gw, "account.qrParse", map[string]any{}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺参错误码 = %s，期望 INVALID_ARG", gerr.Code)
	}
	// 篡改/非法载荷拒绝。
	if gerr := callErr(t, gw, "account.qrParse", map[string]any{"payload": "not-a-card"}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非法载荷错误码 = %s，期望 INVALID_ARG", gerr.Code)
	}
}
