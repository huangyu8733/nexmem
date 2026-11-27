package push

// Web Push (VAPID) 唤醒推送发送端。
//
// 只发送空载荷：浏览器 Service Worker 的 push 事件被触发后，客户端自行走离线
// 通道拉取。VAPID 密钥由部署者提供，未配置时不构造本发送端。

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const webPushTTL = "0"

// WebPushConfig 是 VAPID 凭证。
type WebPushConfig struct {
	// Subject 是 mailto: 或 https: 形式的站点联系人。
	Subject string
	// PrivateKeyPEM 是 PKCS#8 P-256 私钥。
	PrivateKeyPEM string
	// HTTPClient 可选。
	HTTPClient *http.Client
	Now        func() time.Time
}

// WebPushClient 发送空载荷 Web Push。
type WebPushClient struct {
	cfg WebPushConfig
	key *ecdsa.PrivateKey
	hc  *http.Client
	now func() time.Time
}

// NewWebPush 校验 VAPID 凭证并构造发送端。
func NewWebPush(cfg WebPushConfig) (*WebPushClient, error) {
	cfg.Subject = strings.TrimSpace(cfg.Subject)
	if cfg.Subject == "" {
		return nil, errors.New("Web Push 配置缺少 Subject")
	}
	key, err := parsePrivateKey([]byte(cfg.PrivateKeyPEM))
	if err != nil {
		return nil, fmt.Errorf("解析 VAPID 私钥: %w", err)
	}
	hc := cfg.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: defaultTimeout}
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &WebPushClient{cfg: cfg, key: key, hc: hc, now: now}, nil
}

// PushSilent 的 deviceToken 参数是 base64url 编码的 PushSubscription JSON。
func (c *WebPushClient) PushSilent(ctx context.Context, account, deviceToken string) error {
	sub, err := decodeSubscription(deviceToken)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrBadToken, err)
	}
	endpoint, err := url.Parse(sub.Endpoint)
	if err != nil || endpoint.Scheme != "https" || endpoint.Host == "" {
		return fmt.Errorf("%w: Web Push endpoint 非法", ErrBadToken)
	}
	audience := endpoint.Scheme + "://" + endpoint.Host
	jwt, err := c.vapidJWT(audience)
	if err != nil {
		return err
	}
	pub := elliptic.Marshal(elliptic.P256(), c.key.X, c.key.Y)
	auth := "vapid t=" + jwt + ",k=" + base64.RawURLEncoding.EncodeToString(pub)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.Endpoint, bytes.NewReader(nil))
	if err != nil {
		return fmt.Errorf("构造 Web Push 请求: %w", err)
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("TTL", webPushTTL)
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("请求 Web Push: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxRespBytes))
	switch resp.StatusCode {
	case http.StatusCreated, http.StatusOK:
		return nil
	case http.StatusGone, http.StatusNotFound:
		return fmt.Errorf("%w: Web Push %s", ErrUnregistered, reasonOr(string(raw), resp.StatusCode))
	case http.StatusBadRequest:
		return fmt.Errorf("%w: Web Push %s", ErrBadToken, reasonOr(string(raw), resp.StatusCode))
	default:
		return fmt.Errorf("Web Push 暂时不可用（%d %s）", resp.StatusCode, reasonOr(string(raw), resp.StatusCode))
	}
}

func (c *WebPushClient) vapidJWT(audience string) (string, error) {
	header, err := json.Marshal(map[string]string{"alg": "ES256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	now := c.now()
	claims, err := json.Marshal(map[string]any{
		"aud": audience,
		"exp": now.Add(12 * time.Hour).Unix(),
		"sub": c.cfg.Subject,
	})
	if err != nil {
		return "", err
	}
	input := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(input))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", fmt.Errorf("签名 VAPID JWT: %w", err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return input + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

type webSubscription struct {
	Endpoint string `json:"endpoint"`
}

func decodeSubscription(raw string) (webSubscription, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(raw))
	if err != nil {
		return webSubscription{}, errors.New("订阅不是 base64url")
	}
	var sub webSubscription
	if err := json.Unmarshal(decoded, &sub); err != nil || sub.Endpoint == "" {
		return webSubscription{}, errors.New("订阅 JSON 缺少 endpoint")
	}
	return sub, nil
}

// VerifyVAPIDToken 供测试校验 VAPID JWT 的签名与声明。
func VerifyVAPIDToken(token string, pub *ecdsa.PublicKey, audience, subject string) error {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return errors.New("JWT 段数非法")
	}
	h, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return errors.New("JWT 头编码非法")
	}
	var header struct{ Alg string }
	if err := json.Unmarshal(h, &header); err != nil || header.Alg != "ES256" {
		return errors.New("JWT 头非法")
	}
	c, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return errors.New("JWT 声明编码非法")
	}
	var claims struct {
		Aud string `json:"aud"`
		Sub string `json:"sub"`
	}
	if err := json.Unmarshal(c, &claims); err != nil || claims.Aud != audience || claims.Sub != subject {
		return errors.New("JWT 声明非法")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return errors.New("JWT 签名非法")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return errors.New("JWT 签名校验失败")
	}
	return nil
}
