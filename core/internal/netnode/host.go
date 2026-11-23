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
	PrivateKey       crypto.PrivKey
	Listen           []string
	Announce         []string
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
