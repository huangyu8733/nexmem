package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func newTestKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("生成 P-256 私钥: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("编码私钥: %v", err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func newTestClient(t *testing.T, baseURL string, key []byte, now func() time.Time) *Client {
	t.Helper()
	c, err := New(Config{
		KeyID:         "KEY1234567",
		TeamID:        "TEAM123456",
		BundleID:      "io.nexmem.app",
		PrivateKeyPEM: key,
		BaseURL:       baseURL,
		Now:           now,
	})
	if err != nil {
		t.Fatalf("创建推送客户端: %v", err)
	}
	return c
}

func newPushServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	srv := httptest.NewUnstartedServer(handler)
	srv.EnableHTTP2 = true
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv
}

func h2Client(srv *httptest.Server) *http.Client {
	tr := srv.Client().Transport.(*http.Transport).Clone()
	tr.ForceAttemptHTTP2 = true
	return &http.Client{Transport: tr, Timeout: 5 * time.Second}
}

func TestNewValidation(t *testing.T) {
	_, pemKey := newTestKey(t)
	cases := []struct {
		name string
		cfg  Config
	}{
		{"缺少 KeyID", Config{TeamID: "T", BundleID: "B", PrivateKeyPEM: pemKey}},
		{"缺少 TeamID", Config{KeyID: "K", BundleID: "B", PrivateKeyPEM: pemKey}},
		{"缺少 BundleID", Config{KeyID: "K", TeamID: "T", PrivateKeyPEM: pemKey}},
		{"缺少私钥", Config{KeyID: "K", TeamID: "T", BundleID: "B"}},
		{"私钥非 PEM", Config{KeyID: "K", TeamID: "T", BundleID: "B", PrivateKeyPEM: []byte("nope")}},
	}
	for _, tc := range cases {
		if _, err := New(tc.cfg); err == nil {
			t.Fatalf("%s 应失败", tc.name)
		}
	}

	// P-384 私钥不符合 APNs 要求。
	p384, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(p384)
	_, err = New(Config{KeyID: "K", TeamID: "T", BundleID: "B",
		PrivateKeyPEM: pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})})
	if err == nil {
		t.Fatal("非 P-256 私钥应失败")
	}
}

func TestPushSilentSuccess(t *testing.T) {
	key, pemKey := newTestKey(t)
	var (
		gotPath, gotTopic, gotType, gotPriority, gotProto string
		gotPayload                                        map[string]any
	)
	srv := newPushServer(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotTopic = r.Header.Get("apns-topic")
		gotType = r.Header.Get("apns-push-type")
		gotPriority = r.Header.Get("apns-priority")
		gotProto = r.Proto
		auth := r.Header.Get("Authorization")
		token := auth[len("bearer "):]
		if err := VerifyToken(token, &key.PublicKey, "TEAM123456"); err != nil {
			t.Errorf("鉴权 JWT 非法: %v", err)
		}
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &gotPayload); err != nil {
			t.Errorf("载荷非 JSON: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	})

	c := newTestClient(t, srv.URL, pemKey, time.Now)
	c.hc = h2Client(srv)
	if err := c.PushSilent(context.Background(), "Acc-1", "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"); err != nil {
		t.Fatalf("推送应成功: %v", err)
	}

	if gotPath != "/3/device/aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("推送路径错误: %s", gotPath)
	}
	if gotTopic != "io.nexmem.app" || gotType != "background" || gotPriority != "5" {
		t.Fatalf("推送头部错误: topic=%s type=%s priority=%s", gotTopic, gotType, gotPriority)
	}
	if gotProto != "HTTP/2.0" {
		t.Fatalf("APNs 必须使用 HTTP/2，实际 %s", gotProto)
	}
	aps, _ := gotPayload["aps"].(map[string]any)
	if aps == nil || aps["content-available"] != float64(1) {
		t.Fatalf("aps 载荷错误: %v", gotPayload["aps"])
	}
	if gotPayload["acct"] != "Acc-1" || gotPayload["has_offline"] != true {
		t.Fatalf("唤醒字段错误: %v", gotPayload)
	}
	if _, ok := gotPayload["text"]; ok {
		t.Fatal("唤醒推送不得包含正文")
	}
}

func TestPushSilentCachesToken(t *testing.T) {
	key, pemKey := newTestKey(t)
	var mu sync.Mutex
	var tokens []string
	srv := newPushServer(t, func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		token := auth[len("bearer "):]
		if err := VerifyToken(token, &key.PublicKey, "TEAM123456"); err != nil {
			t.Errorf("鉴权 JWT 非法: %v", err)
		}
		mu.Lock()
		tokens = append(tokens, token)
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})

	now := time.Now()
	c := newTestClient(t, srv.URL, pemKey, func() time.Time { return now })
	c.hc = h2Client(srv)
	for i := 0; i < 2; i++ {
		if err := c.PushSilent(context.Background(), "Acc-1", "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"); err != nil {
			t.Fatalf("第 %d 次推送应成功: %v", i+1, err)
		}
	}
	if len(tokens) != 2 || tokens[0] != tokens[1] {
		t.Fatalf("同一时间窗内 JWT 应复用，实际 %v", tokens)
	}
}

