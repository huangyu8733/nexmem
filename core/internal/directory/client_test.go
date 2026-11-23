package directory

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/dirsig"
	"github.com/nexmem/core/internal/identity"
)

func TestWake(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	mode := "ok"
	var gotMethod, gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath = r.Method, r.URL.Path
		if r.Header.Get(dirsig.HeaderPub) == "" || r.Header.Get(dirsig.HeaderSig) == "" {
			t.Errorf("唤醒请求缺少签名头")
		}
		switch mode {
		case "bad":
			w.WriteHeader(http.StatusServiceUnavailable)
		case "malformed":
			_, _ = w.Write([]byte("not-json"))
		case "disabled":
			_, _ = w.Write([]byte(`{"enabled":false}`))
		default:
			_, _ = w.Write([]byte(`{"enabled":true}`))
		}
	}))
	defer srv.Close()

	c, err := New(Config{BaseURL: srv.URL, Signer: acc})
	if err != nil {
		t.Fatal(err)
	}

	enabled, err := c.Wake(context.Background(), acc.Pub())
	if err != nil || !enabled {
		t.Fatalf("唤醒应成功且启用: enabled=%v err=%v", enabled, err)
	}
	if gotMethod != http.MethodPost || gotPath != "/v1/push/wake/"+URI(acc.Pub()) {
		t.Fatalf("唤醒请求路径错误: %s %s", gotMethod, gotPath)
	}

	mode = "disabled"
	if enabled, err := c.Wake(context.Background(), acc.Pub()); err != nil || enabled {
		t.Fatalf("未配置推送应返回 false: enabled=%v err=%v", enabled, err)
	}

	mode = "bad"
	if _, err := c.Wake(context.Background(), acc.Pub()); !errors.Is(err, ErrBadResponse) {
		t.Fatalf("5xx 应返回 ErrBadResponse，实际 %v", err)
	}

	mode = "malformed"
	if _, err := c.Wake(context.Background(), acc.Pub()); !errors.Is(err, ErrBadResponse) {
		t.Fatalf("非法响应应返回 ErrBadResponse，实际 %v", err)
	}

	if _, err := c.Wake(context.Background(), []byte("short")); err == nil {
		t.Fatal("非法账号公钥应失败")
	}
}

// TestSubmitReport 覆盖 report.submit 的请求形态与服务端错误映射（P6-06）。
func TestSubmitReport(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	mode := "ok"
	var got struct {
		path string
		body map[string]any
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.path = r.URL.Path
		if r.Header.Get(dirsig.HeaderPub) == "" || r.Header.Get(dirsig.HeaderSig) == "" {
			t.Errorf("举报请求缺少签名头")
		}
		_ = json.NewDecoder(r.Body).Decode(&got.body)
		switch mode {
		case "rejected":
			w.WriteHeader(http.StatusBadRequest)
		case "limited":
			w.WriteHeader(http.StatusTooManyRequests)
		case "no-id":
			_, _ = w.Write([]byte(`{}`))
		default:
			_, _ = w.Write([]byte(`{"id":"abc","created_at":123}`))
		}
	}))
	defer srv.Close()

	c, err := New(Config{BaseURL: srv.URL, Signer: acc})
	if err != nil {
		t.Fatal(err)
	}

	res, err := c.SubmitReport(context.Background(), ReportRequest{
		Reason:         "spam",
		ConversationID: "dm:peer",
		Detail:         "广告",
		Diagnostics:    []byte("{\"event\":\"boot\"}\n"),
		ClientVersion:  "test",
	})
	if err != nil || res.ID != "abc" || res.CreatedAt != 123 {
		t.Fatalf("举报应成功: res=%+v err=%v", res, err)
	}
	if got.path != "/v1/report" {
		t.Fatalf("举报路径错误: %s", got.path)
	}
	if got.body["reason"] != "spam" || got.body["conversation_id"] != "dm:peer" {
		t.Fatalf("举报请求字段错误: %v", got.body)
	}
	if got.body["diagnostics_b64"] != "eyJldmVudCI6ImJvb3QifQo=" {
		t.Fatalf("诊断包 base64 错误: %v", got.body["diagnostics_b64"])
	}

	mode = "rejected"
	if _, err := c.SubmitReport(context.Background(), ReportRequest{Reason: "spam"}); !errors.Is(err, ErrReportRejected) {
		t.Fatalf("400 应返回 ErrReportRejected，实际 %v", err)
	}
	mode = "limited"
	if _, err := c.SubmitReport(context.Background(), ReportRequest{Reason: "spam"}); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("429 应返回 ErrRateLimited，实际 %v", err)
	}
	mode = "no-id"
	if _, err := c.SubmitReport(context.Background(), ReportRequest{Reason: "spam"}); !errors.Is(err, ErrBadResponse) {
		t.Fatalf("缺少 ID 应返回 ErrBadResponse，实际 %v", err)
	}
	if _, err := c.SubmitReport(context.Background(), ReportRequest{Reason: "spam", Diagnostics: make([]byte, maxReportDiagnostics+1)}); err == nil {
		t.Fatal("超限诊断包应失败")
	}
}

