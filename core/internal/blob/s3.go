// Package blob 提供 S3 兼容对象存储的客户端抽象（P3-02）。
//
// 同一套接口覆盖 Cloudflare R2、MinIO 以及 OSS / COS 等 S3 兼容实现：
// 仅依赖标准库，内置 AWS Signature V4、一次性 presigned URL、
// 分页列举与统一错误分类（S3_AUTH / S3_QUOTA / S3_IO）。
package blob

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	signAlgorithm   = "AWS4-HMAC-SHA256"
	signService     = "s3"
	signTerminator  = "aws4_request"
	amzDateLayout   = "20060102T150405Z"
	dateScopeLayout = "20060102"
	unsignedPayload = "UNSIGNED-PAYLOAD"

	// EmptyPayloadHash 是空请求体的 SHA-256 十六进制值。
	EmptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

	maxPresignTTL = 7 * 24 * time.Hour
	maxErrorBody  = 8 << 10
)

// 统一错误分类，对应契约错误码 S3_AUTH / S3_QUOTA / S3_IO / NOT_FOUND。
var (
	// ErrAuth 表示凭证无效、签名不匹配或无权访问桶。
	ErrAuth = errors.New("S3 鉴权失败")
	// ErrQuota 表示限流、带宽或配额超限，调用方应退避后重试。
	ErrQuota = errors.New("S3 配额或限流")
	// ErrNotFound 表示桶或对象不存在。
	ErrNotFound = errors.New("S3 对象不存在")
	// ErrIO 表示网络、服务端 5xx 或响应解析失败。
	ErrIO = errors.New("S3 IO 错误")
)

// Config 描述一个 S3 兼容后端。
type Config struct {
	// Endpoint 形如 https://<account>.r2.cloudflarestorage.com 或 http://127.0.0.1:9000。
	Endpoint string
	// Region 为签名区域；R2 用 "auto"，MinIO 可用 "us-east-1"。
	Region string
	// Bucket 为桶名，所有操作都限定在该桶内。
	Bucket string
	// AccessKey / SecretKey 为桶的访问凭证；SessionToken 用于临时凭证。
	AccessKey    string
	SecretKey    string
	SessionToken string
	// PathStyle 为 true 时使用 http://host/bucket/key（MinIO 常用），
	// 为 false 时使用虚拟主机风格 http://bucket.host/key（R2 / AWS 常用）。
	PathStyle bool
	// HTTPClient 可选，默认 60s 超时的连接池。
	HTTPClient *http.Client
	// Retries 为可重试错误的额外重试次数，默认 2（共 3 次）。
	Retries int
	// RetryBackoff 为首次重试退避，默认 200ms，之后线性递增。
	RetryBackoff time.Duration
	// OnResponse 可选：每次收到 HTTP 响应（含重试）时回调方法名与状态码，
	// 传输失败时 status 为 0，供诊断指标采集 S3 状态码。
	// 回调运行在请求 goroutine 上，必须立即返回。
	OnResponse func(method string, status int)
}

// ObjectInfo 是对象或列表项的元数据。
type ObjectInfo struct {
	Key          string
	Size         int64
	ETag         string
	LastModified time.Time
	ContentType  string
}

// Client 是并发安全的 S3 客户端。
type Client struct {
	endpoint     *url.URL
	region       string
	bucket       string
	accessKey    string
	secretKey    string
	sessionToken string
	pathStyle    bool
	httpClient   *http.Client
	retries      int
	backoff      time.Duration
	onResponse   func(method string, status int)
	now          func() time.Time
}

