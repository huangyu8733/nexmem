// Package push 实现可选的唤醒推送发送端（P6-02）。
//
// 推送只携带"有离线消息"的指针，不包含正文、发送者或会话信息；接收方设备被唤醒后
// 自行经离线通道拉取密文并本地解密。当前实现 APNs（iOS）的 token 鉴权与静默推送，
// 采用 HTTP/2 直连，不依赖第三方 SDK。
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// ProductionHost 是 APNs 生产环境地址。
	ProductionHost = "https://api.push.apple.com"
	// SandboxHost 是 APNs 开发环境地址。
	SandboxHost = "https://api.sandbox.push.apple.com"

	// tokenTTL 是鉴权 JWT 的复用时长；APNs 要求一小时内有效，这里提前刷新。
	tokenTTL       = 50 * time.Minute
	defaultTimeout = 10 * time.Second
	maxAttempts    = 3
	maxRespBytes   = 4096
	// expiration 是推送的最长保留时长：设备离线时不立即丢弃。
	expiration = time.Hour
)

// 推送语义错误，调用方可用 errors.Is 判定。
var (
	// ErrBadToken 表示设备令牌无效，应停止向该令牌推送。
	ErrBadToken = errors.New("推送令牌无效")
	// ErrUnregistered 表示设备已注销，应删除该令牌。
	ErrUnregistered = errors.New("推送令牌已注销")
	// ErrAuth 表示 APNs 鉴权失败（密钥/TeamID/KeyID 不匹配）。
	ErrAuth = errors.New("推送鉴权失败")
)

// Config 描述 APNs 凭据与连接参数。
type Config struct {
	// KeyID 是 APNs 鉴权密钥 ID（.p8 文件名中的 10 位标识）。
	KeyID string
	// TeamID 是 Apple Developer 团队 ID。
	TeamID string
	// BundleID 是应用 Bundle ID，作为 apns-topic。
	BundleID string
	// PrivateKeyPEM 是 .p8 私钥内容（P-256 EC PKCS#8）。
	PrivateKeyPEM []byte
	// Sandbox 为真时使用 APNs 开发环境。
	Sandbox bool
	// BaseURL 覆盖推送主机，仅用于测试。
	BaseURL string
	// HTTPClient 可选；默认强制 HTTP/2 且 10s 超时。
	HTTPClient *http.Client
	// Now 可注入时钟，为空时使用 time.Now。
	Now func() time.Time
}

// Client 是并发安全的 APNs 静默推送发送端。
type Client struct {
	cfg  Config
	key  *ecdsa.PrivateKey
	base string
	hc   *http.Client
	now  func() time.Time

	mu    sync.Mutex
	jwt   string
	jwtAt time.Time
}

