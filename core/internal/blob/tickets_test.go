package blob

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// fakePresigner 记录请求并返回带签名的假 URL。
type fakePresigner struct {
	keys []string
	err  error
	url  func(key string) string
}

func (f *fakePresigner) PresignPut(key string, ttl time.Duration) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	f.keys = append(f.keys, key)
	if f.url != nil {
		return f.url(key), nil
	}
	return "https://s3.example.test/bucket/" + key + "?X-Amz-Signature=deadbeef", nil
}

// TestIssueTicketBatch512 校验单批生成 512 张唯一票据。
func TestIssueTicketBatch512(t *testing.T) {
	presigner := &fakePresigner{}
	issuer, err := NewTicketIssuer(presigner, time.Hour)
	if err != nil {
		t.Fatalf("创建票据生成器: %v", err)
	}
	now := time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)
	issuer.now = func() time.Time { return now }

	accountPub := make([]byte, AccountPubSize)
	if _, err := rand.Read(accountPub); err != nil {
		t.Fatalf("生成账号公钥: %v", err)
	}

	batch, err := issuer.IssueBatch(accountPub, "device-1", TicketBatchSize)
	if err != nil {
		t.Fatalf("IssueBatch: %v", err)
	}
	if len(batch.Tickets) != TicketBatchSize {
		t.Fatalf("票据数量 %d，期望 %d", len(batch.Tickets), TicketBatchSize)
	}
	if batch.DeviceID != "device-1" || batch.IssuedAt != now.Unix() || batch.ExpiresAt != now.Add(time.Hour).Unix() {
		t.Fatalf("批次元数据不符: %+v", batch)
	}
	if batch.AccountPub == "" || strings.ContainsAny(batch.AccountPub, "=+/") {
		t.Fatalf("账号公钥编码不是无填充 base64url: %q", batch.AccountPub)
	}

	pattern := regexp.MustCompile(`^im_offline/[A-Za-z0-9_-]+/inbox/[0-9a-f]{32}\.msg$`)
	seen := make(map[string]struct{}, len(batch.Tickets))
	for _, ticket := range batch.Tickets {
		if !pattern.MatchString(ticket.Key) {
			t.Fatalf("票据对象键格式不符: %s", ticket.Key)
		}
		if !strings.Contains(ticket.Key, batch.AccountPub) {
			t.Fatalf("票据对象键未包含账号前缀: %s", ticket.Key)
		}
		if ticket.ExpiresAt != batch.ExpiresAt {
			t.Fatalf("票据过期时间 %d，期望 %d", ticket.ExpiresAt, batch.ExpiresAt)
		}
		if !strings.Contains(ticket.URL, ticket.Key) || !strings.Contains(ticket.URL, "X-Amz-Signature=") {
			t.Fatalf("票据 URL 不匹配: %s", ticket.URL)
		}
		if _, dup := seen[ticket.Key]; dup {
			t.Fatalf("票据对象键重复: %s", ticket.Key)
		}
		seen[ticket.Key] = struct{}{}
	}
	if len(presigner.keys) != TicketBatchSize {
		t.Fatalf("presigner 调用 %d 次，期望 %d", len(presigner.keys), TicketBatchSize)
	}
}

// TestTicketIssuerDefaults 校验默认有效期与简化接口。
func TestTicketIssuerDefaults(t *testing.T) {
	presigner := &fakePresigner{}
	issuer, err := NewTicketIssuer(presigner, 0)
	if err != nil {
		t.Fatalf("创建票据生成器: %v", err)
	}
	if issuer.TTL() != DefaultTicketTTL {
		t.Fatalf("默认有效期 %s，期望 %s", issuer.TTL(), DefaultTicketTTL)
	}
	tickets, err := issuer.Issue(make([]byte, AccountPubSize), 3)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if len(tickets) != 3 {
		t.Fatalf("票据数量 %d，期望 3", len(tickets))
	}
}

