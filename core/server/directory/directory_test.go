package directory

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/dirsig"
	"github.com/nexmem/core/internal/identity"
	"google.golang.org/protobuf/proto"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	return newTestServerWithConfig(t, Config{
		PerIPPerSecond:          1 << 20,
		PerAccountPerSecond:     1 << 20,
		TakePerAccountPerSecond: 1 << 20,
	})
}

func newTestServerWithConfig(t *testing.T, cfg Config) *Server {
	t.Helper()
	s, err := NewWithConfig(filepath.Join(t.TempDir(), "directory.db"), cfg)
	if err != nil {
		t.Fatalf("创建索引服务: %v", err)
	}
	t.Cleanup(func() {
		if err := s.Close(); err != nil {
			t.Errorf("关闭索引服务: %v", err)
		}
	})
	return s
}

type profileFixture struct {
	account *identity.Account
	profile *nexmemv1.PublicProfile
	raw     []byte
	id      string
}

func newProfileFixture(t *testing.T, updatedAt int64) profileFixture {
	t.Helper()
	account, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成账号: %v", err)
	}
	devicePub := make([]byte, ed25519.PublicKeySize)
	if _, err := rand.Read(devicePub); err != nil {
		t.Fatalf("生成设备公钥: %v", err)
	}
	cert, err := account.IssueDeviceCert(devicePub, "test-device", time.Hour)
	if err != nil {
		t.Fatalf("签发设备证书: %v", err)
	}
	p := &nexmemv1.PublicProfile{
		Devices:        []*nexmemv1.DeviceCert{cert},
		OfflineEnabled: true,
		UpdatedAt:      updatedAt,
	}
	if err := account.SignProfile(p); err != nil {
		t.Fatalf("签名公开档案: %v", err)
	}
	raw, err := proto.Marshal(p)
	if err != nil {
		t.Fatalf("编码公开档案: %v", err)
	}
	return profileFixture{
		account: account,
		profile: p,
		raw:     raw,
		id:      base64.RawURLEncoding.EncodeToString(p.AccountPub),
	}
}

type staticPresigner struct{}

func (staticPresigner) PresignPut(key string, _ time.Duration) (string, error) {
	return "https://s3.example.test/bucket/" + key + "?X-Amz-Signature=deadbeef", nil
}

func issueBatch(t *testing.T, accountPub []byte, device string, count int, ttl time.Duration) *blob.TicketBatch {
	t.Helper()
	issuer, err := blob.NewTicketIssuer(staticPresigner{}, ttl)
	if err != nil {
		t.Fatalf("创建票据生成器: %v", err)
	}
	batch, err := issuer.IssueBatch(accountPub, device, count)
	if err != nil {
		t.Fatalf("生成票据批次: %v", err)
	}
	return batch
}

// signRequest 按索引服务签名规范给请求追加头部（P3-05）。
func signRequest(t *testing.T, req *http.Request, signer *identity.Account, body []byte) {
	t.Helper()
	for k, v := range dirsig.Headers(signer, req.Method, req.URL.RequestURI(), time.Now().Unix(), body) {
		req.Header.Set(k, v)
	}
}

// doRequest 发送签名请求；signer 为 nil 时故意发送未签名请求，用于鉴权用例。
func doRequest(t *testing.T, ts *httptest.Server, signer *identity.Account, method, path string, body []byte, contentType string) (int, []byte) {
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
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("执行请求 %s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取响应: %v", err)
	}
	return resp.StatusCode, out
}