// New 校验配置并解析 APNs 私钥。
func New(cfg Config) (*Client, error) {
	cfg.KeyID = strings.TrimSpace(cfg.KeyID)
	cfg.TeamID = strings.TrimSpace(cfg.TeamID)
	cfg.BundleID = strings.TrimSpace(cfg.BundleID)
	if cfg.KeyID == "" || cfg.TeamID == "" || cfg.BundleID == "" {
		return nil, errors.New("推送配置缺少 KeyID/TeamID/BundleID")
	}
	if len(cfg.PrivateKeyPEM) == 0 {
		return nil, errors.New("推送配置缺少 APNs 私钥")
	}
	key, err := parsePrivateKey(cfg.PrivateKeyPEM)
	if err != nil {
		return nil, err
	}

	base := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if base == "" {
		if cfg.Sandbox {
			base = SandboxHost
		} else {
			base = ProductionHost
		}
	}
	hc := cfg.HTTPClient
	if hc == nil {
		tr := http.DefaultTransport.(*http.Transport).Clone()
		tr.ForceAttemptHTTP2 = true
		hc = &http.Client{Timeout: defaultTimeout, Transport: tr}
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &Client{cfg: cfg, key: key, base: base, hc: hc, now: now}, nil
}

// parsePrivateKey 解析 PKCS#8 编码的 P-256 私钥（APNs .p8 格式）。
func parsePrivateKey(raw []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("推送私钥不是 PEM 格式")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("解析推送私钥: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("推送私钥不是 EC 密钥")
	}
	if key.Curve != elliptic.P256() {
		return nil, errors.New("推送私钥必须为 P-256 曲线")
	}
	return key, nil
}

// SilentPayload 构造无内容唤醒载荷：只说明"该账号有离线消息"。
func SilentPayload(account string) []byte {
	raw, _ := json.Marshal(map[string]any{
		"aps":         map[string]any{"content-available": 1},
		"acct":        account,
		"has_offline": true,
	})
	return raw
}

// PushSilent 向单个设备令牌发送静默推送。
//
// 429 与 5xx 按固定次数退避重试；鉴权失败会刷新 JWT 后重试一次；
// 无效令牌与已注销分别返回 ErrBadToken / ErrUnregistered，供调用方清理。
func (c *Client) PushSilent(ctx context.Context, account, deviceToken string) error {
	token := strings.TrimSpace(deviceToken)
	if token == "" {
		return fmt.Errorf("%w: 设备令牌为空", ErrBadToken)
	}
	payload := SilentPayload(account)

	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		jwt, err := c.authToken()
		if err != nil {
			return err
		}
		status, reason, err := c.post(ctx, jwt, token, payload)
		if err != nil {
			lastErr = err
			if !c.wait(ctx, attempt) {
				return err
			}
			continue
		}

		switch {
		case status == http.StatusOK:
			return nil
		case status == http.StatusForbidden:
			// 密钥轮换或 JWT 过期：清缓存后重试。
			c.invalidateAuthToken()
			lastErr = fmt.Errorf("%w: %s", ErrAuth, reasonOr(reason, status))
			continue
		case status == http.StatusBadRequest && (reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic"):
			return fmt.Errorf("%w: %s", ErrBadToken, reason)
		case status == http.StatusGone:
			return fmt.Errorf("%w: %s", ErrUnregistered, reasonOr(reason, status))
		case status == http.StatusTooManyRequests || status >= 500:
			lastErr = fmt.Errorf("APNs 暂时不可用（%d %s）", status, reasonOr(reason, status))
			if !c.wait(ctx, attempt) {
				return lastErr
			}
			continue
		default:
			return fmt.Errorf("APNs 拒绝推送（%d %s）", status, reasonOr(reason, status))
		}
	}
	return lastErr
}

// post 发送一次 HTTP/2 推送请求并返回状态码与 APNs 错误原因。
func (c *Client) post(ctx context.Context, jwt, deviceToken string, payload []byte) (int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.base+"/3/device/"+deviceToken, bytes.NewReader(payload))
	if err != nil {
		return 0, "", fmt.Errorf("构造推送请求: %w", err)
	}
	req.Header.Set("Authorization", "bearer "+jwt)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("apns-topic", c.cfg.BundleID)
	req.Header.Set("apns-push-type", "background")
	req.Header.Set("apns-priority", "5")
	req.Header.Set("apns-expiration", strconv.FormatInt(c.now().Add(expiration).Unix(), 10))

	resp, err := c.hc.Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("请求 APNs: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxRespBytes))

	var body struct {
		Reason string `json:"reason"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &body) != nil {
		body.Reason = ""
	}
	return resp.StatusCode, body.Reason, nil
}

// authToken 返回缓存的鉴权 JWT，过期后重新签发。
func (c *Client) authToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.jwt != "" && now.Sub(c.jwtAt) < tokenTTL {
		return c.jwt, nil
	}
	token, err := c.mintToken(now)
	if err != nil {
		return "", err
	}
	c.jwt = token
	c.jwtAt = now
	return token, nil
}

// invalidateAuthToken 丢弃缓存，下一次发送会重新签发。
func (c *Client) invalidateAuthToken() {
	c.mu.Lock()
	c.jwt = ""
	c.mu.Unlock()
}

// mintToken 按 APNs provider token 规范签发 ES256 JWT。
func (c *Client) mintToken(now time.Time) (string, error) {
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": c.cfg.KeyID})
	if err != nil {
		return "", fmt.Errorf("编码推送 JWT 头: %w", err)
	}
	claims, err := json.Marshal(map[string]any{"iss": c.cfg.TeamID, "iat": now.Unix()})
	if err != nil {
		return "", fmt.Errorf("编码推送 JWT 声明: %w", err)
	}
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))

	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", fmt.Errorf("签名推送 JWT: %w", err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// wait 在重试前退避，返回 false 表示上下文已取消。
func (c *Client) wait(ctx context.Context, attempt int) bool {
	delay := time.Duration(100*(attempt+1)) * time.Millisecond
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func reasonOr(reason string, status int) string {
	if reason != "" {
		return reason
	}
	return "status " + strconv.Itoa(status)
}

// VerifyToken 校验 ES256 JWT 签名与声明，供服务端测试与冒烟工具复用。
func VerifyToken(token string, pub *ecdsa.PublicKey, teamID string) error {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return errors.New("JWT 段数非法")
	}
	headerRaw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return errors.New("JWT 头编码非法")
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headerRaw, &header); err != nil {
		return errors.New("JWT 头非 JSON")
	}
	if header.Alg != "ES256" || header.Kid == "" {
		return errors.New("JWT 头字段非法")
	}
	claimsRaw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return errors.New("JWT 声明编码非法")
	}
	var claims struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
	}
	if err := json.Unmarshal(claimsRaw, &claims); err != nil {
		return errors.New("JWT 声明非 JSON")
	}
	if claims.Iss != teamID || claims.Iat == 0 {
		return errors.New("JWT 声明字段非法")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return errors.New("JWT 签名编码非法")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return errors.New("JWT 签名校验失败")
	}
	return nil
}