// New 校验配置并创建客户端。
func New(cfg Config) (*Client, error) {
	if strings.TrimSpace(cfg.Endpoint) == "" {
		return nil, errors.New("缺少 S3 Endpoint")
	}
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(cfg.Endpoint), "/"))
	if err != nil {
		return nil, fmt.Errorf("解析 S3 Endpoint: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("S3 Endpoint 必须为 http/https: %q", cfg.Endpoint)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("S3 Endpoint 缺少主机: %q", cfg.Endpoint)
	}
	if strings.TrimSpace(cfg.Bucket) == "" {
		return nil, errors.New("缺少 S3 桶名")
	}
	if cfg.AccessKey == "" || cfg.SecretKey == "" {
		return nil, errors.New("缺少 S3 访问凭证")
	}
	region := strings.TrimSpace(cfg.Region)
	if region == "" {
		region = "auto"
	}
	httpClient := cfg.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 60 * time.Second}
	}
	retries := cfg.Retries
	if retries < 0 {
		retries = 0
	}
	backoff := cfg.RetryBackoff
	if backoff <= 0 {
		backoff = 200 * time.Millisecond
	}
	return &Client{
		endpoint:     u,
		region:       region,
		bucket:       cfg.Bucket,
		accessKey:    cfg.AccessKey,
		secretKey:    cfg.SecretKey,
		sessionToken: cfg.SessionToken,
		pathStyle:    cfg.PathStyle,
		httpClient:   httpClient,
		retries:      retries,
		backoff:      backoff,
		onResponse:   cfg.OnResponse,
		now:          time.Now,
	}, nil
}

// Bucket 返回客户端绑定的桶名。
func (c *Client) Bucket() string { return c.bucket }

// Put 上传对象并返回元数据。
func (c *Client) Put(ctx context.Context, key string, data []byte, contentType string) (ObjectInfo, error) {
	if err := validKey(key); err != nil {
		return ObjectInfo{}, err
	}
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	resp, err := c.do(ctx, http.MethodPut, key, nil, data, contentType)
	if err != nil {
		return ObjectInfo{}, err
	}
	drainClose(resp)
	return ObjectInfo{
		Key:         key,
		Size:        int64(len(data)),
		ETag:        trimETag(resp.Header.Get("ETag")),
		ContentType: contentType,
	}, nil
}

// Get 读取对象内容并返回元数据。
func (c *Client) Get(ctx context.Context, key string) ([]byte, ObjectInfo, error) {
	if err := validKey(key); err != nil {
		return nil, ObjectInfo{}, err
	}
	resp, err := c.do(ctx, http.MethodGet, key, nil, nil, "")
	if err != nil {
		return nil, ObjectInfo{}, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, ObjectInfo{}, fmt.Errorf("%w: 读取响应体: %v", ErrIO, err)
	}
	return data, ObjectInfo{
		Key:          key,
		Size:         int64(len(data)),
		ETag:         trimETag(resp.Header.Get("ETag")),
		LastModified: parseHTTPTime(resp.Header.Get("Last-Modified")),
		ContentType:  resp.Header.Get("Content-Type"),
	}, nil
}

// Head 查询对象元数据，不存在时返回 ErrNotFound。
func (c *Client) Head(ctx context.Context, key string) (ObjectInfo, error) {
	if err := validKey(key); err != nil {
		return ObjectInfo{}, err
	}
	resp, err := c.do(ctx, http.MethodHead, key, nil, nil, "")
	if err != nil {
		return ObjectInfo{}, err
	}
	drainClose(resp)
	return ObjectInfo{
		Key:          key,
		Size:         resp.ContentLength,
		ETag:         trimETag(resp.Header.Get("ETag")),
		LastModified: parseHTTPTime(resp.Header.Get("Last-Modified")),
		ContentType:  resp.Header.Get("Content-Type"),
	}, nil
}

// Delete 删除对象，不存在时返回 ErrNotFound。
func (c *Client) Delete(ctx context.Context, key string) error {
	if err := validKey(key); err != nil {
		return err
	}
	resp, err := c.do(ctx, http.MethodDelete, key, nil, nil, "")
	if err != nil {
		return err
	}
	drainClose(resp)
	return nil
}

