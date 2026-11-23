// Package directory 实现 Nexmem 索引服务（P3-04）：公开档案与上传票据池。
//
// 服务只保存公钥类数据与 presigned URL，不保存消息明文、S3 凭证或正文日志。
// 票据领取为原子操作，同一张票最多被一个发送方领取。
package directory

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
	"google.golang.org/protobuf/proto"
)

const (
	maxProfileBytes = 1 << 20 // 公开档案上限 1 MiB
	maxTicketsBytes = 4 << 20 // 单批票据上限 4 MiB
	maxTicketsBatch = 4096    // 单次交存票据上限
	maxTake         = 100     // 单次领取票据上限
	maxTicketKeyLen = 512
	maxTicketURLLen = 8192
)

// Server 是索引服务实例，持有 SQLite 连接与路由。
type Server struct {
	db  *sql.DB
	now func() time.Time
	cfg Config

	// lastTicketCleanup 是上次清理过期票据的真实时间（UnixNano）。
	// 清理是维护操作，限频执行以避免高频并发领取反复争抢 SQLite 写锁（R-24）。
	lastTicketCleanup atomic.Int64

	ipLimiter      *rateLimiter
	accountLimiter *rateLimiter
	takeLimiter    *rateLimiter
	wakeLimiter    *rateLimiter
	reportLimiter  *rateLimiter
	push           PushSender
}

// New 打开（不存在则创建）索引服务数据库并初始化表结构，使用默认限流与签名策略。
func New(dbPath string) (*Server, error) {
	return NewWithConfig(dbPath, Config{})
}

// NewWithConfig 与 New 相同，但允许注入时钟、签名偏移与限流阈值。
func NewWithConfig(dbPath string, cfg Config) (*Server, error) {
	if strings.TrimSpace(dbPath) == "" {
		return nil, errors.New("索引服务数据库路径为空")
	}
	if dir := filepath.Dir(dbPath); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("创建索引服务数据目录: %w", err)
		}
	}

	db, err := store.Open(dbPath)
	if err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), directorySchema); err != nil {
		db.Close()
		return nil, fmt.Errorf("初始化索引服务表结构: %w", err)
	}

	cfg = cfg.withDefaults()
	s := &Server{db: db, now: cfg.Now, cfg: cfg, push: cfg.Push}
	s.ipLimiter = newRateLimiter(cfg.PerIPPerSecond, time.Second, s.now)
	s.accountLimiter = newRateLimiter(cfg.PerAccountPerSecond, time.Second, s.now)
	s.takeLimiter = newRateLimiter(cfg.TakePerAccountPerSecond, time.Second, s.now)
	s.wakeLimiter = newRateLimiter(cfg.WakePerAccountPerSecond, time.Second, s.now)
	s.reportLimiter = newRateLimiter(cfg.ReportPerAccountPerSecond, time.Second, s.now)
	return s, nil
}

// Close 释放数据库连接。
func (s *Server) Close() error {
	return s.db.Close()
}

// Handler 返回索引服务的 HTTP 路由；所有 /v1 接口要求签名鉴权并通过限流。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("PUT /v1/profile", s.protect(s.handlePutProfile, protectOptions{}))
	mux.HandleFunc("GET /v1/profile/{account}", s.protect(s.handleGetProfile, protectOptions{}))
	mux.HandleFunc("POST /v1/inbox/{account}/tickets", s.protect(s.handlePutTickets, protectOptions{bindPathAccount: true}))
	mux.HandleFunc("GET /v1/inbox/{account}/tickets", s.protect(s.handleTakeTickets, protectOptions{takeLimited: true}))
	mux.HandleFunc("POST /v1/push/token", s.protect(s.handlePutPushToken, protectOptions{}))
	mux.HandleFunc("DELETE /v1/push/token", s.protect(s.handleDeletePushToken, protectOptions{}))
	mux.HandleFunc("POST /v1/push/wake/{account}", s.protect(s.handleWake, protectOptions{wakeLimited: true}))
	mux.HandleFunc("POST /v1/report", s.protect(s.handleSubmitReport, protectOptions{reportLimited: true}))
	return s.limitIP(mux)
}

type profileResponse struct {
	Account   string `json:"account"`
	UpdatedAt int64  `json:"updated_at"`
	Devices   int    `json:"devices"`
}

func (s *Server) handlePutProfile(w http.ResponseWriter, r *http.Request) {
	raw, err := readLimited(r.Body, maxProfileBytes)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, err.Error())
		return
	}

	var p nexmemv1.PublicProfile
	if err := proto.Unmarshal(raw, &p); err != nil {
		writeError(w, http.StatusBadRequest, "公开档案解码失败")
		return
	}
	if err := identity.VerifyPublicProfile(&p, s.now()); err != nil {
		writeError(w, http.StatusBadRequest, "公开档案校验失败: "+err.Error())
		return
	}

	account := accountID(p.AccountPub)
	if signer, ok := signerAccount(r.Context()); ok && signer != account {
		writeError(w, http.StatusForbidden, "签名账号与档案账号不一致")
		return
	}
	if err := s.putProfile(r.Context(), account, raw, p.UpdatedAt); err != nil {
		if errors.Is(err, ErrStaleProfile) {
			writeError(w, http.StatusConflict, err.Error())
			return
		}
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, profileResponse{
		Account:   account,
		UpdatedAt: p.UpdatedAt,
		Devices:   len(p.Devices),
	})
}

