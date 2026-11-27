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
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
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
	// DefaultMaxUploadSize 是浏览器单次选择上传的总字节上限。
	DefaultMaxUploadSize = 256 << 20
	// sendQueue 是单个连接的待发送队列长度；持续堆积说明客户端失联，直接断开。
	// 断线重放最多 512 条事件，队列需容纳一轮重放，避免握手即误判断连。
	sendQueue = 1024
	// writeWait 是单帧写超时。
	writeWait = 10 * time.Second
	// replayWait 是重放入队的最长等待时间；写入由 writeLoop 统一收敛。
	replayWait = 30 * time.Second
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
	// UploadDir 是浏览器选择文件/目录后上传的落地目录；留空使用系统临时目录。
	UploadDir string
	// DownloadDirs 是 /download 端点额外放行的目录白名单（如内核群文件下载目录）。
	// UploadDir 始终自动放行；本列表用于放行内核写入的其它目录。留空时只放行 UploadDir。
	// 端点会做绝对路径校验与符号链接逃逸防护，仅允许下载白名单目录内的普通文件。
	DownloadDirs []string
	// AllowedOrigins 非空时按完整 Origin 白名单校验；为空时只允许同源与不带 Origin 的客户端。
	AllowedOrigins []string
	// MaxMessageSize 留空使用 DefaultMaxMessageSize。
	MaxMessageSize int64
	// MaxUploadSize 留空使用 DefaultMaxUploadSize。
	MaxUploadSize int64
	// RequestTimeout 留空使用 DefaultRequestTimeout。
	RequestTimeout time.Duration
	// EventBufferSize 是事件重放缓冲容量，留空使用 DefaultEventBufferSize。
	EventBufferSize int
}

// Server 是 WebSocket 网关，允许多个浏览器连接同时使用。
type Server struct {
	token        atomic.Value // []byte，支持运行期热轮换
	tokenFile    string
	gw           *gateway.Gateway
	maxSize      int64
	timeout      time.Duration
	origins      []string
	static       string
	uploadDir    string
	downloadDirs []string // 已 Abs+Clean 的白名单根目录（含 uploadDir）
	maxUpload    int64
	upgrade      websocket.Upgrader

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
	uploadDir := strings.TrimSpace(cfg.UploadDir)
	if uploadDir == "" {
		uploadDir = filepath.Join(os.TempDir(), "nexmem-web-uploads")
	}
	if err := os.MkdirAll(uploadDir, 0o700); err != nil {
		return nil, fmt.Errorf("创建上传目录 %s: %w", uploadDir, err)
	}
	maxUpload := cfg.MaxUploadSize
	if maxUpload <= 0 {
		maxUpload = DefaultMaxUploadSize
	}
	// 下载白名单：uploadDir 始终放行，叠加调用方显式配置的目录；
	// 全部 Abs+Clean 后去重，供 /download 做逃逸校验。
	downloadDirs := make([]string, 0, len(cfg.DownloadDirs)+1)
	seenDir := make(map[string]struct{}, len(cfg.DownloadDirs)+1)
	for _, dir := range append([]string{uploadDir}, cfg.DownloadDirs...) {
		abs, err := filepath.Abs(strings.TrimSpace(dir))
		if err != nil || abs == "" {
			continue
		}
		if _, dup := seenDir[abs]; dup {
			continue
		}
		seenDir[abs] = struct{}{}
		downloadDirs = append(downloadDirs, abs)
	}
	s := &Server{
		gw:           cfg.Gateway,
		maxSize:      maxSize,
		timeout:      timeout,
		origins:      append([]string(nil), cfg.AllowedOrigins...),
		static:       cfg.StaticDir,
		uploadDir:    uploadDir,
		downloadDirs: downloadDirs,
		maxUpload:    maxUpload,
		tokenFile:    strings.TrimSpace(cfg.TokenFile),
		conns:        make(map[*session]struct{}),
		buf:          newEventBuffer(cfg.EventBufferSize),
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

// Handler 返回 HTTP 路由：/ws 为 WebSocket 通道，/auth 为轻量令牌探测，
// /healthz 为存活探测，其余路径在配置了 StaticDir 时提供静态资源与单页回退。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	mux.HandleFunc("/auth", s.handleAuth)
	mux.HandleFunc("/upload", s.handleUpload)
	mux.HandleFunc("/download", s.handleDownload)
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

// handleAuth 给浏览器提供握手前的令牌探测：200 表示令牌有效，401 表示
// 令牌无效或已轮换。WebSocket 握手失败在浏览器里拿不到 HTTP 状态码，
// 客户端据此把「token 错误」与「网络离线」区分开，避免无意义重连。
func (s *Server) handleAuth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="nexmem"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(`{"authorized":true}`))
}