func TestPushSilentRetriesServerError(t *testing.T) {
	_, pemKey := newTestKey(t)
	var attempts int
	srv := newPushServer(t, func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts == 1 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"reason":"ServiceUnavailable"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
	})

	c := newTestClient(t, srv.URL, pemKey, time.Now)
	c.hc = h2Client(srv)
	if err := c.PushSilent(context.Background(), "Acc-1", "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"); err != nil {
		t.Fatalf("5xx 后重试应成功: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("应重试一次，实际尝试 %d 次", attempts)
	}
}

func TestPushSilentRefreshesAuthToken(t *testing.T) {
	key, pemKey := newTestKey(t)
	var mu sync.Mutex
	var tokens []string
	srv := newPushServer(t, func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		token := auth[len("bearer "):]
		if err := VerifyToken(token, &key.PublicKey, "TEAM123456"); err != nil {
			t.Errorf("鉴权 JWT 非法: %v", err)
		}
		mu.Lock()
		tokens = append(tokens, token)
		first := len(tokens) == 1
		mu.Unlock()
		if first {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"reason":"ExpiredProviderToken"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
	})

	base := time.Now()
	var clockMu sync.Mutex
	step := 0
	now := func() time.Time {
		clockMu.Lock()
		defer clockMu.Unlock()
		step += 2
		return base.Add(time.Duration(step) * time.Second)
	}
	c := newTestClient(t, srv.URL, pemKey, now)
	c.hc = h2Client(srv)
	if err := c.PushSilent(context.Background(), "Acc-1", "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"); err != nil {
		t.Fatalf("403 后刷新 JWT 应成功: %v", err)
	}
	if len(tokens) != 2 || tokens[0] == tokens[1] {
		t.Fatalf("应重新签发 JWT，实际 %v", tokens)
	}
}

func TestPushSilentClassifiesPermanentErrors(t *testing.T) {
	_, pemKey := newTestKey(t)
	cases := []struct {
		status int
		reason string
		want   error
	}{
		{http.StatusBadRequest, "BadDeviceToken", ErrBadToken},
		{http.StatusGone, "Unregistered", ErrUnregistered},
	}
	for _, tc := range cases {
		srv := newPushServer(t, func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(`{"reason":"` + tc.reason + `"}`))
		})
		c := newTestClient(t, srv.URL, pemKey, time.Now)
		c.hc = h2Client(srv)
		err := c.PushSilent(context.Background(), "Acc-1", "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899")
		if !errors.Is(err, tc.want) {
			t.Fatalf("状态 %d 应返回 %v，实际 %v", tc.status, tc.want, err)
		}
		srv.Close()
	}
}
