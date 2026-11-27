package netnode

import (
	"context"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/p2p/net/connmgr"
	"github.com/multiformats/go-multiaddr"
)

// Config 是 P0 阶段 host 的最小配置集合。
type Config struct {
	PrivateKey crypto.PrivKey
	Listen     []string
	Announce   []string
	// LanAddrs 是宿主注入的本机局域网 IP（如 192.168.1.5）。Android 上 Go 的
	// net.Interfaces() 常被 SELinux 拦截，libp2p 无法把 /ip4/0.0.0.0 展开为
	// 局域网地址，导致 mDNS 无地址可广播。注入后用于改写宣告地址。
	LanAddrs         []string
	UserAgent        string
	EnableNATService bool
	EnableHolePunch  bool
	// Relay 是中继客户端与 AutoRelay 策略，零值表示关闭（项目默认）。
	Relay RelayPolicy
	// RelayService 是中继服务开关与限额，零值表示关闭（项目默认）。
	RelayService RelayServicePolicy
	// ForcePublic 让节点强制宣告为公网可达。中继节点必须置为 true，
	// 因为 libp2p 只在 ReachabilityPublic 时才真正启动 Relay 服务。
	ForcePublic bool
	ConnLow     int
	ConnHigh    int
}

// NewHost 创建具备 Noise 加密、QUIC/TCP 传输与打洞能力的 libp2p host。
func NewHost(ctx context.Context, cfg Config) (host.Host, error) {
	opts := []libp2p.Option{
		libp2p.Identity(cfg.PrivateKey),
		libp2p.ListenAddrStrings(cfg.Listen...),
		libp2p.UserAgent(cfg.UserAgent),
		libp2p.NATPortMap(),
	}

	if cfg.EnableNATService {
		opts = append(opts, libp2p.EnableNATService())
	}
	if cfg.EnableHolePunch {
		opts = append(opts, libp2p.EnableHolePunching())
	}
	opts = append(opts, cfg.Relay.hostOptions()...)
	if cfg.RelayService.Enabled {
		opts = append(opts, libp2p.EnableRelayService(cfg.RelayService.options()...))
	}
	if cfg.ForcePublic {
		opts = append(opts, libp2p.ForceReachabilityPublic())
	}
	if len(cfg.Announce) > 0 {
		announced := make([]multiaddr.Multiaddr, 0, len(cfg.Announce))
		for _, s := range cfg.Announce {
			ma, err := multiaddr.NewMultiaddr(s)
			if err != nil {
				return nil, err
			}
			announced = append(announced, ma)
		}
		opts = append(opts, libp2p.AddrsFactory(func([]multiaddr.Multiaddr) []multiaddr.Multiaddr {
			return announced
		}))
	} else if len(cfg.LanAddrs) > 0 {
		// 把 libp2p 的 0.0.0.0 通配地址展开为宿主注入的局域网 IP。
		// 不改其他地址（公网/loopback/中继），仅补全缺失的局域网地址。
		opts = append(opts, libp2p.AddrsFactory(func(addrs []multiaddr.Multiaddr) []multiaddr.Multiaddr {
			return expandUnspecifiedWithLan(addrs, cfg.LanAddrs)
		}))
	}
	if cfg.ConnLow > 0 && cfg.ConnHigh >= cfg.ConnLow {
		cm, err := connmgr.NewConnManager(cfg.ConnLow, cfg.ConnHigh, connmgr.WithGracePeriod(time.Minute))
		if err != nil {
			return nil, err
		}
		opts = append(opts, libp2p.ConnectionManager(cm))
	}

	// ctx 仅用于建 host 阶段；libp2p 会自行管理后台生命周期。
	_ = ctx
	return libp2p.New(opts...)
}

// expandUnspecifiedWithLan 把 libp2p 的 /ip4/0.0.0.0 通配监听地址展开为宿主
// 注入的局域网 IP。Android 上 net.Interfaces() 被 SELinux 拦截时，libp2p 无法
// 自行展开，mDNS 没有可广播地址；这里用原生层拿到的 IP 补全。
//
// 只处理 0.0.0.0 地址，保留其余地址（含公网、loopback、p2p-circuit），
// 并对注入 IP 生成的地址去重，避免与 libp2p 已展开的地址重复。
func expandUnspecifiedWithLan(addrs []multiaddr.Multiaddr, lanIPs []string) []multiaddr.Multiaddr {
	out := make([]multiaddr.Multiaddr, 0, len(addrs)+len(lanIPs))
	seen := make(map[string]struct{}, len(addrs)+len(lanIPs))
	add := func(a multiaddr.Multiaddr) {
		if a == nil {
			return
		}
		s := a.String()
		if _, ok := seen[s]; ok {
			return
		}
		seen[s] = struct{}{}
		out = append(out, a)
	}
	const anyIPv4 = "/ip4/0.0.0.0"
	for _, a := range addrs {
		if a == nil {
			add(a)
			continue
		}
		first, rest := multiaddr.SplitFirst(a)
		if first == nil || first.String() != anyIPv4 {
			add(a)
			continue
		}
		// 地址以 /ip4/0.0.0.0 开头：为每个注入 IP 生成一份替换地址。
		for _, ip := range lanIPs {
			replacement, err := multiaddr.NewMultiaddr("/ip4/" + ip + rest.String())
			if err == nil {
				add(replacement)
			}
		}
		// 保留原始 0.0.0.0 地址本身，避免丢失端口信息。
		add(a)
	}
	return out
}
