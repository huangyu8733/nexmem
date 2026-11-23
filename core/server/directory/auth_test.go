package directory

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/nexmem/core/internal/dirsig"
	"github.com/nexmem/core/internal/identity"
)

func buildSigned(t *testing.T, ts *httptest.Server, signer *identity.Account, method, path string, body []byte, contentType string) *http.Request {
	t.Helper()
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(context.Background(), method, ts.URL+path, rdr)
	if err != nil {
		t.Fatalf("构造请求: %v", err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if signer != nil {
		signRequest(t, req, signer, body)
	}
	return req
}

func execRequest(t *testing.T, ts *httptest.Server, req *http.Request) (int, []byte, http.Header) {
	t.Helper()
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("执行请求 %s %s: %v", req.Method, req.URL.Path, err)
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取响应: %v", err)
	}
	return resp.StatusCode, out, resp.Header
}

// TestAuthRejectsForgeries 覆盖缺签名、伪造签名、篡改请求体与过期时间戳四类拒绝路径。
func TestAuthRejectsForgeries(t *testing.T) {
	s := newTestServer(t)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	fx := newProfileFixture(t, time.Now().Unix())

	t.Run("未携带签名", func(t *testing.T) {
		req := buildSigned(t, ts, nil, http.MethodPut, "/v1/profile", fx.raw, "application/x-protobuf")
		if status, body, _ := execRequest(t, ts, req); status != http.StatusUnauthorized {
			t.Fatalf("状态 %d，期望 401: %s", status, body)
		}
	})

	t.Run("公钥编码非法", func(t *testing.T) {
		req := buildSigned(t, ts, fx.account, http.MethodPut, "/v1/profile", fx.raw, "application/x-protobuf")
		req.Header.Set(dirsig.HeaderPub, "not-base64!")
		if status, _, _ := execRequest(t, ts, req); status != http.StatusUnauthorized {
			t.Fatalf("状态 %d，期望 401", status)
		}
	})

	t.Run("伪造签名", func(t *testing.T) {
		req := buildSigned(t, ts, fx.account, http.MethodPut, "/v1/profile", fx.raw, "application/x-protobuf")
		req.Header.Set(dirsig.HeaderSig, base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x11}, ed25519.SignatureSize)))
		if status, _, _ := execRequest(t, ts, req); status != http.StatusUnauthorized {
			t.Fatalf("状态 %d，期望 401", status)
		}
	})

	t.Run("篡改请求体", func(t *testing.T) {
		req := buildSigned(t, ts, fx.account, http.MethodPut, "/v1/profile", fx.raw, "application/x-protobuf")
		tampered := append(append([]byte{}, fx.raw...), 0x00)
		req.Body = io.NopCloser(bytes.NewReader(tampered))
		req.ContentLength = int64(len(tampered))
		req.GetBody = nil
		if status, _, _ := execRequest(t, ts, req); status != http.StatusUnauthorized {
			t.Fatalf("状态 %d，期望 401", status)
		}
	})

	t.Run("时间戳过期", func(t *testing.T) {
		stale := time.Now().Add(-10 * time.Minute).Unix()
		req := buildSigned(t, ts, nil, http.MethodPut, "/v1/profile", fx.raw, "application/x-protobuf")
		for k, v := range dirsig.Headers(fx.account, req.Method, req.URL.RequestURI(), stale, fx.raw) {
			req.Header.Set(k, v)
		}
		if status, body, _ := execRequest(t, ts, req); status != http.StatusUnauthorized {
			t.Fatalf("状态 %d，期望 401: %s", status, body)
		}
	})

	t.Run("签名账号与档案不一致", func(t *testing.T) {
		other := newProfileFixture(t, time.Now().Unix())
		req := buildSigned(t, ts, other.account, http.MethodPut, "/v1/profile", fx.raw, "application/x-protobuf")
		if status, body, _ := execRequest(t, ts, req); status != http.StatusForbidden {
			t.Fatalf("状态 %d，期望 403: %s", status, body)
		}
	})
}

// TestRateLimitPerAccount 验证单账号超限返回 429 且带 Retry-After。
func TestRateLimitPerAccount(t *testing.T) {
	s := newTestServerWithConfig(t, Config{
		PerIPPerSecond:          1 << 20,
		PerAccountPerSecond:     2,
		TakePerAccountPerSecond: 1 << 20,
	})
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	fx := newProfileFixture(t, time.Now().Unix())
	path := "/v1/profile/" + fx.id

	for i := 0; i < 2; i++ {
		req := buildSigned(t, ts, fx.account, http.MethodGet, path, nil, "")
		if status, _, _ := execRequest(t, ts, req); status == http.StatusTooManyRequests {
			t.Fatalf("第 %d 次请求不应被限流", i+1)
		}
	}

	req := buildSigned(t, ts, fx.account, http.MethodGet, path, nil, "")
	status, body, header := execRequest(t, ts, req)
	if status != http.StatusTooManyRequests {
		t.Fatalf("超限请求状态 %d，期望 429: %s", status, body)
	}
	if header.Get("Retry-After") == "" {
		t.Fatalf("429 响应缺少 Retry-After 头")
	}
}

// TestRateLimitTakeQuota 验证票据领取接口的独立账号配额。
func TestRateLimitTakeQuota(t *testing.T) {
	s := newTestServerWithConfig(t, Config{
		PerIPPerSecond:          1 << 20,
		PerAccountPerSecond:     1 << 20,
		TakePerAccountPerSecond: 2,
	})
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	fx := newProfileFixture(t, time.Now().Unix())
	batch := issueBatch(t, fx.profile.AccountPub, "device-1", 4, time.Hour)
	if status, body := postBatch(t, ts, fx.account, fx.id, batch); status != http.StatusOK {
		t.Fatalf("交存票据状态 %d: %s", status, body)
	}

	takePath := "/v1/inbox/" + fx.id + "/tickets?take=1"
	for i := 0; i < 2; i++ {
		req := buildSigned(t, ts, fx.account, http.MethodGet, takePath, nil, "")
		if status, body, _ := execRequest(t, ts, req); status != http.StatusOK {
			t.Fatalf("第 %d 次领取状态 %d: %s", i+1, status, body)
		}
	}
	req := buildSigned(t, ts, fx.account, http.MethodGet, takePath, nil, "")
	if status, body, _ := execRequest(t, ts, req); status != http.StatusTooManyRequests {
		t.Fatalf("第三次领取状态 %d，期望 429: %s", status, body)
	}
}

// TestRateLimitPerIP 验证未鉴权流量同样受来源 IP 限流约束。
func TestRateLimitPerIP(t *testing.T) {
	s := newTestServerWithConfig(t, Config{
		PerIPPerSecond:          2,
		PerAccountPerSecond:     1 << 20,
		TakePerAccountPerSecond: 1 << 20,
	})
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	for i := 0; i < 2; i++ {
		req := buildSigned(t, ts, nil, http.MethodGet, "/v1/profile/abc", nil, "")
		if status, _, _ := execRequest(t, ts, req); status != http.StatusUnauthorized {
			t.Fatalf("第 %d 次未签名请求状态 %d，期望 401", i+1, status)
		}
	}
	req := buildSigned(t, ts, nil, http.MethodGet, "/v1/profile/abc", nil, "")
	if status, _, _ := execRequest(t, ts, req); status != http.StatusTooManyRequests {
		t.Fatalf("超过 IP 配额状态 %d，期望 429", status)
	}
}
