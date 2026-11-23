package directory

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/nexmem/core/internal/push"
)

// recordingPusher 记录唤醒推送调用，并按令牌返回预设错误。
type recordingPusher struct {
	mu    sync.Mutex
	got   []string
	calls int
	errs  map[string]error
}

func (p *recordingPusher) PushSilent(_ context.Context, account, deviceToken string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls++
	p.got = append(p.got, account+"|"+deviceToken)
	if err, ok := p.errs[deviceToken]; ok {
		return err
	}
	return nil
}

func (p *recordingPusher) snapshot() (int, []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, len(p.got))
	copy(out, p.got)
	return p.calls, out
}

func pushToken(i int) string {
	return fmt.Sprintf("%064x", i+1)
}

func pushServer(t *testing.T, p PushSender) (*Server, *httptest.Server) {
	t.Helper()
	s := newTestServerWithConfig(t, Config{
		PerIPPerSecond:          1 << 20,
		PerAccountPerSecond:     1 << 20,
		TakePerAccountPerSecond: 1 << 20,
		WakePerAccountPerSecond: 1 << 20,
		Push:                    p,
	})
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return s, ts
}

func TestPushTokenRegisterUnregister(t *testing.T) {
	_, ts := pushServer(t, nil)
	fixture := newProfileFixture(t, 1)

	body, _ := json.Marshal(map[string]string{"token": pushToken(0), "env": "production"})
	status, raw := doRequest(t, ts, fixture.account, http.MethodPost, "/v1/push/token", body, "application/json")
	if status != http.StatusOK {
		t.Fatalf("登记令牌应成功，实际 %d %s", status, raw)
	}
	var resp pushTokenResponse
	if err := json.Unmarshal(raw, &resp); err != nil || resp.Tokens != 1 {
		t.Fatalf("登记响应错误: %s", raw)
	}

	// 重复登记应幂等。
	status, raw = doRequest(t, ts, fixture.account, http.MethodPost, "/v1/push/token", body, "application/json")
	if status != http.StatusOK {
		t.Fatalf("重复登记应成功，实际 %d %s", status, raw)
	}
	_ = json.Unmarshal(raw, &resp)
	if resp.Tokens != 1 {
		t.Fatalf("重复登记后令牌数应为 1，实际 %d", resp.Tokens)
	}

	// 超限时裁剪到上限。
	for i := 1; i <= maxPushTokensPerAccount+2; i++ {
		body, _ := json.Marshal(map[string]string{"token": pushToken(i)})
		status, raw = doRequest(t, ts, fixture.account, http.MethodPost, "/v1/push/token", body, "application/json")
		if status != http.StatusOK {
			t.Fatalf("第 %d 个令牌登记失败: %d %s", i, status, raw)
		}
	}
	_ = json.Unmarshal(raw, &resp)
	if resp.Tokens != maxPushTokensPerAccount {
		t.Fatalf("令牌应裁剪到 %d，实际 %d", maxPushTokensPerAccount, resp.Tokens)
	}

	// 非法令牌与未签名请求均被拒绝。
	bad, _ := json.Marshal(map[string]string{"token": "short"})
	if status, _ := doRequest(t, ts, fixture.account, http.MethodPost, "/v1/push/token", bad, "application/json"); status != http.StatusBadRequest {
		t.Fatalf("非法令牌应返回 400，实际 %d", status)
	}
	if status, _ := doRequest(t, ts, nil, http.MethodPost, "/v1/push/token", body, "application/json"); status != http.StatusUnauthorized {
		t.Fatalf("未签名请求应返回 401，实际 %d", status)
	}

	// 注销后不再命中：重新登记一个确定存在的令牌再注销。
	freshBody, _ := json.Marshal(map[string]string{"token": pushToken(100)})
	if status, raw := doRequest(t, ts, fixture.account, http.MethodPost, "/v1/push/token", freshBody, "application/json"); status != http.StatusOK {
		t.Fatalf("重新登记令牌应成功: %d %s", status, raw)
	}
	delBody, _ := json.Marshal(map[string]string{"token": pushToken(100)})
	status, raw = doRequest(t, ts, fixture.account, http.MethodDelete, "/v1/push/token", delBody, "application/json")
	if status != http.StatusOK {
		t.Fatalf("注销令牌应成功，实际 %d %s", status, raw)
	}
	var delResp pushTokenDeleteResponse
	if err := json.Unmarshal(raw, &delResp); err != nil || !delResp.Removed {
		t.Fatalf("注销响应错误: %s", raw)
	}
}

func TestWakeSendsAndPrunesTokens(t *testing.T) {
	receiver := newProfileFixture(t, 1)
	sender := newProfileFixture(t, 1)
	badToken := pushToken(1)

	pusher := &recordingPusher{errs: map[string]error{
		badToken:     push.ErrUnregistered,
		pushToken(2): fmt.Errorf("APNs 暂时不可用"),
	}}
	srv, ts := pushServer(t, pusher)

	for i := 0; i < 3; i++ {
		body, _ := json.Marshal(map[string]string{"token": pushToken(i)})
		if status, raw := doRequest(t, ts, receiver.account, http.MethodPost, "/v1/push/token", body, "application/json"); status != http.StatusOK {
			t.Fatalf("登记令牌失败: %d %s", status, raw)
		}
	}

	status, raw := doRequest(t, ts, sender.account, http.MethodPost, "/v1/push/wake/"+receiver.id, nil, "")
	if status != http.StatusOK {
		t.Fatalf("唤醒应成功，实际 %d %s", status, raw)
	}
	var resp wakeResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("唤醒响应非法: %s", raw)
	}
	if !resp.Enabled || resp.Sent != 1 || resp.Removed != 1 || resp.Failed != 1 {
		t.Fatalf("唤醒统计错误: %+v", resp)
	}

	calls, got := pusher.snapshot()
	if calls != 3 || len(got) != 3 {
		t.Fatalf("应推送 3 个令牌，实际 %d %v", calls, got)
	}
	for _, item := range got {
		if want := receiver.id + "|"; len(item) <= len(want) || item[:len(want)] != want {
			t.Fatalf("推送账号不匹配: %s", item)
		}
	}

	// 已注销令牌应被清理，其余保留。
	n, err := srv.countPushTokens(context.Background(), receiver.id)
	if err != nil {
		t.Fatalf("统计令牌: %v", err)
	}
	if n != 2 {
		t.Fatalf("注销令牌未清理，剩余 %d", n)
	}
}

func TestWakeDisabledWhenNoPusher(t *testing.T) {
	_, ts := pushServer(t, nil)
	sender := newProfileFixture(t, 1)
	target := newProfileFixture(t, 1)

	status, raw := doRequest(t, ts, sender.account, http.MethodPost, "/v1/push/wake/"+target.id, nil, "")
	if status != http.StatusOK {
		t.Fatalf("未配置推送时应返回 200，实际 %d %s", status, raw)
	}
	var resp wakeResponse
	if err := json.Unmarshal(raw, &resp); err != nil || resp.Enabled {
		t.Fatalf("未配置推送应返回 enabled=false: %s", raw)
	}
}
