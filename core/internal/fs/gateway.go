package fs

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/nexmem/core/gateway"
)

// Gateway 把文件夹共享能力接入 RPC。Service 以提供者形式注入，
// 使 core.start 前后切换实现时统一返回 NOT_STARTED。
type Gateway struct {
	Service func() *Service
}

// BindProvider 以服务提供者形式注册 fs.* 方法，供 coreapp 在启动前后切换实现。
func BindProvider(g *gateway.Gateway, service func() *Service) error {
	return Bind(g, &Gateway{Service: service})
}

// Bind 注册 fs.* 方法。
func Bind(g *gateway.Gateway, gw *Gateway) error {
	if g == nil || gw == nil || gw.Service == nil {
		return errors.New("缺少文件共享服务")
	}
	handlers := map[string]gateway.HandlerFunc{
		"fs.publish":  gw.publishHandler(),
		"fs.list":     gw.listHandler(),
		"fs.get":      gw.getHandler(),
		"fs.import":   gw.importHandler(),
		"fs.send":     gw.sendHandler(),
		"fs.remove":   gw.removeHandler(),
		"fs.download": gw.downloadHandler(),
	}
	for method, h := range handlers {
		if err := g.SetHandler(method, h); err != nil {
			return err
		}
	}
	return nil
}

func (gw *Gateway) service() (*Service, *gateway.Error) {
	svc := gw.Service()
	if svc == nil {
		return nil, gateway.NewError(gateway.CodeNotStarted, "文件共享服务尚未接入内核")
	}
	return svc, nil
}

func decodeParams(params json.RawMessage, out any) *gateway.Error {
	if err := json.Unmarshal(params, out); err != nil {
		return gateway.NewError(gateway.CodeInvalidArg, "参数不是合法 JSON: %v", err)
	}
	return nil
}

func (gw *Gateway) publishHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		var req struct {
			Path string `json:"path"`
			Name string `json:"name"`
		}
		if gerr := decodeParams(params, &req); gerr != nil {
			return nil, gerr
		}
		req.Path = strings.TrimSpace(req.Path)
		if req.Path == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 path")
		}
		rec, code, err := svc.Publish(ctx, req.Path, req.Name)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "发布共享失败: %v", err)
		}
		return shareResult(svc, rec, code), nil
	}
}

func (gw *Gateway) listHandler() gateway.HandlerFunc {
	return func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		recs := svc.List()
		items := make([]map[string]any, 0, len(recs))
		for _, rec := range recs {
			m := rec.Manifest
			items = append(items, map[string]any{
				"share_id":   m.ID,
				"name":       m.Name,
				"kind":       rec.Kind,
				"file_count": len(m.Files),
				"total_size": m.TotalSize,
				"created_at": rec.CreatedAt,
				"local":      rec.LocalRoot != "",
			})
		}
		return map[string]any{"items": items}, nil
	}
}

func (gw *Gateway) getHandler() gateway.HandlerFunc {
	return func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		var req struct {
			ShareID string `json:"share_id"`
		}
		if gerr := decodeParams(params, &req); gerr != nil {
			return nil, gerr
		}
		if req.ShareID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 share_id")
		}
		rec, code, err := svc.Get(req.ShareID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%v", err)
		}
		result := shareResult(svc, rec, code)
		files := make([]map[string]any, 0, len(rec.Manifest.Files))
		for _, f := range rec.Manifest.Files {
			files = append(files, map[string]any{
				"path": f.Path, "size": f.Size, "sha256": f.SHA256, "mime": f.MIME,
			})
		}
		result["files"] = files
		result["owner"] = rec.Manifest.Owner
		return result, nil
	}
}

func (gw *Gateway) importHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		var req struct {
			Code string `json:"code"`
		}
		if gerr := decodeParams(params, &req); gerr != nil {
			return nil, gerr
		}
		req.Code = strings.TrimSpace(req.Code)
		if req.Code == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 code")
		}
		rec, err := svc.Import(ctx, req.Code)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "导入分享码失败: %v", err)
		}
		_, code, _ := svc.Get(rec.Manifest.ID)
		return shareResult(svc, rec, code), nil
	}
}

func (gw *Gateway) sendHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		var req struct {
			ShareID string `json:"share_id"`
			Peer    string `json:"peer"`
		}
		if gerr := decodeParams(params, &req); gerr != nil {
			return nil, gerr
		}
		if req.ShareID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 share_id")
		}
		if strings.TrimSpace(req.Peer) == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 peer")
		}
		msgUUID, err := svc.Share(ctx, req.ShareID, strings.TrimSpace(req.Peer))
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "发送共享失败: %v", err)
		}
		return map[string]any{"msg_uuid": msgUUID}, nil
	}
}

func (gw *Gateway) removeHandler() gateway.HandlerFunc {
	return func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		var req struct {
			ShareID string `json:"share_id"`
		}
		if gerr := decodeParams(params, &req); gerr != nil {
			return nil, gerr
		}
		if req.ShareID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 share_id")
		}
		if err := svc.Remove(req.ShareID); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%v", err)
		}
		return map[string]any{}, nil
	}
}

func (gw *Gateway) downloadHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		var req struct {
			ShareID  string `json:"share_id"`
			Dest     string `json:"dest"`
			Parallel int    `json:"parallel"`
		}
		if gerr := decodeParams(params, &req); gerr != nil {
			return nil, gerr
		}
		if req.ShareID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 share_id")
		}
		if strings.TrimSpace(req.Dest) == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 dest")
		}
		if req.Parallel < 0 || req.Parallel > maxParallel {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "parallel 需要在 1-%d 之间", maxParallel)
		}
		rec, err := svc.Download(ctx, req.ShareID, req.Dest, nil, req.Parallel)
		if err != nil {
			code := gateway.CodeInvalidArg
			if errors.Is(err, ErrNoSeeds) || errors.Is(err, ErrSeedUnavailable) {
				code = gateway.CodePeerUnreachable
			}
			return nil, gateway.NewError(code, "下载共享失败: %v", err)
		}
		return map[string]any{
			"share_id": rec.Manifest.ID,
			"dest":     rec.LocalRoot,
			"kind":     rec.Kind,
		}, nil
	}
}

func shareResult(svc *Service, rec *ShareRecord, code string) map[string]any {
	seeds := rec.Seeds
	if len(seeds) == 0 && rec.LocalRoot != "" {
		seeds = svc.localSeeds()
	}
	return map[string]any{
		"share_id":   rec.Manifest.ID,
		"name":       rec.Manifest.Name,
		"code":       code,
		"kind":       rec.Kind,
		"file_count": len(rec.Manifest.Files),
		"total_size": rec.Manifest.TotalSize,
		"local":      rec.LocalRoot != "",
		"seeds":      seeds,
	}
}
