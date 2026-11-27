package coreapp

// 网络设置：中继开关与中继地址（P6-20）。
//
// Circuit Relay 可配置且默认开启，首次启动预填官方公共中继节点，开箱即用；
// 用户显式保存过（哪怕关闭或清空）则尊重用户选择。
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

// 官方公共中继节点（README「完整多地址」的主/备 relay）。用户从未保存过
// 中继配置时默认启用这两个地址，与 Dart 侧 defaultRelayAddrs 保持一致。
var defaultRelayAddrs = []string{
	"/ip4/103.119.14.14/tcp/14002/p2p/12D3KooWS3cnEVm6z4XQQB9nXs9WBb5sfaHnck5TRCAfxEKZQFKm",
	"/ip4/103.142.103.6/tcp/14002/p2p/12D3KooWCv4mouxCSAK6CXJ4B5gZbpjB2pdxVLu8DTz4jViLVvsJ",
}

// applyStoredRelay 在显式未提供中继地址时套用默认开启策略与设置页 KV。
//
// 语义与 Dart 侧 _loadStored 对齐：
//   - 显式入参 cfg.RelayAddrs 优先，不动；
//   - 两个 KV 键都读不到（用户从未配置）→ 默认开启 + 官方主/备中继；
//   - 用户保存过 → 严格按 saved enabled/addr，即使关闭或清空也不回落默认。
func (a *App) applyStoredRelay(ctx context.Context, dao *store.DAO, cfg *Config) {
	if len(cfg.RelayAddrs) > 0 {
		return
	}
	read := func(key string) (string, bool) {
		if dao == nil {
			return "", false
		}
		raw, err := dao.GetKV(ctx, key)
		if err != nil {
			return "", false
		}
		return string(raw), true
	}
	enabledRaw, enabledFound := read(relayEnabledSettingKey)
	addrsRaw, addrsFound := read(relayAddrsSettingKey)

	var addrs []string
	var fromDefault bool
	if !enabledFound && !addrsFound {
		// 从未配置：默认开启 + 官方地址。
		addrs = append([]string(nil), defaultRelayAddrs...)
		fromDefault = true
	} else {
		// 用户保存过：开关不为 "true" 即关闭，地址按保存值。
		if !boolSetting(enabledRaw, false) {
			return
		}
		addrs = splitRelayAddrs(addrsRaw)
		if len(addrs) == 0 {
			a.warnNetwork("中继开关已开启但没有中继地址，保持关闭", nil)
			return
		}
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
		source := "本机设置"
		if fromDefault {
			source = "官方默认"
		}
		a.log.Info("network", "启用中继", map[string]any{"relays": len(valid), "source": source})
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