// List 列出指定前缀下的全部对象，自动翻页。
func (c *Client) List(ctx context.Context, prefix string) ([]ObjectInfo, error) {
	var out []ObjectInfo
	token := ""
	for {
		q := url.Values{"list-type": {"2"}}
		if prefix != "" {
			q.Set("prefix", prefix)
		}
		if token != "" {
			q.Set("continuation-token", token)
		}
		resp, err := c.do(ctx, http.MethodGet, "", q, nil, "")
		if err != nil {
			return nil, err
		}
		var page listBucketResult
		decErr := xml.NewDecoder(resp.Body).Decode(&page)
		resp.Body.Close()
		if decErr != nil {
			return nil, fmt.Errorf("%w: 解析列表响应: %v", ErrIO, decErr)
		}
		for _, item := range page.Contents {
			out = append(out, ObjectInfo{
				Key:          item.Key,
				Size:         item.Size,
				ETag:         trimETag(item.ETag),
				LastModified: parseRFC3339(item.LastModified),
			})
		}
		if !page.IsTruncated || page.NextContinuationToken == "" {
			break
		}
		token = page.NextContinuationToken
	}
	return out, nil
}

// PresignPut 生成一次性上传 URL（PUT），ttl 取值 1s～7 天。
func (c *Client) PresignPut(key string, ttl time.Duration) (string, error) {
	return c.presign(http.MethodPut, key, ttl)
}

// PresignGet 生成一次性下载 URL（GET），ttl 取值 1s～7 天。
func (c *Client) PresignGet(key string, ttl time.Duration) (string, error) {
	return c.presign(http.MethodGet, key, ttl)
}

func (c *Client) presign(method, key string, ttl time.Duration) (string, error) {
	if err := validKey(key); err != nil {
		return "", err
	}
	if ttl < time.Second || ttl > maxPresignTTL {
		return "", fmt.Errorf("presign 有效期 %s 超出 1s～7d 范围", ttl)
	}
	now := c.now().UTC()
	u := c.objectURL(key)
	date := now.Format(dateScopeLayout)
	scope := date + "/" + c.region + "/" + signService + "/" + signTerminator

	q := url.Values{}
	q.Set("X-Amz-Algorithm", signAlgorithm)
	q.Set("X-Amz-Credential", c.accessKey+"/"+scope)
	q.Set("X-Amz-Date", now.Format(amzDateLayout))
	q.Set("X-Amz-Expires", strconv.FormatInt(int64(ttl/time.Second), 10))
	q.Set("X-Amz-SignedHeaders", "host")
	if c.sessionToken != "" {
		q.Set("X-Amz-Security-Token", c.sessionToken)
	}

	canonicalRequest := strings.Join([]string{
		method,
		awsEncodePath(u.Path),
		canonicalQuery(q),
		"host:" + u.Host + "\n",
		"host",
		unsignedPayload,
	}, "\n")
	signature := c.signature(date, now, canonicalRequest)
	q.Set("X-Amz-Signature", signature)

	u.RawQuery = canonicalQuery(q)
	setEscapedPath(u)
	return u.String(), nil
}

// do 执行请求，按状态码做有限重试。
func (c *Client) do(ctx context.Context, method, key string, query url.Values, body []byte, contentType string) (*http.Response, error) {
	attempts := c.retries + 1
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			delay := time.Duration(attempt) * c.backoff
			select {
			case <-ctx.Done():
				return nil, fmt.Errorf("%w: %v", ErrIO, ctx.Err())
			case <-time.After(delay):
			}
		}
		req, err := c.buildRequest(ctx, method, key, query, body, contentType)
		if err != nil {
			return nil, err
		}
		resp, err := c.httpClient.Do(req)
		if err != nil {
			c.reportResponse(method, 0)
			lastErr = fmt.Errorf("%w: %v", ErrIO, err)
			continue
		}
		c.reportResponse(method, resp.StatusCode)
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return resp, nil
		}
		apiErr := readError(resp)
		if !retryableStatus(resp.StatusCode) || attempt == attempts-1 {
			return nil, apiErr
		}
		lastErr = apiErr
	}
	return nil, lastErr
}

// reportResponse 调用可选的响应回调。
func (c *Client) reportResponse(method string, status int) {
	if c.onResponse != nil {
		c.onResponse(method, status)
	}
}