func TestProfilePutGet(t *testing.T) {
	s := newTestServer(t)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	fx := newProfileFixture(t, time.Now().Unix())

	status, body := doRequest(t, ts, fx.account, http.MethodPut, "/v1/profile", fx.raw, "application/x-protobuf")
	if status != http.StatusOK {
		t.Fatalf("上传公开档案状态 %d: %s", status, body)
	}
	var put profileResponse
	if err := json.Unmarshal(body, &put); err != nil {
		t.Fatalf("解析上传响应: %v", err)
	}
	if put.Account != fx.id || put.Devices != 1 || put.UpdatedAt != fx.profile.UpdatedAt {
		t.Fatalf("上传响应不符: %+v", put)
	}

	status, got := doRequest(t, ts, fx.account, http.MethodGet, "/v1/profile/"+fx.id, nil, "")
	if status != http.StatusOK {
		t.Fatalf("查询公开档案状态 %d: %s", status, got)
	}
	if !bytes.Equal(got, fx.raw) {
		t.Fatalf("查询结果与原档案不一致")
	}
	var stored nexmemv1.PublicProfile
	if err := proto.Unmarshal(got, &stored); err != nil {
		t.Fatalf("解码查询结果: %v", err)
	}
	if err := identity.VerifyPublicProfile(&stored, time.Now()); err != nil {
		t.Fatalf("服务端返回的档案验签失败: %v", err)
	}

	unknown := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x7f}, blob.AccountPubSize))
	if status, _ := doRequest(t, ts, fx.account, http.MethodGet, "/v1/profile/"+unknown, nil, ""); status != http.StatusNotFound {
		t.Fatalf("未知账号状态 %d，期望 404", status)
	}

	tampered := proto.Clone(fx.profile).(*nexmemv1.PublicProfile)
	tampered.Devices[0].DeviceName = "tampered"
	raw, err := proto.Marshal(tampered)
	if err != nil {
		t.Fatalf("编码篡改档案: %v", err)
	}
	if status, _ := doRequest(t, ts, fx.account, http.MethodPut, "/v1/profile", raw, "application/x-protobuf"); status != http.StatusBadRequest {
		t.Fatalf("篡改档案状态 %d，期望 400", status)
	}

	older := &nexmemv1.PublicProfile{
		Devices:        fx.profile.Devices,
		OfflineEnabled: true,
		UpdatedAt:      fx.profile.UpdatedAt - 60,
	}
	if err := fx.account.SignProfile(older); err != nil {
		t.Fatalf("签名旧版本档案: %v", err)
	}
	raw, err = proto.Marshal(older)
	if err != nil {
		t.Fatalf("编码旧版本档案: %v", err)
	}
	if status, _ := doRequest(t, ts, fx.account, http.MethodPut, "/v1/profile", raw, "application/x-protobuf"); status != http.StatusConflict {
		t.Fatalf("旧版本档案状态 %d，期望 409", status)
	}
}

func postBatch(t *testing.T, ts *httptest.Server, signer *identity.Account, accountID string, batch *blob.TicketBatch) (int, []byte) {
	t.Helper()
	raw, err := json.Marshal(batch)
	if err != nil {
		t.Fatalf("编码票据批次: %v", err)
	}
	return doRequest(t, ts, signer, http.MethodPost, "/v1/inbox/"+accountID+"/tickets", raw, "application/json")
}

func takeBatch(t *testing.T, ts *httptest.Server, signer *identity.Account, accountID string, take int) takeTicketsResponse {
	t.Helper()
	status, body := doRequest(t, ts, signer, http.MethodGet,
		fmt.Sprintf("/v1/inbox/%s/tickets?take=%d", accountID, take), nil, "")
	if status != http.StatusOK {
		t.Fatalf("领取票据状态 %d: %s", status, body)
	}
	var resp takeTicketsResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("解析领取响应: %v", err)
	}
	return resp
}

