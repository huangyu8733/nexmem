package directory

// 举报上报（P6-06）。
//
// 客户端把举报原因、补充说明与可选脱敏诊断包交给索引服务留档；
// 服务端只保存账号公钥编码与调用方主动提交的文本，不保存聊天正文，
// 也不主动拉取任何本机数据。诊断包由客户端脱敏后自行上传。

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"unicode/utf8"
)

const (
	// maxReportBytes 是举报请求体（含诊断包 base64）的上限。
	maxReportBytes = 1 << 20
	// maxReportDiagnostics 是诊断包解码后的上限。
	maxReportDiagnostics = 256 << 10
	maxReportDetail      = 2000
	maxReportConversation = 256
)

// reportReasons 是允许上报的原因集合，与客户端 ReportReason 枚举一致。
var reportReasons = map[string]struct{}{
	"harassment": {},
	"spam":       {},
	"fraud":      {},
	"porn":       {},
	"other":      {},
}

type reportRequest struct {
	Reason         string `json:"reason"`
	ConversationID string `json:"conversation_id"`
	Detail         string `json:"detail"`
	// DiagnosticsB64 是脱敏诊断包的 base64 内容；为空表示未附带。
	DiagnosticsB64 string `json:"diagnostics_b64"`
	ClientVersion  string `json:"client_version"`
}

type reportResponse struct {
	ID        string `json:"id"`
	CreatedAt int64  `json:"created_at"`
}

// handleSubmitReport 保存当前账号（签名账号）提交的一条举报。
func (s *Server) handleSubmitReport(w http.ResponseWriter, r *http.Request) {
	account, ok := signerAccount(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "缺少签名账号")
		return
	}
	req, diagnostics, err := decodeReportRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	id, createdAt, err := s.addReport(r.Context(), account, req, diagnostics)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, reportResponse{ID: id, CreatedAt: createdAt})
}

func decodeReportRequest(r *http.Request) (reportRequest, []byte, error) {
	raw, err := readLimited(r.Body, maxReportBytes)
	if err != nil {
		return reportRequest{}, nil, err
	}
	var req reportRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		return reportRequest{}, nil, errors.New("举报请求 JSON 非法")
	}
	req.Reason = strings.TrimSpace(req.Reason)
	if _, ok := reportReasons[req.Reason]; !ok {
		return reportRequest{}, nil, fmt.Errorf("举报原因 %q 不支持", req.Reason)
	}
	req.Detail = strings.TrimSpace(req.Detail)
	if utf8.RuneCountInString(req.Detail) > maxReportDetail {
		return reportRequest{}, nil, fmt.Errorf("补充说明超过 %d 字", maxReportDetail)
	}
	req.ConversationID = strings.TrimSpace(req.ConversationID)
	if len(req.ConversationID) > maxReportConversation {
		return reportRequest{}, nil, fmt.Errorf("会话 ID 超过 %d 字节", maxReportConversation)
	}
	req.ClientVersion = strings.TrimSpace(req.ClientVersion)
	if len(req.ClientVersion) > 64 {
		return reportRequest{}, nil, errors.New("客户端版本过长")
	}

	var diagnostics []byte
	if req.DiagnosticsB64 != "" {
		diagnostics, err = base64.StdEncoding.DecodeString(req.DiagnosticsB64)
		if err != nil {
			return reportRequest{}, nil, errors.New("诊断包不是合法 base64")
		}
		if len(diagnostics) > maxReportDiagnostics {
			return reportRequest{}, nil, fmt.Errorf("诊断包超过 %d 字节", maxReportDiagnostics)
		}
	}
	return req, diagnostics, nil
}

// addReport 写入一条举报并返回其 ID 与服务端接收时间（毫秒）。
func (s *Server) addReport(ctx context.Context, account string, req reportRequest, diagnostics []byte) (string, int64, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", 0, fmt.Errorf("生成举报 ID: %w", err)
	}
	id := hex.EncodeToString(buf[:])
	createdAt := s.now().UnixMilli()

	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO reports
			(id, account, reason, conversation_id, detail, diagnostics, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, account, req.Reason, req.ConversationID, req.Detail, diagnostics, createdAt); err != nil {
		return "", 0, fmt.Errorf("写入举报: %w", err)
	}
	return id, createdAt, nil
}

// countReports 返回账号提交的举报数，供冒烟与观测使用。
func (s *Server) countReports(ctx context.Context, account string) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM reports WHERE account = ?`, account).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("统计举报: %w", err)
	}
	return n, nil
}
