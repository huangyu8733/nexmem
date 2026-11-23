// Package directory 是索引服务的 HTTP 客户端（P3-06）。
//
// 客户端只信任自签名校验通过的公开档案：服务端可能被替换或篡改，
// 因此 GetProfile 会用账号 ed25519 公钥逐字段验签，并确认返回的账号与请求一致。
package directory

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/dirsig"
	"github.com/nexmem/core/internal/identity"
)

const (
	maxProfileBytes  = 1 << 20
	maxTicketsBytes  = 8 << 20
	maxWakeBytes     = 4 << 10
	// maxReportBytes 与服务端 /v1/report 的请求体上限保持一致。
	maxReportBytes         = 1 << 20
	maxReportDiagnostics   = 256 << 10
	maxReportResponseBytes = 4 << 10
	// push token 请求/响应上限（与服务端 decodePushTokenRequest 一致）。
	maxPushTokenBytes   = 4 << 10
	maxPushTokenRespLen = 4 << 10
	maxTakeTickets   = 100
	defaultTimeout   = 15 * time.Second
	defaultTakeCount = 1
)

// 客户端语义错误。
var (
	// ErrProfileNotFound 表示索引服务没有该账号的公开档案。
	ErrProfileNotFound = errors.New("公开档案不存在")
	// ErrTicketPoolEmpty 表示没有可用的离线上传票据。
	ErrTicketPoolEmpty = errors.New("离线票据池为空")
	// ErrBadResponse 表示索引服务返回了非法或不匹配的数据。
	ErrBadResponse = errors.New("索引服务响应非法")
	// ErrReportRejected 表示索引服务拒绝了举报内容（参数非法等）。
	ErrReportRejected = errors.New("举报被索引服务拒绝")
	// ErrRateLimited 表示索引服务限流。
	ErrRateLimited = errors.New("索引服务限流")
)

// Config 描述索引服务地址与连接参数。
type Config struct {
	// BaseURL 形如 https://dir.example.com，末尾斜杠可省略。
	BaseURL string
	// Signer 是请求签名用的账号密钥（P3-05），必填。
	Signer dirsig.Signer
	// HTTPClient 可选，默认 15s 超时。
	HTTPClient *http.Client
	// Timeout 仅在 HTTPClient 为空时生效。
	Timeout time.Duration
}

// Client 是并发安全的索引服务客户端。
type Client struct {
	base   string
	hc     *http.Client
	now    func() time.Time
	signer dirsig.Signer
}

// New 校验并创建客户端。
func New(cfg Config) (*Client, error) {
	base := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if base == "" {
		return nil, errors.New("索引服务地址为空")
	}
	if cfg.Signer == nil {
		return nil, errors.New("索引服务客户端缺少账号签名器")
	}
	u, err := url.Parse(base)
	if err != nil {
		return nil, fmt.Errorf("解析索引服务地址: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("索引服务地址必须为 http/https: %q", cfg.BaseURL)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("索引服务地址缺少主机: %q", cfg.BaseURL)
	}
	hc := cfg.HTTPClient
	if hc == nil {
		timeout := cfg.Timeout
		if timeout <= 0 {
			timeout = defaultTimeout
		}
		hc = &http.Client{Timeout: timeout}
	}
	return &Client{base: base, hc: hc, now: time.Now, signer: cfg.Signer}, nil
}

// sign 给请求追加签名头部；签名覆盖 method + path?query + 时间戳 + 请求体摘要。
func (c *Client) sign(req *http.Request, body []byte) {
	for k, v := range dirsig.Headers(c.signer, req.Method, req.URL.RequestURI(), c.now().Unix(), body) {
		req.Header.Set(k, v)
	}
}

// URI 返回账号在索引服务中的路径编码（无填充 base64url）。
func URI(accountPub []byte) string {
	return base64.RawURLEncoding.EncodeToString(accountPub)
}

// GetProfile 拉取并校验对端公开档案。
func (c *Client) GetProfile(ctx context.Context, accountPub []byte) (*nexmemv1.PublicProfile, error) {
	if len(accountPub) != blob.AccountPubSize {
		return nil, fmt.Errorf("账号公钥长度 %d，期望 %d", len(accountPub), blob.AccountPubSize)
	}
	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodGet, c.base+"/v1/profile/"+URI(accountPub), nil)
	if err != nil {
		return nil, fmt.Errorf("构造档案请求: %w", err)
	}
	c.sign(req, nil)
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("请求公开档案: %w", err)
	}
	raw, err := readBody(resp, maxProfileBytes)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrProfileNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return nil, statusErr("查询公开档案", resp.StatusCode)
	}

	profile := &nexmemv1.PublicProfile{}
	if err := proto.Unmarshal(raw, profile); err != nil {
		return nil, fmt.Errorf("%w: 档案解码失败: %v", ErrBadResponse, err)
	}
	if !bytes.Equal(profile.AccountPub, accountPub) {
		return nil, fmt.Errorf("%w: 档案账号与请求不一致", ErrBadResponse)
	}
	if err := identity.VerifyPublicProfile(profile, c.now()); err != nil {
		return nil, fmt.Errorf("%w: 档案验签失败: %v", ErrBadResponse, err)
	}
	return profile, nil
}

