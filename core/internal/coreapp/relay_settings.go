package coreapp

// 网络设置：中继开关与中继地址（P6-20）。
//
// 需求要求 Circuit Relay 可配置且默认关闭，仅在桌面端或用户自愿开启时生效。
// libp2p 的中继客户端能力在主机创建时装配，无法运行期热插拔，因此这里沿用
// 设置页（P6-15）的 `kv` 落盘：界面写入 `net.relay_enabled` 与
// `net.relay_addrs`，下次 `core.start` 时在显式入参缺失的情况下生效。

import (
	"context"
	"strings"

	"github.com/libp2p/go-libp2p/core/peer"

	"github.com/nexmem/core/internal/store"
)

const (
	// relayEnabledSettingKey 是中继开关设置键，值为 "true" 时开启。
	relayEnabledSettingKey = "net.relay_enabled"
	// relayAddrsSettingKey 是中继地址设置键，多行/逗号分隔的 multiaddr。
	relayAddrsSettingKey = "net.relay_addrs"
)

// applyStoredRelay 在显式未提供中继地址时读取设置页保存的中继配置。
// 读取失败、开关关闭或没有合法地址时保持默认关闭，不影响内核启动。
func (a *App) applyStoredRelay(ctx context.Context, dao *store.DAO, cfg *Config) {
	if dao == nil || len(cfg.RelayAddrs) > 0 {
		return
	}
	raw, err := dao.GetKV(ctx, relayEnabledSettingKey)
	if err != nil || strings.TrimSpace(string(raw)) != "true" {
		return
	}
	rawAddrs, err := dao.GetKV(ctx, relayAddrsSettingKey)
	if err != nil {
		return
	}
	addrs := splitRelayAddrs(string(rawAddrs))
	if len(addrs) == 0 {
		a.warnNetwork("中继开关已开启但没有中继地址，保持关闭", nil)
		return
	}
	valid := make([]string, 0, len(addrs))
	for _, addr := range addrs {
		if _, perr := peer.AddrInfoFromString(addr); perr != nil {
			a.warnNetwork("忽略非法的中继地址", map[string]any{"addr": addr})
			continue
		}
		valid = append(valid, addr)
	}
	if len(valid) == 0 {
		a.warnNetwork("中继地址全部非法，保持关闭", map[string]any{"count": len(addrs)})
		return
	}
	cfg.RelayAddrs = valid
	if a.log != nil {
		a.log.Info("network", "按本机设置启用中继", map[string]any{"relays": len(valid)})
	}
}

// splitRelayAddrs 按换行 / 逗号拆分中继地址，去掉首尾空白与重复项。
func splitRelayAddrs(raw string) []string {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == '\n' || r == '\r' || r == ','
	})
	out := make([]string, 0, len(fields))
	seen := make(map[string]struct{}, len(fields))
	for _, field := range fields {
		addr := strings.TrimSpace(field)
		if addr == "" {
			continue
		}
		if _, dup := seen[addr]; dup {
			continue
		}
		seen[addr] = struct{}{}
		out = append(out, addr)
	}
	return out
}

// warnNetwork 写一条网络设置相关的告警；日志器缺失时静默。
func (a *App) warnNetwork(msg string, fields map[string]any) {
	if a.log == nil {
		return
	}
	a.log.Warn("network", msg, fields)
}
