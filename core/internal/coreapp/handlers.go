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
		// 客户端未显式配置时发现源默认开启；显式 false 仍可关闭。
		req.Config.applyDiscoveryDefaults = true
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

// dataDirHandler 实现 core.dataDir：返回当前内核数据目录，供客户端在
// 多账号切换（core.stop + core.start 指定 data_dir）后恢复到原账号。
func (a *App) dataDirHandler() gateway.HandlerFunc {
	return func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
		a.mu.RLock()
		dir := a.cfg.DataDir
		started := a.started
		a.mu.RUnlock()
		if !started {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		return map[string]any{"data_dir": dir}, nil
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