func takeRaw(ts *httptest.Server, signer *identity.Account, accountID string, take int) (takeTicketsResponse, error) {
	var resp takeTicketsResponse
	url := fmt.Sprintf("%s/v1/inbox/%s/tickets?take=%d", ts.URL, accountID, take)
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, url, nil)
	if err != nil {
		return resp, err
	}
	for k, v := range dirsig.Headers(signer, req.Method, req.URL.RequestURI(), time.Now().Unix(), nil) {
		req.Header.Set(k, v)
	}
	httpResp, err := ts.Client().Do(req)
	if err != nil {
		return resp, err
	}
	defer httpResp.Body.Close()
	body, err := io.ReadAll(httpResp.Body)
	if err != nil {
		return resp, err
	}
	if httpResp.StatusCode != http.StatusOK {
		return resp, fmt.Errorf("状态 %d: %s", httpResp.StatusCode, body)
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return resp, err
	}
	return resp, nil
}

// TestTicketClaimAtomic 验证并发领取时同一张票不会落到两个调用方。
func TestTicketClaimAtomic(t *testing.T) {
	s := newTestServer(t)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	fx := newProfileFixture(t, time.Now().Unix())
	const total = 200
	batch := issueBatch(t, fx.profile.AccountPub, "device-1", total, time.Hour)
	if status, body := postBatch(t, ts, fx.account, fx.id, batch); status != http.StatusOK {
		t.Fatalf("交存票据状态 %d: %s", status, body)
	}

	const workers = 8
	var wg sync.WaitGroup
	results := make(chan []string, workers)
	errs := make(chan error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var keys []string
			for {
				resp, err := takeRaw(ts, fx.account, fx.id, 3)
				if err != nil {
					errs <- err
					return
				}
				if len(resp.Tickets) == 0 {
					results <- keys
					return
				}
				for _, ticket := range resp.Tickets {
					keys = append(keys, ticket.Key)
				}
			}
		}()
	}
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		t.Fatalf("并发领取失败: %v", err)
	}

	seen := make(map[string]struct{}, total)
	for keys := range results {
		for _, key := range keys {
			if _, dup := seen[key]; dup {
				t.Fatalf("票据 %s 被领取两次", key)
			}
			seen[key] = struct{}{}
		}
	}
	if len(seen) != total {
		t.Fatalf("共领取 %d 张，期望 %d", len(seen), total)
	}

	final := takeBatch(t, ts, fx.account, fx.id, 1)
	if len(final.Tickets) != 0 || final.Remaining != 0 {
		t.Fatalf("票据应已清空，实际 remaining=%d tickets=%d", final.Remaining, len(final.Tickets))
	}
}

func TestTicketBatchValidation(t *testing.T) {
	s := newTestServer(t)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	fx := newProfileFixture(t, time.Now().Unix())
	other := newProfileFixture(t, time.Now().Unix())

	t.Run("签名账号与路径不一致", func(t *testing.T) {
		batch := issueBatch(t, other.profile.AccountPub, "device-1", 1, time.Hour)
		if status, _ := postBatch(t, ts, other.account, fx.id, batch); status != http.StatusForbidden {
			t.Fatalf("状态 %d，期望 403", status)
		}
	})

	t.Run("对象键越界", func(t *testing.T) {
		batch := issueBatch(t, fx.profile.AccountPub, "device-1", 1, time.Hour)
		batch.Tickets[0].Key = blob.OfflineObjectPrefix + "/other/inbox/x.msg"
		if status, _ := postBatch(t, ts, fx.account, fx.id, batch); status != http.StatusBadRequest {
			t.Fatalf("状态 %d，期望 400", status)
		}
	})

	t.Run("票据已过期", func(t *testing.T) {
		batch := issueBatch(t, fx.profile.AccountPub, "device-1", 1, time.Hour)
		batch.Tickets[0].ExpiresAt = time.Now().Add(-time.Minute).Unix()
		if status, _ := postBatch(t, ts, fx.account, fx.id, batch); status != http.StatusBadRequest {
			t.Fatalf("状态 %d，期望 400", status)
		}
	})

	t.Run("批次已过期", func(t *testing.T) {
		batch := issueBatch(t, fx.profile.AccountPub, "device-1", 1, time.Hour)
		batch.ExpiresAt = time.Now().Add(-time.Minute).Unix()
		if status, _ := postBatch(t, ts, fx.account, fx.id, batch); status != http.StatusBadRequest {
			t.Fatalf("状态 %d，期望 400", status)
		}
	})

	t.Run("缺少签名", func(t *testing.T) {
		batch := issueBatch(t, fx.profile.AccountPub, "device-1", 1, time.Hour)
		batch.Tickets[0].URL = "https://s3.example.test/bucket/no-signature"
		if status, _ := postBatch(t, ts, fx.account, fx.id, batch); status != http.StatusBadRequest {
			t.Fatalf("状态 %d，期望 400", status)
		}
	})

	t.Run("take 非法", func(t *testing.T) {
		for _, take := range []string{"0", "101", "abc"} {
			status, _ := doRequest(t, ts, fx.account, http.MethodGet, "/v1/inbox/"+fx.id+"/tickets?take="+take, nil, "")
			if status != http.StatusBadRequest {
				t.Fatalf("take=%s 状态 %d，期望 400", take, status)
			}
		}
	})

	t.Run("账号路径非法", func(t *testing.T) {
		status, _ := doRequest(t, ts, fx.account, http.MethodGet, "/v1/inbox/not-base64!/tickets", nil, "")
		if status != http.StatusBadRequest {
			t.Fatalf("状态 %d，期望 400", status)
		}
	})
}

