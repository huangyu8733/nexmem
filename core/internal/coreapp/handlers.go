package coreapp

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/nexmem/core/gateway"
)

// startHandler 实现 core.start：解析启动配置并幂等启动内核。
func (a *App) startHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Config Config `json:"config"`
		}
		if len(params) > 0 {
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "core.start 参数不是合法 JSON: %v", err)
			}
		}
		state, err := a.Start(ctx, req.Config)
		if err != nil {
			if errors.Is(err, ErrDataDirRequired) {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "%v", err)
			}
			return nil, gateway.NewError(gateway.CodeNotStarted, "启动内核失败: %v", err)
		}
		return map[string]any{"state": state}, nil
	}
}

// stopHandler 实现 core.stop。
func (a *App) stopHandler() gateway.HandlerFunc {
	return func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
		if err := a.Stop(); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "停止内核失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

// accountHandler 实现 account.me：返回当前账号与设备信息。
func (a *App) accountHandler() gateway.HandlerFunc {
	return func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
		a.mu.RLock()
		acc := a.account
		cfg := a.cfg
		h := a.host
		a.mu.RUnlock()
		if acc == nil || h == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		return map[string]any{
			"account_id":   acc.ID(),
			"device_id":    h.ID().String(),
			"display_name": cfg.DisplayName,
		}, nil
	}
}
