package coreapp

// 三种发现源的本机设置：mDNS 开关、公共 DHT 开关、手动地址列表。
// 与中继设置一致：设置页写 KV，`core.start` 时在显式入参缺失的情况下生效。
// 显式 config 入参始终优先。

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/discovery"
	"github.com/nexmem/core/internal/store"
)

const (
	mdnsEnabledSettingKey      = "net.mdns_enabled"
	publicDHTEnabledSettingKey = "net.public_dht_enabled"
	manualAddrsSettingKey      = "net.manual_addrs"
)

// applyStoredDiscovery 在显式入参未提供时，从设置页 KV 补齐发现源配置。
func (a *App) applyStoredDiscovery(ctx context.Context, dao *store.DAO, cfg *Config) {
	if dao == nil {
		return
	}
	if !cfg.EnableMDNS {
		if raw, err := dao.GetKV(ctx, mdnsEnabledSettingKey); err == nil && strings.TrimSpace(string(raw)) == "true" {
			cfg.EnableMDNS = true
		}
	}
	if !cfg.PublicDHT {
		if raw, err := dao.GetKV(ctx, publicDHTEnabledSettingKey); err == nil && strings.TrimSpace(string(raw)) == "true" {
			cfg.PublicDHT = true
		}
	}
	if len(cfg.ManualAddrs) == 0 {
		if raw, err := dao.GetKV(ctx, manualAddrsSettingKey); err == nil {
			addrs := splitRelayAddrs(string(raw)) // 复用换行/逗号拆分
			if len(addrs) > 0 {
				cfg.ManualAddrs = addrs
			}
		}
	}
}

// peerbookListHandler 返回本地地址簿全部记录。
func (a *App) peerbookListHandler() gateway.HandlerFunc {
	return func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
		a.mu.RLock()
		book := a.book
		a.mu.RUnlock()
		if book == nil {
			return map[string]any{"items": []any{}}, nil
		}
		items := make([]map[string]any, 0)
		for _, e := range book.List() {
			items = append(items, map[string]any{
				"account_id": e.AccountID,
				"peer_id":    e.PeerID,
				"addrs":      e.Addrs,
				"label":      e.Label,
				"updated_at": e.UpdatedAt,
			})
		}
		return map[string]any{"items": items}, nil
	}
}

// peerbookAddHandler 写入一条账号地址记录：account_id + peer_id + addrs。
func (a *App) peerbookAddHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			AccountID string   `json:"account_id"`
			PeerID    string   `json:"peer_id"`
			Addrs     []string `json:"addrs"`
			Label     string   `json:"label"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "net.addPeer 参数不是合法 JSON: %v", err)
		}
		a.mu.RLock()
		book, dao := a.book, a.dao
		a.mu.RUnlock()
		if book == nil || dao == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		if err := book.Put(ctx, req.AccountID, req.PeerID, req.Addrs, req.Label); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "写入地址簿失败: %v", err)
		}
		return map[string]any{"ok": true}, nil
	}
}

// peerbookRemoveHandler 删除一条地址簿记录。
func (a *App) peerbookRemoveHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			AccountID string `json:"account_id"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "net.removePeer 参数不是合法 JSON: %v", err)
		}
		a.mu.RLock()
		book, dao := a.book, a.dao
		a.mu.RUnlock()
		if book == nil || dao == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		if err := book.Remove(ctx, req.AccountID); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "删除地址簿记录失败: %v", err)
		}
		return map[string]any{"ok": true}, nil
	}
}

// connectAddrHandler 主动连接一个手动输入的 multiaddr（立即建连，不写入地址簿）。
func (a *App) connectAddrHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Addr string `json:"addr"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "net.connectAddr 参数不是合法 JSON: %v", err)
		}
		a.mu.RLock()
		h := a.host
		a.mu.RUnlock()
		if h == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		info, err := discovery.ConnectManual(ctx, h, req.Addr)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "连接失败: %v", err)
		}
		return map[string]any{"peer_id": info.ID.String()}, nil
	}
}