func TestTicketDuplicateIdempotent(t *testing.T) {
	s := newTestServer(t)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	fx := newProfileFixture(t, time.Now().Unix())
	batch := issueBatch(t, fx.profile.AccountPub, "device-1", 4, time.Hour)

	if status, body := postBatch(t, ts, fx.account, fx.id, batch); status != http.StatusOK {
		t.Fatalf("首次交存状态 %d: %s", status, body)
	}
	status, body := postBatch(t, ts, fx.account, fx.id, batch)
	if status != http.StatusOK {
		t.Fatalf("重复交存状态 %d: %s", status, body)
	}
	var resp ticketBatchResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("解析交存响应: %v", err)
	}
	if resp.Accepted != 0 || resp.Duplicates != 4 {
		t.Fatalf("重复交存应全部忽略，实际 %+v", resp)
	}

	claimed := takeBatch(t, ts, fx.account, fx.id, 10)
	if len(claimed.Tickets) != 4 || claimed.Remaining != 0 {
		t.Fatalf("应领取 4 张且池空，实际 tickets=%d remaining=%d", len(claimed.Tickets), claimed.Remaining)
	}
}

func TestTakeTicketsSkipsExpired(t *testing.T) {
	s := newTestServer(t)
	fx := newProfileFixture(t, time.Now().Unix())
	ctx := context.Background()
	now := time.Now().Unix()
	prefix := blob.OfflineObjectPrefix + "/" + fx.id + "/inbox/"

	added, err := s.addTickets(ctx, fx.id, "device-1", []blob.Ticket{
		{Key: prefix + "expired.msg", URL: "https://s3.example.test/x?X-Amz-Signature=a", ExpiresAt: now - 60},
		{Key: prefix + "valid.msg", URL: "https://s3.example.test/y?X-Amz-Signature=b", ExpiresAt: now + 3600},
	})
	if err != nil {
		t.Fatalf("写入票据: %v", err)
	}
	if added != 2 {
		t.Fatalf("写入 %d 张，期望 2", added)
	}

	tickets, err := s.takeTickets(ctx, fx.id, 10, now)
	if err != nil {
		t.Fatalf("领取票据: %v", err)
	}
	if len(tickets) != 1 || !strings.HasSuffix(tickets[0].Key, "valid.msg") {
		t.Fatalf("应只领取未过期票据，实际 %+v", tickets)
	}
	remaining, err := s.countTickets(ctx, fx.id, now)
	if err != nil {
		t.Fatalf("统计票据: %v", err)
	}
	if remaining != 0 {
		t.Fatalf("过期票据应被清理，剩余 %d", remaining)
	}
}
