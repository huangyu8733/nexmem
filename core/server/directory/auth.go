package directory

// 索引服务的签名鉴权与限流（P3-05）。
//
// 鉴权：所有 /v1 接口必须携带 X-Nexmem-Pub / X-Nexmem-Sig / X-Nexmem-Ts，
// 签名覆盖 method + path?query + ts + body SHA-256；伪造、篡改或过期一律 401。
// 限流：按来源 IP 与账号双维度滑动窗口计数，票据领取接口另有更严格的账号配额，超限 429。

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/nexmem/core/internal/dirsig"
)

const (
	defaultPerIPPerSecond          = 200
	defaultPerAccountPerSecond     = 60
	defaultTakePerAccountPerSecond = 10
	defaultWakePerAccountPerSecond = 2
	// defaultReportPerAccountPerSecond 限制单账号举报提交频率，避免被当成日志洪泛通道。
	defaultReportPerAccountPerSecond = 2
	maxAuthBodyBytes               = 4 << 20
	maxRateEntries                 = 8192
)

// Config 是索引服务的运行参数，零值即默认配置。
type Config struct {
	// Now 可注入时钟，用于测试；为空时使用 time.Now。
	Now func() time.Time
	// MaxClockSkew 是签名时间戳允许的偏移，为空时使用 5 分钟。
	MaxClockSkew time.Duration
	// PerIPPerSecond 是单个来源 IP 每秒请求上限。
	PerIPPerSecond int
	// PerAccountPerSecond 是单个账号每秒请求上限。
	PerAccountPerSecond int
	// TakePerAccountPerSecond 是票据领取接口的单账号每秒上限。
	TakePerAccountPerSecond int
	// WakePerAccountPerSecond 是唤醒推送接口按目标账号的每秒上限。
	WakePerAccountPerSecond int
	// ReportPerAccountPerSecond 是举报提交接口的单账号每秒上限。
	ReportPerAccountPerSecond int
	// Push 是可选的唤醒推送发送器（P6-02）；为空时关闭唤醒推送。
	Push PushSender
}

func (c Config) withDefaults() Config {
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.MaxClockSkew <= 0 {
		c.MaxClockSkew = dirsig.DefaultMaxSkew
	}
	if c.PerIPPerSecond <= 0 {
		c.PerIPPerSecond = defaultPerIPPerSecond
	}
	if c.PerAccountPerSecond <= 0 {
		c.PerAccountPerSecond = defaultPerAccountPerSecond
	}
	if c.TakePerAccountPerSecond <= 0 {
		c.TakePerAccountPerSecond = defaultTakePerAccountPerSecond
	}
	if c.WakePerAccountPerSecond <= 0 {
		c.WakePerAccountPerSecond = defaultWakePerAccountPerSecond
	}
	if c.ReportPerAccountPerSecond <= 0 {
		c.ReportPerAccountPerSecond = defaultReportPerAccountPerSecond
	}
	return c
}

type pubKeyContextKey struct{}

// signerAccount 从请求上下文取出已验签的账号编码。
func signerAccount(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(pubKeyContextKey{}).(string)
	return v, ok
}