func TestNewValidation(t *testing.T) {
	if _, err := New(Config{}); err == nil {
		t.Fatal("空地址应失败")
	}
	if _, err := New(Config{BaseURL: "ftp://host"}); err == nil {
		t.Fatal("非 http(s) 应失败")
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := New(Config{BaseURL: "https://dir.example.com/"}); err == nil {
		t.Fatal("缺少签名器应失败")
	}
	c, err := New(Config{BaseURL: "https://dir.example.com/", Signer: acc})
	if err != nil {
		t.Fatalf("合法地址应成功: %v", err)
	}
	if c.base != "https://dir.example.com" {
		t.Fatalf("base 应为 %q，实际 %q", "https://dir.example.com", c.base)
	}
}

func TestGetProfile(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	profile := &nexmemv1.PublicProfile{OfflineEnabled: true, UpdatedAt: time.Now().Unix()}
	if err := acc.SignProfile(profile); err != nil {
		t.Fatal(err)
	}
	raw, _ := proto.Marshal(profile)

	var mode string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch mode {
		case "notfound":
			w.WriteHeader(http.StatusNotFound)
		case "mismatch":
			other, _ := identity.GenerateAccount()
			p := &nexmemv1.PublicProfile{UpdatedAt: time.Now().Unix()}
			_ = other.SignProfile(p)
			body, _ := proto.Marshal(p)
			w.Write(body)
		case "tampered":
			bad := proto.Clone(profile).(*nexmemv1.PublicProfile)
			bad.OfflineEnabled = false
			body, _ := proto.Marshal(bad)
			w.Write(body)
		default:
			w.Header().Set("Content-Type", "application/x-protobuf")
			w.Write(raw)
		}
	}))
	defer srv.Close()

	c, err := New(Config{BaseURL: srv.URL, Signer: acc})
	if err != nil {
		t.Fatal(err)
	}
	got, err := c.GetProfile(context.Background(), acc.Pub())
	if err != nil {
		t.Fatalf("拉取档案应成功: %v", err)
	}
	if !got.OfflineEnabled {
		t.Fatal("档案字段不一致")
	}

	mode = "notfound"
	if _, err := c.GetProfile(context.Background(), acc.Pub()); !errors.Is(err, ErrProfileNotFound) {
		t.Fatalf("404 应返回 ErrProfileNotFound，实际 %v", err)
	}
	mode = "mismatch"
	if _, err := c.GetProfile(context.Background(), acc.Pub()); !errors.Is(err, ErrBadResponse) {
		t.Fatalf("账号不匹配应返回 ErrBadResponse，实际 %v", err)
	}
	mode = "tampered"
	if _, err := c.GetProfile(context.Background(), acc.Pub()); !errors.Is(err, ErrBadResponse) {
		t.Fatalf("篡改档案应返回 ErrBadResponse，实际 %v", err)
	}
}