func (s *Server) handleGetProfile(w http.ResponseWriter, r *http.Request) {
	account, err := canonicalAccount(r.PathValue("account"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	raw, err := s.getProfile(r.Context(), account)
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "公开档案不存在")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/x-protobuf")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

type ticketBatchResponse struct {
	Accepted   int `json:"accepted"`
	Duplicates int `json:"duplicates"`
}

func (s *Server) handlePutTickets(w http.ResponseWriter, r *http.Request) {
	account, err := canonicalAccount(r.PathValue("account"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	raw, err := readLimited(r.Body, maxTicketsBytes)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, err.Error())
		return
	}
	var batch blob.TicketBatch
	if err := json.Unmarshal(raw, &batch); err != nil {
		writeError(w, http.StatusBadRequest, "票据批次 JSON 非法")
		return
	}
	if err := s.validateBatch(&batch, account); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	added, err := s.addTickets(r.Context(), account, batch.DeviceID, batch.Tickets)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, ticketBatchResponse{
		Accepted:   added,
		Duplicates: len(batch.Tickets) - added,
	})
}

type takeTicketsResponse struct {
	Tickets   []blob.Ticket `json:"tickets"`
	Remaining int           `json:"remaining"`
}

func (s *Server) handleTakeTickets(w http.ResponseWriter, r *http.Request) {
	account, err := canonicalAccount(r.PathValue("account"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	take, err := parseTake(r.URL.Query().Get("take"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	now := s.now().Unix()
	tickets, err := s.takeTickets(r.Context(), account, take, now)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	remaining, err := s.countTickets(r.Context(), account, now)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, takeTicketsResponse{Tickets: tickets, Remaining: remaining})
}

// validateBatch 校验票据批次归属、有效期与每张票的对象键和 URL 形态。
func (s *Server) validateBatch(batch *blob.TicketBatch, account string) error {
	if batch.AccountPub != account {
		return errors.New("票据批次账号与路径不一致")
	}
	if strings.TrimSpace(batch.DeviceID) == "" {
		return errors.New("票据批次缺少设备 ID")
	}
	now := s.now().Unix()
	if batch.ExpiresAt <= now {
		return errors.New("票据批次已过期")
	}
	if len(batch.Tickets) == 0 {
		return errors.New("票据批次为空")
	}
	if len(batch.Tickets) > maxTicketsBatch {
		return fmt.Errorf("票据数量 %d 超出上限 %d", len(batch.Tickets), maxTicketsBatch)
	}

	prefix := blob.OfflineObjectPrefix + "/" + account + "/inbox/"
	for i, t := range batch.Tickets {
		if err := validateTicket(t, prefix, now); err != nil {
			return fmt.Errorf("第 %d 张票据非法: %w", i, err)
		}
	}
	return nil
}

func validateTicket(t blob.Ticket, prefix string, now int64) error {
	if !strings.HasPrefix(t.Key, prefix) || len(t.Key) > maxTicketKeyLen {
		return errors.New("对象键不在本账号 inbox 前缀下")
	}
	if t.ExpiresAt <= now {
		return errors.New("票据已过期")
	}
	if len(t.URL) > maxTicketURLLen {
		return errors.New("票据 URL 过长")
	}
	u, err := url.Parse(t.URL)
	if err != nil {
		return errors.New("票据 URL 无法解析")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("票据 URL 协议 %q 不支持", u.Scheme)
	}
	if u.Host == "" {
		return errors.New("票据 URL 缺少主机")
	}
	if u.Query().Get("X-Amz-Signature") == "" {
		return errors.New("票据 URL 缺少签名")
	}
	return nil
}

// canonicalAccount 解析路径中的账号公钥（无填充 base64url），并返回规范编码。
func canonicalAccount(raw string) (string, error) {
	pub, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return "", errors.New("账号编码不是无填充 base64url")
	}
	if len(pub) != blob.AccountPubSize {
		return "", fmt.Errorf("账号公钥长度 %d，期望 %d", len(pub), blob.AccountPubSize)
	}
	return accountID(pub), nil
}

func accountID(pub []byte) string {
	return base64.RawURLEncoding.EncodeToString(pub)
}

func parseTake(raw string) (int, error) {
	if raw == "" {
		return 1, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 || n > maxTake {
		return 0, fmt.Errorf("take 必须是 1～%d 的整数", maxTake)
	}
	return n, nil
}

func readLimited(body io.ReadCloser, limit int64) ([]byte, error) {
	defer body.Close()
	raw, err := io.ReadAll(io.LimitReader(body, limit+1))
	if err != nil {
		return nil, fmt.Errorf("读取请求体: %w", err)
	}
	if int64(len(raw)) > limit {
		return nil, fmt.Errorf("请求体超过 %d 字节", limit)
	}
	return raw, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
