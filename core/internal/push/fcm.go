package push

// Firebase Cloud Messaging HTTP v1 唤醒推送发送端。
//
// 只发送 data 消息（无 notification 字段），不携带正文/发送者/会话信息；
// 客户端收到后自行走离线通道拉取密文。凭证由部署者通过服务账号 JSON 提供，
// 未配置时构造阶段即返回明确错误，不影响进程启动。

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	fcmTokenURL  = "https://oauth2.googleapis.com/token"
	fcmSendURL   = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
	fcmScope     = "https://www.googleapis.com/auth/firebase.messaging"
	fcmGrantType = "urn:ietf:params:oauth:grant-type:jwt-bearer"
	fcmTokenTTL  = 50 * time.Minute
)

// FCMConfig 是 FCM 服务账号凭证。
type FCMConfig struct {
	ProjectID     string
	ClientEmail   string
	PrivateKeyPEM string
	// TokenURL / SendURL 可覆盖，仅用于测试。
	TokenURL string
	SendURL  string
	// HTTPClient 可选；默认 10s 超时。
	HTTPClient *http.Client
	Now        func() time.Time
}

// FCMClient 是并发安全的 FCM data 消息发送端。
type FCMClient struct {
	cfg     FCMConfig
	key     *rsa.PrivateKey
	sendURL string
	hc      *http.Client
	now     func() time.Time

	mu      sync.Mutex
	oauth   string
	oauthAt time.Time
}

// ServiceAccount 是 Google 服务账号 JSON 的最小字段集。
type ServiceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
}

// NewFCM 从服务账号 JSON 构造 FCM 发送端；缺少任一凭证字段时返回错误。
func NewFCM(sa ServiceAccount) (*FCMClient, error) {
	sa.ProjectID = strings.TrimSpace(sa.ProjectID)
	sa.ClientEmail = strings.TrimSpace(sa.ClientEmail)
	if sa.ProjectID == "" || sa.ClientEmail == "" || strings.TrimSpace(sa.PrivateKey) == "" {
		return nil, errors.New("FCM 配置缺少 project_id / client_email / private_key")
	}
	key, err := parseRSAPrivateKey([]byte(sa.PrivateKey))
	if err != nil {
		return nil, fmt.Errorf("解析 FCM 服务账号私钥: %w", err)
	}
	cfg := FCMConfig{
		ProjectID:     sa.ProjectID,
		ClientEmail:   sa.ClientEmail,
		PrivateKeyPEM: sa.PrivateKey,
	}
	return newFCMWithConfig(cfg, key)
}

func newFCMWithConfig(cfg FCMConfig, key *rsa.PrivateKey) (*FCMClient, error) {
	hc := cfg.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: defaultTimeout}
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	sendURL := strings.TrimSpace(cfg.SendURL)
	if sendURL == "" {
		sendURL = fmt.Sprintf(fcmSendURL, url.PathEscape(cfg.ProjectID))
	}
	tokenURL := strings.TrimSpace(cfg.TokenURL)
	if tokenURL == "" {
		tokenURL = fcmTokenURL
	}
	cfg.TokenURL = tokenURL
	return &FCMClient{cfg: cfg, key: key, sendURL: sendURL, hc: hc, now: now}, nil
}

func parseRSAPrivateKey(raw []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("服务账号私钥不是 PEM 格式")
	}
	if parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		key, ok := parsed.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("服务账号私钥不是 RSA 密钥")
		}
		return key, nil
	}
	key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("解析 RSA 私钥: %w", err)
	}
	return key, nil
}

// PushSilent 发送一条无通知的 data 消息。
func (c *FCMClient) PushSilent(ctx context.Context, account, deviceToken string) error {
	token := strings.TrimSpace(deviceToken)
	if token == "" {
		return fmt.Errorf("%w: FCM 设备令牌为空", ErrBadToken)
	}
	oauth, err := c.accessToken(ctx)
	if err != nil {
		return err
	}
	body, err := json.Marshal(map[string]any{
		"message": map[string]any{
			"token": token,
			"data": map[string]string{
				"has_offline": "1",
				"acct":        account,
			},
			"android": map[string]any{"priority": "HIGH"},
		},
	})
	if err != nil {
		return fmt.Errorf("编码 FCM 消息: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.sendURL, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("构造 FCM 请求: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+oauth)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("请求 FCM: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxRespBytes))
	switch resp.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusBadRequest:
		return fmt.Errorf("%w: FCM %s", ErrBadToken, reasonOr(string(raw), resp.StatusCode))
	case http.StatusUnauthorized, http.StatusForbidden:
		c.invalidate()
		return fmt.Errorf("%w: FCM %s", ErrAuth, reasonOr(string(raw), resp.StatusCode))
	default:
		return fmt.Errorf("FCM 暂时不可用（%d %s）", resp.StatusCode, reasonOr(string(raw), resp.StatusCode))
	}
}

func (c *FCMClient) accessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.oauth != "" && now.Sub(c.oauthAt) < fcmTokenTTL {
		return c.oauth, nil
	}
	assertion, err := c.mintJWT(now)
	if err != nil {
		return "", err
	}
	form := url.Values{}
	form.Set("grant_type", fcmGrantType)
	form.Set("assertion", assertion)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.TokenURL,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("构造 OAuth 请求: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("请求 OAuth 令牌: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxRespBytes))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("OAuth 令牌请求失败（%d %s）", resp.StatusCode, reasonOr(string(raw), resp.StatusCode))
	}
	var data struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &data); err != nil || data.AccessToken == "" {
		return "", errors.New("OAuth 响应缺少 access_token")
	}
	c.oauth = data.AccessToken
	c.oauthAt = now
	return c.oauth, nil
}

func (c *FCMClient) invalidate() {
	c.mu.Lock()
	c.oauth = ""
	c.mu.Unlock()
}

func (c *FCMClient) mintJWT(now time.Time) (string, error) {
	header, err := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"iss":   c.cfg.ClientEmail,
		"scope": fcmScope,
		"aud":   c.cfg.TokenURL,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	})
	if err != nil {
		return "", err
	}
	input := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(input))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("签名 OAuth JWT: %w", err)
	}
	return input + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}