// TestTicketIssuerRejectsBadInput 校验非法入参与非法产物。
func TestTicketIssuerRejectsBadInput(t *testing.T) {
	if _, err := NewTicketIssuer(nil, time.Hour); !errors.Is(err, ErrInvalidTicket) {
		t.Fatalf("空 presigner 应被拒绝，实际 %v", err)
	}
	for _, ttl := range []time.Duration{30 * time.Second, 25 * time.Hour} {
		if _, err := NewTicketIssuer(&fakePresigner{}, ttl); !errors.Is(err, ErrInvalidTicket) {
			t.Fatalf("有效期 %s 应被拒绝，实际 %v", ttl, err)
		}
	}

	issuer, err := NewTicketIssuer(&fakePresigner{}, time.Hour)
	if err != nil {
		t.Fatalf("创建票据生成器: %v", err)
	}
	cases := []struct {
		name    string
		account []byte
		device  string
		count   int
	}{
		{"公钥为空", nil, "device-1", 1},
		{"公钥长度错误", make([]byte, 16), "device-1", 1},
		{"数量为零", make([]byte, AccountPubSize), "device-1", 0},
		{"数量超限", make([]byte, AccountPubSize), "device-1", maxTicketBatch + 1},
		{"设备为空", make([]byte, AccountPubSize), "  ", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := issuer.IssueBatch(tc.account, tc.device, tc.count); !errors.Is(err, ErrInvalidTicket) {
				t.Fatalf("期望 ErrInvalidTicket，实际 %v", err)
			}
		})
	}

	failing := &fakePresigner{err: errors.New("presign 失败")}
	bad, err := NewTicketIssuer(failing, time.Hour)
	if err != nil {
		t.Fatalf("创建票据生成器: %v", err)
	}
	if _, err := bad.Issue(make([]byte, AccountPubSize), 1); err == nil {
		t.Fatal("presign 失败应向上返回")
	}

	unsigned := &fakePresigner{url: func(key string) string { return "https://s3.example.test/" + key }}
	noSig, err := NewTicketIssuer(unsigned, time.Hour)
	if err != nil {
		t.Fatalf("创建票据生成器: %v", err)
	}
	if _, err := noSig.Issue(make([]byte, AccountPubSize), 1); !errors.Is(err, ErrInvalidTicket) {
		t.Fatalf("缺少签名的 URL 应被拒绝，实际 %v", err)
	}
}

// TestTicketExpired 校验过期判断。
func TestTicketExpired(t *testing.T) {
	ticket := Ticket{ExpiresAt: 100}
	if ticket.Expired(time.Unix(99, 0)) {
		t.Fatal("未到期不应判为过期")
	}
	if !ticket.Expired(time.Unix(100, 0)) {
		t.Fatal("到期后应判为过期")
	}
}

// TestLiveTicketExpiry 在真实 S3 后端验证 presigned URL 到期后不可用。
// 未设置 NEXMEM_S3_ENDPOINT 时跳过。
func TestLiveTicketExpiry(t *testing.T) {
	endpoint := os.Getenv("NEXMEM_S3_ENDPOINT")
	if endpoint == "" {
		t.Skip("未设置 NEXMEM_S3_ENDPOINT，跳过票据过期实测")
	}
	client, err := New(Config{
		Endpoint:  endpoint,
		Region:    envOr("NEXMEM_S3_REGION", "us-east-1"),
		Bucket:    envOr("NEXMEM_S3_BUCKET", "nexmem"),
		AccessKey: envOr("NEXMEM_S3_ACCESS_KEY", "minioadmin"),
		SecretKey: envOr("NEXMEM_S3_SECRET_KEY", "minioadmin"),
		PathStyle: envOr("NEXMEM_S3_PATH_STYLE", "true") == "true",
	})
	if err != nil {
		t.Fatalf("创建客户端: %v", err)
	}
	issuer, err := NewTicketIssuer(client, time.Hour)
	if err != nil {
		t.Fatalf("创建票据生成器: %v", err)
	}
	// 票据池按 1h 签发，先确认生成器可对真实后端出票。
	batch, err := issuer.Issue(make([]byte, AccountPubSize), 1)
	if err != nil {
		t.Fatalf("签发真实票据: %v", err)
	}
	if len(batch) != 1 || !strings.Contains(batch[0].URL, "X-Amz-Signature=") {
		t.Fatalf("真实票据内容不符: %+v", batch)
	}

	// 直接签发 2s 有效期的 URL，验证到期后服务端拒绝。
	key := fmt.Sprintf("im_offline/live-%d/inbox/%d.msg", time.Now().UnixNano(), time.Now().UnixNano())
	raw, err := client.PresignPut(key, 2*time.Second)
	if err != nil {
		t.Fatalf("PresignPut: %v", err)
	}

	status, err := putPresigned(raw, "before-expiry")
	if err != nil {
		t.Fatalf("上传: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("有效期内上传状态 %d，期望 200", status)
	}

	time.Sleep(3 * time.Second)
	status, err = putPresigned(raw, "after-expiry")
	if err != nil {
		t.Fatalf("过期后上传: %v", err)
	}
	if status != http.StatusForbidden {
		t.Fatalf("过期后上传状态 %d，期望 403", status)
	}
}

func putPresigned(raw, body string) (int, error) {
	req, err := http.NewRequest(http.MethodPut, raw, strings.NewReader(body))
	if err != nil {
		return 0, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, nil
}