// handleUpload 接收浏览器文件选择器上传的字节，落到网关本机目录后返回
// 内核可读的绝对路径。浏览器拿不到服务端路径，必须通过这一步 bridging。
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="nexmem"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, s.maxUpload)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, "invalid multipart body", http.StatusBadRequest)
		return
	}

	root, err := os.MkdirTemp(s.uploadDir, "pick-")
	if err != nil {
		http.Error(w, "创建上传目录失败", http.StatusInternalServerError)
		return
	}
	fail := func(status int, message string) {
		_ = os.RemoveAll(root)
		http.Error(w, message, status)
	}
	writeJSON := func(payload map[string]any) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(payload)
	}

	if r.FormValue("mode") == "dir" {
		headers := r.MultipartForm.File["files"]
		if len(headers) == 0 {
			fail(http.StatusBadRequest, "目录上传为空")
			return
		}
		relValues := r.MultipartForm.Value["relative_path"]
		relFiles := r.MultipartForm.File["relative_path"]
		relativeAt := func(index int) string {
			if index < len(relValues) {
				return relValues[index]
			}
			if index < len(relFiles) {
				file, err := relFiles[index].Open()
				if err != nil {
					return ""
				}
				raw, err := io.ReadAll(file)
				_ = file.Close()
				if err != nil {
					return ""
				}
				return string(raw)
			}
			return ""
		}
		var total int64
		for i, header := range headers {
			rel := relativeAt(i)
			safe, ok := safeRelativePath(rel)
			if !ok {
				fail(http.StatusBadRequest, "非法相对路径")
				return
			}
			if safe == "" {
				safe = filepath.Base(header.Filename)
			}
			target := filepath.Join(root, filepath.FromSlash(safe))
			file, err := header.Open()
			if err != nil {
				fail(http.StatusBadRequest, "读取上传文件失败")
				return
			}
			err = writeUploadedFile(target, file)
			_ = file.Close()
			if err != nil {
				fail(http.StatusInternalServerError, "写入上传文件失败")
				return
			}
			total += header.Size
		}
		writeJSON(map[string]any{
			"path": root,
			"name": filepath.Base(root),
			"size": total,
		})
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		fail(http.StatusBadRequest, "缺少上传文件")
		return
	}
	defer file.Close()
	name := filepath.Base(header.Filename)
	if name == "." || name == string(filepath.Separator) || name == "" {
		name = "upload.bin"
	}
	target := filepath.Join(root, name)
	if err := writeUploadedFile(target, file); err != nil {
		fail(http.StatusInternalServerError, "写入上传文件失败")
		return
	}
	info, err := os.Stat(target)
	if err != nil {
		fail(http.StatusInternalServerError, "读取上传文件信息失败")
		return
	}
	writeJSON(map[string]any{
		"path": target,
		"name": name,
		"size": info.Size(),
	})
}

