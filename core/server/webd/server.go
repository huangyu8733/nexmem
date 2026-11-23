// Package webd 实现自托管 Web 网关（P1-15）：浏览器经 WebSocket 复用
// Gateway 的 Request/Response/Event 契约，内核运行在用户自有服务器上。
//
// 设计约束（docs/Nexmem-engineering-plan.md §6.1）：
//   - 浏览器不承载内核：DHT、打洞与对象存储读写全部在服务端完成；
//   - 网关只做字节搬运与令牌门禁，业务语义统一由 core/gateway 提供；
//   - 必须携带访问令牌，未认证连接在握手阶段即被拒绝。
package webd

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nexmem/core/gateway"
)

const (
	// DefaultMaxMessageSize 是单条请求信封上限，与跨通道 64 KiB 约束一致。
	DefaultMaxMessageSize = 64 << 10
	// DefaultRequestTimeout 是单条请求的处理上限。
	DefaultRequestTimeout = 30 * time.Second
	// sendQueue 是单个连接的待发送队列长度；持续堆积说明客户端失联，直接断开。
	sendQueue = 64
	// writeWait 是单帧写超时。
	writeWait = 10 * time.Second
)

// 配置错误。
var (
	ErrTokenRequired      = errors.New("访问令牌不能为空")
	ErrGatewayRequired    = errors.New("缺少 gateway 实例")
	ErrTokenFileEmpty     = errors.New("未配置令牌文件")
	ErrTokenFileEmptyFile = errors.New("令牌文件内容为空")
)

// Config 是 Web 网关的运行参数。
type Config struct {
	// Token 是唯一访问令牌，浏览器经 Authorization: Bearer 或 ?token= 携带。
	Token string
	// TokenFile 非空时从文件读取令牌（与 Token 二选一，同时存在时文件优先），
	// 并可通过 ReloadTokenFile 在运行期热轮换。
	TokenFile string
	// Gateway 是请求分发目标，必须由调用方提供（通常是 gateway.New()）。
	Gateway *gateway.Gateway
	// StaticDir 是 Flutter Web 产物目录；为空时只暴露 /ws 与 /healthz。
	StaticDir string
	// AllowedOrigins 非空时按完整 Origin 白名单校验；为空时只允许同源与不带 Origin 的客户端。
	AllowedOrigins []string
	// MaxMessageSize 留空使用 DefaultMaxMessageSize。
	MaxMessageSize int64
	// RequestTimeout 留空使用 DefaultRequestTimeout。
	RequestTimeout time.Duration
	// EventBufferSize 是事件重放缓冲容量，留空使用 DefaultEventBufferSize。
	EventBufferSize int
}

// Server 是 WebSocket 网关，允许多个浏览器连接同时使用。
type Server struct {
	token     atomic.Value // []byte，支持运行期热轮换
	tokenFile string
	gw        *gateway.Gateway
	maxSize   int64
	timeout   time.Duration
	origins   []string
	static    string
	upgrade   websocket.Upgrader

	mu     sync.Mutex
	conns  map[*session]struct{}
	buf    *eventBuffer
	seq    uint64
	closed bool
}

// New 校验配置并构造网关；Token 与 TokenFile 同时为空时直接拒绝启动。
func New(cfg Config) (*Server, error) {
	token, err := resolveToken(cfg)
	if err != nil {
		return nil, err
	}
	if cfg.Gateway == nil {
		return nil, ErrGatewayRequired
	}
	maxSize := cfg.MaxMessageSize
	if maxSize <= 0 {
		maxSize = DefaultMaxMessageSize
	}
	timeout := cfg.RequestTimeout
	if timeout <= 0 {
		timeout = DefaultRequestTimeout
	}
	s := &Server{
		gw:        cfg.Gateway,
		maxSize:   maxSize,
		timeout:   timeout,
		origins:   append([]string(nil), cfg.AllowedOrigins...),
		static:    cfg.StaticDir,
		tokenFile: strings.TrimSpace(cfg.TokenFile),
		conns:     make(map[*session]struct{}),
		buf:       newEventBuffer(cfg.EventBufferSize),
	}
	s.token.Store([]byte(token))
	s.upgrade = websocket.Upgrader{
		ReadBufferSize:  4096,
		WriteBufferSize: 4096,
		CheckOrigin:     s.checkOrigin,
	}
	return s, nil
}

// resolveToken 以令牌文件优先，其次使用显式令牌。
func resolveToken(cfg Config) (string, error) {
	if path := strings.TrimSpace(cfg.TokenFile); path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("读取令牌文件 %s: %w", path, err)
		}
		token := strings.TrimSpace(string(raw))
		if token == "" {
			return "", ErrTokenFileEmptyFile
		}
		return token, nil
	}
	token := strings.TrimSpace(cfg.Token)
	if token == "" {
		return "", ErrTokenRequired
	}
	return token, nil
}