// PutProfile 上传本机公开档案；服务端会重新验签，篡改或盗用他人账号会被拒绝。
//
// 与 GetProfile 对称，这里不信任服务端，只负责把账号签名后的档案交给它保管。
func (c *Client) PutProfile(ctx context.Context, p *nexmemv1.PublicProfile) error {
	if p == nil {
		return errors.New("公开档案为空")
	}
	raw, err := proto.Marshal(p)
	if err != nil {
		return fmt.Errorf("序列化公开档案: %w", err)
	}
	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodPut, c.base+"/v1/profile", bytes.NewReader(raw))
	if err != nil {
		return fmt.Errorf("构造档案请求: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-protobuf")
	c.sign(req, raw)
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("上传公开档案: %w", err)
	}
	if _, err := readBody(resp, maxProfileBytes); err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return statusErr("上传公开档案", resp.StatusCode)
	}
	return nil
}

// DepositTickets 把本机生成的一批 presigned 票据交存到索引服务。
//
// 服务端只保存对象键与 URL，不接触 S3 凭证；路径账号必须与签名账号一致。
func (c *Client) DepositTickets(ctx context.Context, batch *blob.TicketBatch) error {
	if batch == nil {
		return errors.New("票据批次为空")
	}
	accountPub, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(batch.AccountPub))
	if err != nil || len(accountPub) != blob.AccountPubSize {
		return fmt.Errorf("票据批次账号公钥非法")
	}
	if len(batch.Tickets) == 0 {
		return errors.New("票据批次为空")
	}
	raw, err := json.Marshal(batch)
	if err != nil {
		return fmt.Errorf("序列化票据批次: %w", err)
	}
	endpoint := fmt.Sprintf("%s/v1/inbox/%s/tickets", c.base, URI(accountPub))
	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return fmt.Errorf("构造票据请求: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	c.sign(req, raw)
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("交存上传票据: %w", err)
	}
	if _, err := readBody(resp, maxTicketsBytes); err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return statusErr("交存上传票据", resp.StatusCode)
	}
	return nil
}

