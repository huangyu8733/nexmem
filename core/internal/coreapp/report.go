package coreapp

// 举报上报（P6-06）。
//
// 旧版 UI 的举报入口只有本地导出，没有后端出口；这里把「原因 + 补充说明 +
// 脱敏诊断包」提交给索引服务留档。诊断包复用 diag.export 的产物，
// 内核只读取调用方显式给出的文件，不主动采集任何其他数据。

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/directory"
)

const (
	// maxReportDetailRunes 与索引服务的补充说明上限一致。
	maxReportDetailRunes = 2000
	// maxReportDiagnostics 是诊断包上传上限，与服务端保持一致。
	maxReportDiagnostics = 256 << 10
)

var reportReasons = map[string]struct{}{
	"harassment": {},
	"spam":       {},
	"fraud":      {},
	"porn":       {},
	"other":      {},
}

type reportParams struct {
	Reason          string `json:"reason"`
	ConversationID  string `json:"conversation_id"`
	Detail          string `json:"detail"`
	DiagnosticsPath string `json:"diagnostics_path"`
	ClientVersion   string `json:"client_version"`
}

// reportHandler 处理 report.submit：校验参数后转交索引服务。
func (a *App) reportHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		if !a.isStarted() {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核未启动")
		}
		var in reportParams
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "举报参数 JSON 非法")
		}
		in.Reason = strings.TrimSpace(in.Reason)
		if _, ok := reportReasons[in.Reason]; !ok {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "举报原因 %q 不支持", in.Reason)
		}
		in.Detail = strings.TrimSpace(in.Detail)
		if utf8.RuneCountInString(in.Detail) > maxReportDetailRunes {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "补充说明超过 %d 字", maxReportDetailRunes)
		}
		diagnostics, err := readDiagnostics(in.DiagnosticsPath)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", err.Error())
		}

		a.mu.RLock()
		client := a.dir
		a.mu.RUnlock()
		if client == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "未配置索引服务，举报无法上报")
		}

		res, err := client.SubmitReport(ctx, directory.ReportRequest{
			Reason:         in.Reason,
			ConversationID: strings.TrimSpace(in.ConversationID),
			Detail:         in.Detail,
			Diagnostics:    diagnostics,
			ClientVersion:  strings.TrimSpace(in.ClientVersion),
		})
		if err != nil {
			switch {
			case errors.Is(err, directory.ErrRateLimited):
				return nil, gateway.NewError(gateway.CodeRateLimited, "举报提交过于频繁，稍后重试")
			case errors.Is(err, directory.ErrReportRejected):
				return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", err.Error())
			default:
				return nil, gateway.NewError(gateway.CodeNotOnline, "索引服务不可达: %s", err.Error())
			}
		}
		a.log.Info("report", "举报已上报", map[string]any{
			"report_id":        res.ID,
			"reason":           in.Reason,
			"conversation_id":  strings.TrimSpace(in.ConversationID),
			"diagnostics_size": len(diagnostics),
		})
		return map[string]any{
			"report_id":  res.ID,
			"created_at": res.CreatedAt,
		}, nil
	}
}

// readDiagnostics 读取调用方显式给出的诊断包；未提供路径时返回 nil。
//
// 只接受绝对路径与普通文件，并限制体积，避免把误传的大文件当诊断包上传。
func readDiagnostics(path string) ([]byte, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, nil
	}
	clean := filepath.Clean(path)
	if !filepath.IsAbs(clean) {
		return nil, errors.New("诊断包路径必须是绝对路径")
	}
	info, err := os.Stat(clean)
	if err != nil {
		return nil, errors.New("诊断包不存在或不可读")
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("诊断包必须是普通文件")
	}
	if info.Size() > maxReportDiagnostics {
		return nil, errors.New("诊断包超过 256 KiB")
	}
	f, err := os.Open(clean)
	if err != nil {
		return nil, errors.New("诊断包不可读")
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, maxReportDiagnostics+1))
	if err != nil {
		return nil, errors.New("读取诊断包失败")
	}
	if len(raw) > maxReportDiagnostics {
		return nil, errors.New("诊断包超过 256 KiB")
	}
	return raw, nil
}
