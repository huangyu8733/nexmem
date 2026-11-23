package directory

// 唤醒推送的令牌登记与触发（P6-02）。
//
// 索引服务只保存推送令牌与账号的对应关系，不保存正文；唤醒请求只携带
// "该账号有离线消息"的指针，接收方设备被唤醒后自行走离线通道拉取密文。
// 推送为可选能力：未配置 PushSender 时相关接口保持可用但不发送。

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/nexmem/core/internal/push"
)

const (
	maxPushTokenBytes       = 4 << 10
	maxPushTokensPerAccount = 10
	maxWakeTokens           = 20
	wakeTimeout             = 10 * time.Second
)

// PushSender 是索引服务使用的唤醒推送发送端，通常为 *push.Client。
type PushSender interface {
	PushSilent(ctx context.Context, account, deviceToken string) error
}

var pushTokenPattern = regexp.MustCompile(`^[A-Za-z0-9:_\-\.]{16,512}$`)

type pushTokenRequest struct {
	Token string `json:"token"`
	Env   string `json:"env"`
}

type pushTokenResponse struct {
	Tokens int `json:"tokens"`
}

type pushTokenDeleteResponse struct {
	Removed bool `json:"removed"`
}

type wakeResponse struct {
	Enabled bool `json:"enabled"`
	Sent    int  `json:"sent"`
	Removed int  `json:"removed"`
	Failed  int  `json:"failed"`
}

// handlePutPushToken 登记当前账号（签名账号）的设备推送令牌，重复登记为幂等更新。
func (s *Server) handlePutPushToken(w http.ResponseWriter, r *http.Request) {
	account, ok := signerAccount(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "缺少签名账号")
		return
	}
	req, err := decodePushTokenRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	env, err := normalizePushEnv(req.Env)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	total, err := s.upsertPushToken(r.Context(), account, req.Token, env)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, pushTokenResponse{Tokens: total})
}

// handleDeletePushToken 注销当前账号的单个设备令牌。
func (s *Server) handleDeletePushToken(w http.ResponseWriter, r *http.Request) {
	account, ok := signerAccount(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "缺少签名账号")
		return
	}
	req, err := decodePushTokenRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	removed, err := s.deletePushToken(r.Context(), account, req.Token)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, pushTokenDeleteResponse{Removed: removed})
}

// handleWake 触发目标账号的唤醒推送；未配置推送时返回 enabled=false。
func (s *Server) handleWake(w http.ResponseWriter, r *http.Request) {
	account, err := canonicalAccount(r.PathValue("account"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if s.push == nil {
		writeJSON(w, http.StatusOK, wakeResponse{Enabled: false})
		return
	}

	tokens, err := s.listPushTokens(r.Context(), account, maxWakeTokens)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), wakeTimeout)
	defer cancel()

	resp := wakeResponse{Enabled: true}
	for _, token := range tokens {
		err := s.push.PushSilent(ctx, account, token)
		switch {
		case err == nil:
			resp.Sent++
		case errors.Is(err, push.ErrBadToken), errors.Is(err, push.ErrUnregistered):
			removed, derr := s.deletePushToken(ctx, account, token)
			if derr != nil || !removed {
				resp.Failed++
				continue
			}
			resp.Removed++
		default:
			resp.Failed++
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

func decodePushTokenRequest(r *http.Request) (pushTokenRequest, error) {
	raw, err := readLimited(r.Body, maxPushTokenBytes)
	if err != nil {
		return pushTokenRequest{}, err
	}
	var req pushTokenRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		return pushTokenRequest{}, errors.New("推送令牌请求 JSON 非法")
	}
	req.Token = strings.TrimSpace(req.Token)
	if !pushTokenPattern.MatchString(req.Token) {
		return pushTokenRequest{}, errors.New("推送令牌格式非法")
	}
	return req, nil
}

func normalizePushEnv(raw string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "production":
		return "production", nil
	case "sandbox":
		return "sandbox", nil
	default:
		return "", errors.New("推送环境只支持 production 或 sandbox")
	}
}

// upsertPushToken 登记令牌并裁剪超限的历史令牌，返回账号当前令牌数。
func (s *Server) upsertPushToken(ctx context.Context, account, token, env string) (int, error) {
	now := s.now().UnixMilli()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("开始推送令牌事务: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO push_tokens (account, token, env, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(account, token) DO UPDATE SET
			env = excluded.env,
			updated_at = excluded.updated_at`,
		account, token, env, now, now); err != nil {
		return 0, fmt.Errorf("写入推送令牌: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM push_tokens
		WHERE account = ? AND token NOT IN (
			SELECT token FROM push_tokens
			WHERE account = ?
			ORDER BY updated_at DESC, rowid DESC
			LIMIT ?
		)`, account, account, maxPushTokensPerAccount); err != nil {
		return 0, fmt.Errorf("裁剪推送令牌: %w", err)
	}

	var total int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM push_tokens WHERE account = ?`, account).Scan(&total); err != nil {
		return 0, fmt.Errorf("统计推送令牌: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("提交推送令牌事务: %w", err)
	}
	return total, nil
}

// deletePushToken 删除令牌，返回是否确实删除了一条记录。
func (s *Server) deletePushToken(ctx context.Context, account, token string) (bool, error) {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM push_tokens WHERE account = ? AND token = ?`, account, token)
	if err != nil {
		return false, fmt.Errorf("删除推送令牌: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("统计推送令牌删除: %w", err)
	}
	return n > 0, nil
}

// listPushTokens 按最近登记顺序返回账号的推送令牌。
func (s *Server) listPushTokens(ctx context.Context, account string, limit int) ([]string, error) {
	if limit <= 0 {
		limit = maxWakeTokens
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT token FROM push_tokens
		WHERE account = ?
		ORDER BY updated_at DESC, rowid DESC
		LIMIT ?`, account, limit)
	if err != nil {
		return nil, fmt.Errorf("查询推送令牌: %w", err)
	}
	defer rows.Close()

	out := make([]string, 0, limit)
	for rows.Next() {
		var token string
		if err := rows.Scan(&token); err != nil {
			return nil, fmt.Errorf("扫描推送令牌: %w", err)
		}
		out = append(out, token)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历推送令牌: %w", err)
	}
	return out, nil
}

// countPushTokens 返回账号登记的令牌数，供冒烟与观测使用。
func (s *Server) countPushTokens(ctx context.Context, account string) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM push_tokens WHERE account = ?`, account).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("统计推送令牌: %w", err)
	}
	return n, nil
}