// Handler 返回 HTTP 路由：/ws 为 WebSocket 通道，/healthz 为存活探测，
// 其余路径在配置了 StaticDir 时提供静态资源与单页回退。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/healthz", s.handleHealth)
	if s.static != "" {
		mux.Handle("/", s.staticHandler())
	}
	return mux
}

// Connections 返回当前已认证连接数，用于运维观测。
func (s *Server) Connections() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns)
}

// Broadcast 把一条事件推送给所有已认证连接。data 为 nil 表示不带载荷；
// json.RawMessage 直接使用，其余类型按 JSON 编码。返回值是成功入队的连接数。
// 事件在分配 seq 后写入重放缓冲，供断线重连的客户端按 seq 补齐缺口。
func (s *Server) Broadcast(eventType string, data any) (int, error) {
	raw, err := marshalData(data)
	if err != nil {
		return 0, err
	}
	event := gateway.Event{
		Type: eventType,
		TS:   time.Now().UnixMilli(),
		Data: raw,
	}

	s.mu.Lock()
	s.seq++
	event.Seq = s.seq
	payload, err := json.Marshal(event)
	if err != nil {
		s.mu.Unlock()
		return 0, err
	}
	s.buf.append(event.Seq, payload)
	sessions := make([]*session, 0, len(s.conns))
	for c := range s.conns {
		sessions = append(sessions, c)
	}
	s.mu.Unlock()

	delivered := 0
	for _, c := range sessions {
		if c.send(websocket.TextMessage, payload) {
			delivered++
			continue
		}
		// 队列满说明该连接已无法保证事件一致性，断开后由客户端重新同步。
		c.close()
	}
	return delivered, nil
}

// Close 断开全部连接并禁止后续握手。
func (s *Server) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	sessions := make([]*session, 0, len(s.conns))
	for c := range s.conns {
		sessions = append(sessions, c)
	}
	s.conns = make(map[*session]struct{})
	s.mu.Unlock()
	for _, c := range sessions {
		c.close()
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="nexmem"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	conn, err := s.upgrade.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade 失败时已写入 HTTP 错误响应。
		return
	}
	sess := &session{
		conn: conn,
		out:  make(chan frame, sendQueue),
		done: make(chan struct{}),
	}
	if !s.add(sess) {
		sess.close()
		return
	}
	defer s.remove(sess)

	conn.SetReadLimit(s.maxSize)
	go sess.writeLoop()
	if since, ok := parseSince(r); ok {
		if !s.resume(sess, since) {
			return
		}
	}

	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
		resp := s.gw.Serve(ctx, payload)
		cancel()
		if !sess.send(websocket.TextMessage, resp) {
			return
		}
	}
}

// resume 按客户端上报的 lastSeq 补齐断线期间的事件。缓冲能覆盖缺口时逐帧重放，
// 否则下发 resync_required，由客户端重新拉取首页数据。返回 false 表示连接已不可用。
func (s *Server) resume(sess *session, since uint64) bool {
	s.mu.Lock()
	items, ok := s.buf.replay(since)
	oldest, latest := s.buf.oldest(), s.buf.latest()
	if latest < s.seq {
		latest = s.seq
	}
	s.mu.Unlock()

	if !ok {
		payload, err := resyncEvent("gap", since, oldest, latest)
		if err != nil {
			return true
		}
		return sess.send(websocket.TextMessage, payload)
	}
	for _, item := range items {
		if !sess.send(websocket.TextMessage, item.payload) {
			return false
		}
	}
	return true
}

// parseSince 读取握手查询参数 ?since=<lastSeq>；缺省或非法时表示不重放历史。
func parseSince(r *http.Request) (uint64, bool) {
	raw := strings.TrimSpace(r.URL.Query().Get("since"))
	if raw == "" {
		return 0, false
	}
	v, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func (s *Server) add(sess *session) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return false
	}
	s.conns[sess] = struct{}{}
	return true
}

func (s *Server) remove(sess *session) {
	s.mu.Lock()
	delete(s.conns, sess)
	s.mu.Unlock()
	sess.close()
}

// authorized 接受三种令牌位置：Authorization: Bearer、?token= 与 X-Nexmem-Token。
func (s *Server) authorized(r *http.Request) bool {
	token := bearerToken(r.Header.Get("Authorization"))
	if token == "" {
		token = r.URL.Query().Get("token")
	}
	if token == "" {
		token = r.Header.Get("X-Nexmem-Token")
	}
	return subtle.ConstantTimeCompare([]byte(token), s.currentToken()) == 1
}