func TestTakeTicketsFiltersExpired(t *testing.T) {
	account := make([]byte, blob.AccountPubSize)
	now := time.Now()
	var payload struct {
		Tickets []blob.Ticket `json:"tickets"`
	}
	payload.Tickets = []blob.Ticket{
		{Key: "im_offline/x/inbox/a.msg", URL: "https://s3.example.com/a?X-Amz-Signature=s", ExpiresAt: now.Add(time.Hour).Unix()},
		{Key: "im_offline/x/inbox/b.msg", URL: "https://s3.example.com/b?X-Amz-Signature=s", ExpiresAt: now.Add(-time.Minute).Unix()},
	}
	var takeParam string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		takeParam = r.URL.Query().Get("take")
		_ = json.NewEncoder(w).Encode(payload)
	}))
	defer srv.Close()

	signer, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	c, err := New(Config{BaseURL: srv.URL, Signer: signer})
	if err != nil {
		t.Fatal(err)
	}
	tickets, err := c.TakeTickets(context.Background(), account, 2)
	if err != nil {
		t.Fatalf("领取票据应成功: %v", err)
	}
	if len(tickets) != 1 || tickets[0].Key != "im_offline/x/inbox/a.msg" {
		t.Fatalf("应只返回未过期票据，实际 %+v", tickets)
	}
	if takeParam != "2" {
		t.Fatalf("take 参数 %q，期望 2", takeParam)
	}

	payload.Tickets = payload.Tickets[1:]
	if _, err := c.TakeTickets(context.Background(), account, 1); !errors.Is(err, ErrTicketPoolEmpty) {
		t.Fatalf("全部过期应返回 ErrTicketPoolEmpty，实际 %v", err)
	}
}

func TestTakeTicketsRejectsBadURL(t *testing.T) {
	account := make([]byte, blob.AccountPubSize)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"tickets": []blob.Ticket{{
				Key:       "im_offline/x/inbox/a.msg",
				URL:       "https://s3.example.com/a",
				ExpiresAt: time.Now().Add(time.Hour).Unix(),
			}},
		})
	}))
	defer srv.Close()

	signer, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	c, err := New(Config{BaseURL: srv.URL, Signer: signer})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.TakeTickets(context.Background(), account, 1); !errors.Is(err, ErrBadResponse) {
		t.Fatalf("无签名票据应返回 ErrBadResponse，实际 %v", err)
	}
}

func TestTakeTicketsHTTPError(t *testing.T) {
	account := make([]byte, blob.AccountPubSize)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()

	signer, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	c, err := New(Config{BaseURL: srv.URL, Signer: signer})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.TakeTickets(context.Background(), account, 1); !errors.Is(err, ErrBadResponse) {
		t.Fatalf("5xx 应返回 ErrBadResponse，实际 %v", err)
	}
}

// TestClientSignsRequests 校验客户端为每个请求附加了可验证的签名头部。
func TestClientSignsRequests(t *testing.T) {
	signer, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	profile := &nexmemv1.PublicProfile{OfflineEnabled: true, UpdatedAt: time.Now().Unix()}
	if err := signer.SignProfile(profile); err != nil {
		t.Fatal(err)
	}
	raw, err := proto.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cred, err := dirsig.Parse(
			r.Header.Get(dirsig.HeaderPub),
			r.Header.Get(dirsig.HeaderSig),
			r.Header.Get(dirsig.HeaderTimestamp),
		)
		if err != nil {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if err := dirsig.Verify(cred, r.Method, r.URL.RequestURI(), time.Now(), 0, nil); err != nil {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/x-protobuf")
		_, _ = w.Write(raw)
	}))
	defer srv.Close()

	c, err := New(Config{BaseURL: srv.URL, Signer: signer})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetProfile(context.Background(), signer.Pub()); err != nil {
		t.Fatalf("带签名请求应通过校验: %v", err)
	}
}
