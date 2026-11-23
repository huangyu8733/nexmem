package diag

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"

	"github.com/nexmem/core/gateway"
)

// Bind 把诊断能力接入网关的 diag.* 方法。
//
// diag.export 导出脱敏诊断日志（字段按字段名脱敏，不含正文与密钥）；
// diag.snapshot 返回 DHT 耗时、打洞结果与 S3 状态码等运行指标，
// 供设置页「网络诊断」展示。
func Bind(g *gateway.Gateway, rec *Recorder) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	if rec == nil {
		return errors.New("缺少诊断采集器")
	}
	handlers := map[string]gateway.HandlerFunc{
		"diag.export":   exportHandler(rec),
		"diag.snapshot": snapshotHandler(rec),
	}
	for method, h := range handlers {
		if err := g.SetHandler(method, h); err != nil {
			return err
		}
	}
	return nil
}

func exportHandler(rec *Recorder) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "diag.export 参数不是合法 JSON: %v", err)
		}
		path := strings.TrimSpace(req.Path)
		if path == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "diag.export 缺少 path")
		}
		if !isFilePath(path) {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "diag.export 的 path 必须指向文件")
		}
		logger := rec.Logger()
		if logger == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "诊断日志器未初始化")
		}
		if _, err := logger.ExportFile(path); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "导出诊断日志失败: %v", err)
		}
		return map[string]any{"path": path}, nil
	}
}

func snapshotHandler(rec *Recorder) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		snap := rec.Snapshot()
		return map[string]any{
			"uptime_ms":   snap.UptimeMS,
			"dht_lookups": snap.DHTLookups,
			"dht_errors":  snap.DHTErrors,
			"dht_p50_ms":  snap.DHTP50MS,
			"dht_p95_ms":  snap.DHTP95MS,
			"holepunch":   snap.HolePunch,
			"s3_status":   snap.S3Status,
			"log_records": snap.LogRecords,
			"log_dropped": snap.LogDropped,

			// P3 门禁：桶用量与票据消耗可观测。
			"offline_uploads":         snap.OfflineUploads,
			"offline_upload_bytes":    snap.OfflineUploadBytes,
			"offline_upload_failures": snap.OfflineFailures,
			"tickets_taken":           snap.TicketsTaken,
		}, nil
	}
}

// isFilePath 判断导出路径是否指向文件而非目录。
func isFilePath(path string) bool {
	if strings.HasSuffix(path, string(filepath.Separator)) ||
		strings.HasSuffix(path, "/") || strings.HasSuffix(path, "\\") {
		return false
	}
	clean := filepath.Clean(path)
	return clean != "." && clean != string(filepath.Separator)
}