// currentToken 返回当前生效的访问令牌。
func (s *Server) currentToken() []byte {
	v, _ := s.token.Load().([]byte)
	return v
}

// SetToken 在运行期切换访问令牌；旧连接会被断开，必须用新令牌重新握手。
// 返回是否发生变化。空令牌返回 ErrTokenRequired。
func (s *Server) SetToken(token string) (bool, error) {
	next := strings.TrimSpace(token)
	if next == "" {
		return false, ErrTokenRequired
	}
	if subtle.ConstantTimeCompare([]byte(next), s.currentToken()) == 1 {
		return false, nil
	}
	s.token.Store([]byte(next))
	s.dropSessions()
	return true, nil
}

// ReloadTokenFile 重新读取令牌文件；令牌变化时切换并断开旧连接。
// 返回是否发生变化。未配置令牌文件时返回 ErrTokenFileEmpty。
func (s *Server) ReloadTokenFile() (bool, error) {
	if s.tokenFile == "" {
		return false, ErrTokenFileEmpty
	}
	raw, err := os.ReadFile(s.tokenFile)
	if err != nil {
		return false, fmt.Errorf("读取令牌文件 %s: %w", s.tokenFile, err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return false, ErrTokenFileEmptyFile
	}
	return s.SetToken(token)
}

// dropSessions 断开全部已认证连接，令牌轮换后强制客户端重新认证。
func (s *Server) dropSessions() {
	s.mu.Lock()
	sessions := make([]*session, 0, len(s.conns))
	for c := range s.conns {
		sessions = append(sessions, c)
	}
	s.conns = make(map[*session]struct{})
	s.mu.Unlock()
	for _, c := range sessions {
		c.closeWith(websocket.ClosePolicyViolation, "token rotated")
	}
}

func bearerToken(header string) string {
	const prefix = "bearer "
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}

// checkOrigin 阻止跨站浏览器连接；白名单为空时只放行同源请求。
func (s *Server) checkOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		// 非浏览器客户端（CLI、测试）不携带 Origin。
		return true
	}
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	if len(s.origins) > 0 {
		for _, allowed := range s.origins {
			if strings.EqualFold(strings.TrimSuffix(allowed, "/"), strings.TrimSuffix(origin, "/")) {
				return true
			}
		}
		return false
	}
	return strings.EqualFold(u.Host, r.Host)
}

// staticHandler 提供静态资源并支持单页应用回退：未知路径返回 index.html，
// 由前端路由接管；路径按 path.Clean 规范化，http.Dir 自身也会拒绝越界访问。
func (s *Server) staticHandler() http.Handler {
	fs := http.Dir(s.static)
	files := http.FileServer(fs)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path == "/" {
			files.ServeHTTP(w, r)
			return
		}
		if f, err := fs.Open(path.Clean(r.URL.Path)); err == nil {
			_ = f.Close()
			files.ServeHTTP(w, r)
			return
		}
		index := *r
		index.URL = new(url.URL)
		*index.URL = *r.URL
		index.URL.Path = "/"
		files.ServeHTTP(w, &index)
	})
}

func marshalData(data any) (json.RawMessage, error) {
	switch v := data.(type) {
	case nil:
		return nil, nil
	case json.RawMessage:
		return v, nil
	case []byte:
		if !json.Valid(v) {
			return nil, errors.New("事件载荷不是合法 JSON")
		}
		return json.RawMessage(v), nil
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return nil, err
		}
		return json.RawMessage(b), nil
	}
}

// frame 是待写入客户端的一帧。
type frame struct {
	kind int
	data []byte
}

// session 表示一个已认证的浏览器连接，写操作全部收敛到 writeLoop。
type session struct {
	conn *websocket.Conn
	out  chan frame
	done chan struct{}
	once sync.Once
}

func (s *session) send(kind int, data []byte) bool {
	select {
	case s.out <- frame{kind: kind, data: data}:
		return true
	case <-s.done:
		return false
	default:
		return false
	}
}

func (s *session) writeLoop() {
	for {
		select {
		case <-s.done:
			return
		case f := <-s.out:
			_ = s.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := s.conn.WriteMessage(f.kind, f.data); err != nil {
				s.close()
				return
			}
		}
	}
}

func (s *session) close() {
	s.once.Do(func() {
		close(s.done)
		_ = s.conn.Close()
	})
}

// closeWith 先发送关闭帧再断开，让客户端明确知道连接因策略原因终止。
func (s *session) closeWith(code int, reason string) {
	s.once.Do(func() {
		_ = s.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(code, reason), time.Now().Add(writeWait))
		close(s.done)
		_ = s.conn.Close()
	})
}