// handleDownload 把白名单目录内的文件交给浏览器下载或在线播放。
//
// Web 端内核在网关进程内运行，群文件下载只能落到服务端路径；浏览器拿不到
// 该路径，必须经本端点按 token 鉴权后取回字节。安全约束：
//   - 令牌鉴权与 /ws、/upload 一致，支持 ?token / Authorization / X-Nexmem-Token；
//   - 路径必须落在 downloadDirs 白名单内，且用 EvalSymlinks 解析后仍落在白名单，
//     防止符号链接逃逸到私钥、数据库等敏感文件；
//   - 仅允许普通文件，拒绝目录、设备文件；
//   - Content-Disposition 默认为 attachment 触发保存；聊天媒体在线播放显式传
//     disposition=inline，文件名仍经 mime.FormatMediaType 转义，避免响应头注入；
//   - 仍由 http.ServeFile 输出字节，天然支持 Range / If-Range / HEAD，便于浏览器
//     流式播放与拖动进度，不把整文件读进内存。
func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="nexmem"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	requested := strings.TrimSpace(r.URL.Query().Get("path"))
	if requested == "" {
		http.Error(w, "缺少 path 参数", http.StatusBadRequest)
		return
	}
	realPath, ok := s.resolveDownloadPath(requested)
	if !ok {
		http.Error(w, "文件不在允许的下载目录内", http.StatusForbidden)
		return
	}
	info, err := os.Stat(realPath)
	if err != nil || !info.Mode().IsRegular() {
		http.Error(w, "文件不存在或不是普通文件", http.StatusNotFound)
		return
	}
	name := filepath.Base(realPath)
	disposition := "attachment"
	if strings.EqualFold(r.URL.Query().Get("disposition"), "inline") {
		disposition = "inline"
	}
	w.Header().Set(
		"Content-Disposition",
		mime.FormatMediaType(disposition, map[string]string{"filename": name}),
	)
	w.Header().Set("Cache-Control", "no-store")
	// ServeFile 会设置 Content-Type / Content-Length，并支持 Range / If-Range / HEAD。
	http.ServeFile(w, r, realPath)
}

// resolveDownloadPath 校验下载路径并解析符号链接，返回白名单内的真实绝对路径。
// 请求路径与解析后的真实路径都必须落在同一白名单根目录内，双重校验防逃逸。
func (s *Server) resolveDownloadPath(requested string) (string, bool) {
	abs, err := filepath.Abs(requested)
	if err != nil {
		return "", false
	}
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", false
	}
	real = filepath.Clean(real)
	for _, root := range s.downloadDirs {
		realRoot, err := filepath.EvalSymlinks(root)
		if err != nil {
			continue
		}
		rel, err := filepath.Rel(realRoot, real)
		if err != nil {
			continue
		}
		if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) ||
			filepath.IsAbs(rel) {
			continue
		}
		return real, true
	}
	return "", false
}

// safeRelativePath 把浏览器上报的 webkitRelativePath 收敛为网关内的相对路径，
// 拒绝绝对路径、盘符与向上的路径穿越。
func safeRelativePath(raw string) (string, bool) {
	raw = strings.TrimSpace(strings.ReplaceAll(raw, "\\", "/"))
	if raw == "" {
		return "", true
	}
	if path.IsAbs(raw) || (len(raw) >= 2 && raw[1] == ':') {
		return "", false
	}
	cleaned := path.Clean(raw)
	if cleaned == "." {
		return "", true
	}
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", false
	}
	return cleaned, true
}

func writeUploadedFile(target string, source io.Reader) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return err
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, source)
	return err
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
		return sess.sendWait(websocket.TextMessage, payload, replayWait)
	}
	// 重放必须可靠入队：非阻塞 send 在队列瞬时打满时会返回 false，
	// 上层据此直接关闭连接，用户看到的是「重连后又立刻掉线」。
	for _, item := range items {
		if !sess.sendWait(websocket.TextMessage, item.payload, replayWait) {
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
		// Flutter Web 的 main.dart.js 文件名固定，不能让浏览器长期缓存：
		// 每次重建产物后必须重新校验，否则会一直加载旧界面。
		w.Header().Set("Cache-Control", "no-cache")
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

// sendWait 与 send 类似，但队列满时等待写线程消费，而不是直接判定连接失联。
func (s *session) sendWait(kind int, data []byte, timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case s.out <- frame{kind: kind, data: data}:
		return true
	case <-s.done:
		return false
	case <-timer.C:
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
