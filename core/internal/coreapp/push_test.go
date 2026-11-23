package coreapp

// 推送令牌上报（C-07）端到端：内核 gateway → 索引服务 push_tokens 表。

import "testing"

func TestPushRegisterUnregisterOverGateway(t *testing.T) {
	_, ts, _ := newDirectoryServer(t)
	gw, _ := startAppWithDirectory(t, t.TempDir(), ts.URL)

	const token = "device-token-abcdefghijklmnop"

	reg := call(t, gw, "push.register", map[string]any{
		"token": token,
		"env":   "production",
	}).(map[string]any)
	if reg["registered"] != true || asInt(reg["tokens"]) < 1 {
		t.Fatalf("登记返回不符合预期: %v", reg)
	}

	// 重复登记幂等：tokens 不增加。
	reg2 := call(t, gw, "push.register", map[string]any{
		"token": token,
		"env":   "production",
	}).(map[string]any)
	if reg2["tokens"] != reg["tokens"] {
		t.Fatalf("重复登记应幂等，首次 %v 再次 %v", reg["tokens"], reg2["tokens"])
	}

	unreg := call(t, gw, "push.unregister", map[string]any{
		"token": token,
		"env":   "production",
	}).(map[string]any)
	if unreg["removed"] != true {
		t.Fatalf("注销应返回 removed=true: %v", unreg)
	}
}

// asInt 兼容 gateway.Handle 直接返回的 int 与经 JSON 往返的 float64。
func asInt(v any) int {
	switch n := v.(type) {
	case int:
		return n
	case int64:
		return int(n)
	case float64:
		return int(n)
	default:
		return 0
	}
}

func TestPushTokenRejectsInvalidInput(t *testing.T) {
	_, ts, _ := newDirectoryServer(t)
	gw, _ := startAppWithDirectory(t, t.TempDir(), ts.URL)

	// 令牌过短。
	if gerr := callErr(t, gw, "push.register", map[string]any{"token": "short"}); gerr.Code != "INVALID_ARG" {
		t.Fatalf("短令牌应被拒，实际 %s", gerr.Error())
	}
	// 非法 env。
	if gerr := callErr(t, gw, "push.register", map[string]any{
		"token": "device-token-abcdefghijklmnop",
		"env":   "wrong-env",
	}); gerr.Code != "INVALID_ARG" {
		t.Fatalf("非法 env 应被拒，实际 %s", gerr.Error())
	}
}
