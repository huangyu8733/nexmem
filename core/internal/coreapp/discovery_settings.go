package coreapp

// 三种发现源的本机设置：mDNS 开关、公共 DHT 开关、手动地址列表。
// mDNS 与公共 DHT 默认开启；设置页写 KV，`core.start` 显式入参优先。
// 手动地址簿始终参与解析，无需开关。

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

// boolSetting 把设置页 KV 转为开关值；缺失或非法值回落到 defaultValue。
func boolSetting(raw string, defaultValue bool) bool {
	switch strings.TrimSpace(raw) {
	case "true":
		return true
	case "false":
		return false
	default:
		return defaultValue
	}
}

// applyStoredDiscovery 在显式入参未提供时套用默认开启策略与设置页 KV。
func (a *App) applyStoredDiscovery(ctx context.Context, dao *store.DAO, cfg *Config) {
	read := func(key string) string {
		if dao == nil {
			return ""
		}
		raw, err := dao.GetKV(ctx, key)
		if err != nil {
			return ""
		}
		return string(raw)
	}
	if cfg.EnableMDNS == nil {
		enabled := boolSetting(read(mdnsEnabledSettingKey), true)
		cfg.EnableMDNS = &enabled
	}
	if cfg.PublicDHT == nil {
		enabled := boolSetting(read(publicDHTEnabledSettingKey), true)
		cfg.PublicDHT = &enabled
	}
	if len(cfg.ManualAddrs) == 0 {
		addrs := splitRelayAddrs(read(manualAddrsSettingKey)) // 复用换行/逗号拆分
		if len(addrs) > 0 {
			cfg.ManualAddrs = addrs
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