func (c *Client) buildRequest(ctx context.Context, method, key string, query url.Values, body []byte, contentType string) (*http.Request, error) {
	u := c.objectURL(key)
	if len(query) > 0 {
		u.RawQuery = canonicalQuery(query)
	}
	setEscapedPath(u)
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return nil, fmt.Errorf("构造 S3 请求: %w", err)
	}
	req.Host = u.Host

	payloadHash := EmptyPayloadHash
	if body != nil {
		payloadHash = hexSHA256(body)
	}
	now := c.now().UTC()
	req.Header.Set("x-amz-content-sha256", payloadHash)
	req.Header.Set("x-amz-date", now.Format(amzDateLayout))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if c.sessionToken != "" {
		req.Header.Set("x-amz-security-token", c.sessionToken)
	}
	c.signRequest(req, payloadHash, now)
	return req, nil
}

// signRequest 为请求写入 AWS Signature V4 Authorization 头。
func (c *Client) signRequest(req *http.Request, payloadHash string, now time.Time) {
	headers := make(map[string]string, len(req.Header)+1)
	for name, values := range req.Header {
		lower := strings.ToLower(name)
		if lower == "authorization" || lower == "user-agent" || len(values) == 0 {
			continue
		}
		headers[lower] = normalizeHeaderValue(strings.Join(values, ","))
	}
	headers["host"] = req.URL.Host

	canonicalHeaders, signedHeaders := canonicalHeaderList(headers)
	canonicalRequest := strings.Join([]string{
		req.Method,
		awsEncodePath(req.URL.Path),
		canonicalQuery(req.URL.Query()),
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")

	date := now.UTC().Format(dateScopeLayout)
	scope := date + "/" + c.region + "/" + signService + "/" + signTerminator
	signature := c.signature(date, now, canonicalRequest)

	req.Header.Set("Authorization", fmt.Sprintf("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		signAlgorithm, c.accessKey, scope, signedHeaders, signature))
}

// signature 按 SigV4 生成最终签名。
func (c *Client) signature(date string, now time.Time, canonicalRequest string) string {
	scope := date + "/" + c.region + "/" + signService + "/" + signTerminator
	stringToSign := strings.Join([]string{
		signAlgorithm,
		now.UTC().Format(amzDateLayout),
		scope,
		hexSHA256([]byte(canonicalRequest)),
	}, "\n")

	key := hmacSHA256([]byte("AWS4"+c.secretKey), date)
	key = hmacSHA256(key, c.region)
	key = hmacSHA256(key, signService)
	key = hmacSHA256(key, signTerminator)
	return hex.EncodeToString(hmacSHA256(key, stringToSign))
}

// objectURL 按寻址风格构造对象 URL。
func (c *Client) objectURL(key string) *url.URL {
	u := *c.endpoint
	base := strings.TrimSuffix(u.Path, "/")
	key = strings.TrimPrefix(key, "/")

	if c.pathStyle {
		u.Path = base + "/" + c.bucket
		if key != "" {
			u.Path += "/" + key
		}
	} else {
		u.Host = c.bucket + "." + u.Host
		u.Path = base + "/"
		if key != "" {
			u.Path += key
		}
	}
	u.RawPath = ""
	u.RawQuery = ""
	u.Fragment = ""
	return &u
}

func setEscapedPath(u *url.URL) {
	escaped := awsEncodePath(u.Path)
	decoded, err := url.PathUnescape(escaped)
	if err != nil || decoded != u.Path {
		return
	}
	u.RawPath = escaped
}

// awsEncodePath 按 SigV4 规则对路径逐段做 RFC 3986 编码。
func awsEncodePath(path string) string {
	if path == "" {
		return "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	segments := strings.Split(path, "/")
	for i, segment := range segments {
		segments[i] = awsURIEncode(segment)
	}
	return strings.Join(segments, "/")
}

// canonicalQuery 按 SigV4 规则生成规范化查询串。
func canonicalQuery(values url.Values) string {
	type pair struct{ key, value string }
	pairs := make([]pair, 0, len(values))
	for key, list := range values {
		encodedKey := awsURIEncode(key)
		if len(list) == 0 {
			pairs = append(pairs, pair{encodedKey, ""})
			continue
		}
		for _, value := range list {
			pairs = append(pairs, pair{encodedKey, awsURIEncode(value)})
		}
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].key != pairs[j].key {
			return pairs[i].key < pairs[j].key
		}
		return pairs[i].value < pairs[j].value
	})
	var b strings.Builder
	for i, p := range pairs {
		if i > 0 {
			b.WriteByte('&')
		}
		b.WriteString(p.key)
		b.WriteByte('=')
		b.WriteString(p.value)
	}
	return b.String()
}

// canonicalHeaderList 生成规范化请求头与 SignedHeaders。
func canonicalHeaderList(headers map[string]string) (string, string) {
	names := make([]string, 0, len(headers))
	for name := range headers {
		names = append(names, name)
	}
	sort.Strings(names)
	var b strings.Builder
	for _, name := range names {
		b.WriteString(name)
		b.WriteByte(':')
		b.WriteString(headers[name])
		b.WriteByte('\n')
	}
	return b.String(), strings.Join(names, ";")
}

// awsURIEncode 只保留 RFC 3986 非保留字符，其余按 UTF-8 字节百分号编码。
func awsURIEncode(s string) string {
	const hexDigits = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if isUnreserved(ch) {
			b.WriteByte(ch)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hexDigits[ch>>4])
		b.WriteByte(hexDigits[ch&0x0F])
	}
	return b.String()
}

func isUnreserved(ch byte) bool {
	switch {
	case ch >= 'A' && ch <= 'Z', ch >= 'a' && ch <= 'z', ch >= '0' && ch <= '9':
		return true
	case ch == '-', ch == '_', ch == '.', ch == '~':
		return true
	default:
		return false
	}
}

func normalizeHeaderValue(v string) string {
	return strings.Join(strings.Fields(v), " ")
}

func hmacSHA256(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return mac.Sum(nil)
}

func hexSHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func validKey(key string) error {
	if strings.TrimSpace(key) == "" {
		return errors.New("对象键不能为空")
	}
	if strings.HasPrefix(key, "/") {
		return errors.New("对象键不能以 / 开头")
	}
	return nil
}

func retryableStatus(status int) bool {
	return status == http.StatusTooManyRequests || status == http.StatusInternalServerError ||
		status == http.StatusBadGateway || status == http.StatusServiceUnavailable ||
		status == http.StatusGatewayTimeout
}

func readError(resp *http.Response) error {
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBody))
	resp.Body.Close()

	var apiErr errorResponse
	_ = xml.Unmarshal(raw, &apiErr)

	var base error
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		base = ErrAuth
	case resp.StatusCode == http.StatusNotFound || apiErr.Code == "NoSuchKey":
		base = ErrNotFound
	case resp.StatusCode == http.StatusTooManyRequests || isQuotaCode(apiErr.Code):
		base = ErrQuota
	default:
		base = ErrIO
	}

	detail := strings.TrimSpace(apiErr.Code)
	if apiErr.Message != "" {
		detail += " " + apiErr.Message
	}
	if detail == "" {
		return fmt.Errorf("%w: HTTP %d", base, resp.StatusCode)
	}
	return fmt.Errorf("%w: %s (HTTP %d)", base, strings.TrimSpace(detail), resp.StatusCode)
}

func isQuotaCode(code string) bool {
	switch strings.ToLower(code) {
	case "slowdown", "requestlimitexceeded", "quotaexceeded",
		"bandwidthlimitexceeded", "toomanyrequests":
		return true
	default:
		return false
	}
}

func trimETag(etag string) string {
	return strings.Trim(strings.TrimSpace(etag), `"`)
}

func parseHTTPTime(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	if t, err := http.ParseTime(value); err == nil {
		return t
	}
	return time.Time{}
}

func parseRFC3339(value string) time.Time {
	if value == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339, value); err == nil {
		return t
	}
	return time.Time{}
}

func drainClose(resp *http.Response) {
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
}

type errorResponse struct {
	Code    string `xml:"Code"`
	Message string `xml:"Message"`
}

type listBucketResult struct {
	Contents []struct {
		Key          string `xml:"Key"`
		Size         int64  `xml:"Size"`
		ETag         string `xml:"ETag"`
		LastModified string `xml:"LastModified"`
	} `xml:"Contents"`
	IsTruncated           bool   `xml:"IsTruncated"`
	NextContinuationToken string `xml:"NextContinuationToken"`
}