// TakeTickets 从索引服务原子领取票据，只返回未过期的条目。
// take <= 0 时取 1，超过 100 会被截断到索引服务上限。
func (c *Client) TakeTickets(ctx context.Context, accountPub []byte, take int) ([]blob.Ticket, error) {
	if len(accountPub) != blob.AccountPubSize {
		return nil, fmt.Errorf("账号公钥长度 %d，期望 %d", len(accountPub), blob.AccountPubSize)
	}
	if take <= 0 {
		take = defaultTakeCount
	}
	if take > maxTakeTickets {
		take = maxTakeTickets
	}

	endpoint := fmt.Sprintf("%s/v1/inbox/%s/tickets?take=%d", c.base, URI(accountPub), take)
	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("构造票据请求: %w", err)
	}
	c.sign(req, nil)
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("领取上传票据: %w", err)
	}
	raw, err := readBody(resp, maxTicketsBytes)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, statusErr("领取上传票据", resp.StatusCode)
	}

	var payload struct {
		Tickets []blob.Ticket `json:"tickets"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, fmt.Errorf("%w: 票据响应解码失败: %v", ErrBadResponse, err)
	}
	now := c.now()
	out := make([]blob.Ticket, 0, len(payload.Tickets))
	for i, t := range payload.Tickets {
		if t.Expired(now) {
			continue
		}
		if err := blob.ValidateTicketURL(t.URL); err != nil {
			return nil, fmt.Errorf("%w: 第 %d 张票据非法: %v", ErrBadResponse, i, err)
		}
		out = append(out, t)
	}
	if len(out) == 0 {
		return nil, ErrTicketPoolEmpty
	}
	return out, nil
}

// Wake 请求索引服务向目标账号的已登记设备发送唤醒推送（P6-02）。
//
// 返回推送是否启用；未启用时调用方可直接忽略。推送只携带"有离线消息"的指针，
// 服务端不会接触到消息内容。
func (c *Client) Wake(ctx context.Context, accountPub []byte) (bool, error) {
	if len(accountPub) != blob.AccountPubSize {
		return false, fmt.Errorf("账号公钥长度 %d，期望 %d", len(accountPub), blob.AccountPubSize)
	}
	endpoint := fmt.Sprintf("%s/v1/push/wake/%s", c.base, URI(accountPub))
	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodPost, endpoint, nil)
	if err != nil {
		return false, fmt.Errorf("构造唤醒请求: %w", err)
	}
	c.sign(req, nil)
	resp, err := c.hc.Do(req)
	if err != nil {
		return false, fmt.Errorf("请求唤醒推送: %w", err)
	}
	raw, err := readBody(resp, maxWakeBytes)
	if err != nil {
		return false, err
	}
	if resp.StatusCode != http.StatusOK {
		return false, statusErr("请求唤醒推送", resp.StatusCode)
	}
	var payload struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return false, fmt.Errorf("%w: 唤醒响应解码失败: %v", ErrBadResponse, err)
	}
	return payload.Enabled, nil
}

// ReportRequest 是一次举报提交的输入（P6-06）。
//
// Diagnostics 是客户端已脱敏的诊断包原始字节；索引服务只负责留档。
type ReportRequest struct {
	Reason         string
	ConversationID string
	Detail         string
	Diagnostics    []byte
	ClientVersion  string
}

// ReportResult 是举报受理结果。
type ReportResult struct {
	ID        string
	CreatedAt int64
}

// SubmitReport 把一条举报连同脱敏诊断包提交到索引服务。
//
// 服务端按签名账号记名留档；调用方未配置索引服务时应自行降级。
func (c *Client) SubmitReport(ctx context.Context, in ReportRequest) (ReportResult, error) {
	payload := struct {
		Reason         string `json:"reason"`
		ConversationID string `json:"conversation_id,omitempty"`
		Detail         string `json:"detail,omitempty"`
		DiagnosticsB64 string `json:"diagnostics_b64,omitempty"`
		ClientVersion  string `json:"client_version,omitempty"`
	}{
		Reason:         strings.TrimSpace(in.Reason),
		ConversationID: strings.TrimSpace(in.ConversationID),
		Detail:         strings.TrimSpace(in.Detail),
		ClientVersion:  strings.TrimSpace(in.ClientVersion),
	}
	if payload.Reason == "" {
		return ReportResult{}, errors.New("举报原因为空")
	}
	if len(in.Diagnostics) > maxReportDiagnostics {
		return ReportResult{}, fmt.Errorf("诊断包超过 %d 字节", maxReportDiagnostics)
	}
	if len(in.Diagnostics) > 0 {
		payload.DiagnosticsB64 = base64.StdEncoding.EncodeToString(in.Diagnostics)
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return ReportResult{}, fmt.Errorf("序列化举报: %w", err)
	}
	if len(body) > maxReportBytes {
		return ReportResult{}, fmt.Errorf("举报请求超过 %d 字节", maxReportBytes)
	}

	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodPost, c.base+"/v1/report", bytes.NewReader(body))
	if err != nil {
		return ReportResult{}, fmt.Errorf("构造举报请求: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	c.sign(req, body)
	resp, err := c.hc.Do(req)
	if err != nil {
		return ReportResult{}, fmt.Errorf("提交举报: %w", err)
	}
	raw, err := readBody(resp, maxReportResponseBytes)
	if err != nil {
		return ReportResult{}, err
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return ReportResult{}, fmt.Errorf("提交举报 HTTP %d: %w", resp.StatusCode, ErrRateLimited)
	}
	if resp.StatusCode != http.StatusOK {
		return ReportResult{}, fmt.Errorf("提交举报 HTTP %d: %w", resp.StatusCode, ErrReportRejected)
	}
	var out struct {
		ID        string `json:"id"`
		CreatedAt int64  `json:"created_at"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return ReportResult{}, fmt.Errorf("%w: 举报响应解码失败: %v", ErrBadResponse, err)
	}
	if out.ID == "" {
		return ReportResult{}, fmt.Errorf("%w: 举报响应缺少 ID", ErrBadResponse)
	}
	return ReportResult{ID: out.ID, CreatedAt: out.CreatedAt}, nil
}