// limitIP 在最外层做来源 IP 限流，未通过鉴权的流量同样受限。
func (s *Server) limitIP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.ipLimiter.Allow(clientIP(r)) {
			writeTooMany(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// protectOptions 描述单个路由的鉴权与限流附加要求。
type protectOptions struct {
	// takeLimited 为真时叠加票据领取的单账号配额。
	takeLimited bool
	// bindPathAccount 为真时要求路径账号与签名账号一致（仅票据交存）。
	bindPathAccount bool
	// wakeLimited 为真时叠加唤醒推送按目标账号的配额。
	wakeLimited bool
	// reportLimited 为真时叠加举报提交的单账号配额。
	reportLimited bool
}

// protect 校验请求签名并做账号级限流。
func (s *Server) protect(h http.HandlerFunc, opts protectOptions) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := readSignedBody(r)
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, err.Error())
			return
		}

		cred, err := dirsig.Parse(
			r.Header.Get(dirsig.HeaderPub),
			r.Header.Get(dirsig.HeaderSig),
			r.Header.Get(dirsig.HeaderTimestamp),
		)
		if err != nil {
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}
		if err := dirsig.Verify(cred, r.Method, r.URL.RequestURI(), s.now(), s.cfg.MaxClockSkew, body); err != nil {
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}

		account := dirsig.AccountID(cred.Pub)
		if !s.accountLimiter.Allow(account) {
			writeTooMany(w)
			return
		}
		if opts.takeLimited && !s.takeLimiter.Allow(account) {
			writeTooMany(w)
			return
		}
		// 唤醒推送按目标账号限流，防止单个发送方刷爆接收方设备。
		if opts.wakeLimited {
			target, ok := wakeTargetID(r.URL.Path)
			if !ok {
				writeError(w, http.StatusBadRequest, "唤醒路径账号非法")
				return
			}
			if !s.wakeLimiter.Allow(target) {
				writeTooMany(w)
				return
			}
		}
		if opts.reportLimited && !s.reportLimiter.Allow(account) {
			writeTooMany(w)
			return
		}

		// 票据交存的路径账号必须是签名账号本人，防止替他人写票据池。
		if opts.bindPathAccount {
			if pathAccount, ok := pathAccountID(r.URL.Path); ok && pathAccount != account {
				writeError(w, http.StatusForbidden, "签名账号与路径账号不一致")
				return
			}
		}

		r = r.WithContext(context.WithValue(r.Context(), pubKeyContextKey{}, account))
		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		h(w, r)
	}
}

// readSignedBody 读取请求体用于验签，并限制总体积；无体请求返回空切片。
func readSignedBody(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return nil, nil
	}
	defer r.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(r.Body, maxAuthBodyBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxAuthBodyBytes {
		return nil, fmt.Errorf("请求体超过 %d 字节", maxAuthBodyBytes)
	}
	return raw, nil
}

// pathAccountID 从 /v1/profile/{account} 与 /v1/inbox/{account}/tickets 中取路径账号。
// 路径账号编码非法时返回 false，交由具体 handler 返回 400。
func pathAccountID(path string) (string, bool) {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) < 3 || parts[0] != "v1" {
		return "", false
	}
	switch parts[1] {
	case "profile", "inbox":
		id, err := canonicalAccount(parts[2])
		if err != nil {
			return "", false
		}
		return id, true
	default:
		return "", false
	}
}

// wakeTargetID 从 /v1/push/wake/{account} 中取目标账号编码。
func wakeTargetID(path string) (string, bool) {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) != 4 || parts[0] != "v1" || parts[1] != "push" || parts[2] != "wake" {
		return "", false
	}
	id, err := canonicalAccount(parts[3])
	if err != nil {
		return "", false
	}
	return id, true
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func writeTooMany(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "1")
	writeError(w, http.StatusTooManyRequests, "请求过于频繁，请稍后重试")
}

// rateLimiter 是固定窗口计数器：窗口内计数达到上限即拒绝，窗口到期后自动重置。
type rateLimiter struct {
	mu      sync.Mutex
	limit   int
	window  time.Duration
	now     func() time.Time
	entries map[string]*rateEntry
}

type rateEntry struct {
	start time.Time
	count int
}

func newRateLimiter(limit int, window time.Duration, now func() time.Time) *rateLimiter {
	return &rateLimiter{
		limit:   limit,
		window:  window,
		now:     now,
		entries: make(map[string]*rateEntry),
	}
}

// Allow 记录一次访问并返回是否放行。
func (l *rateLimiter) Allow(key string) bool {
	if l.limit <= 0 {
		return true
	}
	now := l.now()

	l.mu.Lock()
	defer l.mu.Unlock()

	e, ok := l.entries[key]
	if !ok {
		if len(l.entries) >= maxRateEntries {
			l.sweepLocked(now)
		}
		e = &rateEntry{start: now}
		l.entries[key] = e
	} else if now.Sub(e.start) >= l.window {
		e.start = now
		e.count = 0
	}
	if e.count >= l.limit {
		return false
	}
	e.count++
	return true
}

// sweepLocked 清理已过窗口的计数，避免来源分散时内存无界增长。
func (l *rateLimiter) sweepLocked(now time.Time) {
	for key, e := range l.entries {
		if now.Sub(e.start) >= l.window {
			delete(l.entries, key)
		}
	}
	if len(l.entries) >= maxRateEntries {
		l.entries = make(map[string]*rateEntry)
	}
}