// RegisterPushToken 向索引服务登记本账号的设备推送令牌（C-07）。
// token 由客户端从 APNs/FCM 获取；env 为 production/sandbox，留空用服务端默认。
// 服务端按签名账号记名、按 (account, token) 幂等。
func (c *Client) RegisterPushToken(ctx context.Context, token, env string) (int, error) {
	body, err := json.Marshal(struct {
		Token string `json:"token"`
		Env   string `json:"env,omitempty"`
	}{Token: token, Env: env})
	if err != nil {
		return 0, fmt.Errorf("序列化推送令牌: %w", err)
	}
	if len(body) > maxPushTokenBytes {
		return 0, fmt.Errorf("推送令牌请求超过 %d 字节", maxPushTokenBytes)
	}
	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodPost,
		c.base+"/v1/push/token", bytes.NewReader(body))
	if err != nil {
		return 0, fmt.Errorf("构造推送令牌登记请求: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	c.sign(req, body)
	resp, err := c.hc.Do(req)
	if err != nil {
		return 0, fmt.Errorf("登记推送令牌: %w", err)
	}
	raw, err := readBody(resp, maxPushTokenRespLen)
	if err != nil {
		return 0, err
	}
	if resp.StatusCode != http.StatusOK {
		return 0, statusErr("登记推送令牌", resp.StatusCode)
	}
	var out struct {
		Tokens int `json:"tokens"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return 0, fmt.Errorf("%w: 推送令牌响应解码失败: %v", ErrBadResponse, err)
	}
	return out.Tokens, nil
}

// DeletePushToken 注销本账号的一个设备推送令牌（C-07）。
func (c *Client) DeletePushToken(ctx context.Context, token, env string) (bool, error) {
	body, err := json.Marshal(struct {
		Token string `json:"token"`
		Env   string `json:"env,omitempty"`
	}{Token: token, Env: env})
	if err != nil {
		return false, fmt.Errorf("序列化推送令牌: %w", err)
	}
	if len(body) > maxPushTokenBytes {
		return false, fmt.Errorf("推送令牌请求超过 %d 字节", maxPushTokenBytes)
	}
	req, err := http.NewRequestWithContext(ctxOrBackground(ctx), http.MethodDelete,
		c.base+"/v1/push/token", bytes.NewReader(body))
	if err != nil {
		return false, fmt.Errorf("构造推送令牌注销请求: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	c.sign(req, body)
	resp, err := c.hc.Do(req)
	if err != nil {
		return false, fmt.Errorf("注销推送令牌: %w", err)
	}
	raw, err := readBody(resp, maxPushTokenRespLen)
	if err != nil {
		return false, err
	}
	if resp.StatusCode != http.StatusOK {
		return false, statusErr("注销推送令牌", resp.StatusCode)
	}
	var out struct {
		Removed bool `json:"removed"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return false, fmt.Errorf("%w: 推送令牌响应解码失败: %v", ErrBadResponse, err)
	}
	return out.Removed, nil
}

func ctxOrBackground(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}

func readBody(resp *http.Response, limit int64) ([]byte, error) {
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, fmt.Errorf("读取索引服务响应: %w", err)
	}
	if int64(len(raw)) > limit {
		return nil, fmt.Errorf("%w: 响应超过 %d 字节", ErrBadResponse, limit)
	}
	return raw, nil
}

func statusErr(op string, status int) error {
	return fmt.Errorf("%s HTTP %d: %w", op, status, ErrBadResponse)
}
