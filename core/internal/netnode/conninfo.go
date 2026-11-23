package netnode

import (
	"fmt"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
)

// ConnInfo 描述与某个 peer 当前连接的性质，用于判定「直连 / 中继」。
type ConnInfo struct {
	Connected bool
	Direct    bool
	Relayed   bool
	Transport string
	Addrs     []string
}

// InspectPeer 检查 host 到目标 peer 的所有连接。
// 只要存在一条非 Limited 且不含 p2p-circuit 的连接，就视为直连。
func InspectPeer(h host.Host, p peer.ID) ConnInfo {
	var info ConnInfo
	conns := h.Network().ConnsToPeer(p)
	info.Connected = len(conns) > 0

	for _, c := range conns {
		ma := c.RemoteMultiaddr()
		info.Addrs = append(info.Addrs, ma.String())

		circuit := hasProtocolName(ma, "p2p-circuit")
		limited := c.Stat().Limited
		if circuit || limited {
			info.Relayed = true
			continue
		}
		info.Direct = true
		if t := transportOf(ma); t != "" {
			info.Transport = t
		}
	}
	return info
}

func hasProtocolName(ma multiaddr.Multiaddr, name string) bool {
	for _, p := range ma.Protocols() {
		if p.Name == name {
			return true
		}
	}
	return false
}

func transportOf(ma multiaddr.Multiaddr) string {
	for _, p := range ma.Protocols() {
		switch p.Code {
		case multiaddr.P_QUIC, multiaddr.P_QUIC_V1:
			return "quic"
		case multiaddr.P_TCP:
			return "tcp"
		}
	}
	return ""
}

// CircuitAddr 由中继地址与目标 PeerID 构造 p2p-circuit 地址，用于强制走中继。
func CircuitAddr(relay peer.AddrInfo, target peer.ID) (peer.AddrInfo, error) {
	if len(relay.Addrs) == 0 {
		return peer.AddrInfo{}, fmt.Errorf("中继节点没有可用地址")
	}
	raw := fmt.Sprintf("%s/p2p/%s/p2p-circuit/p2p/%s", relay.Addrs[0], relay.ID, target)
	ma, err := multiaddr.NewMultiaddr(raw)
	if err != nil {
		return peer.AddrInfo{}, fmt.Errorf("构造中继地址 %s: %w", raw, err)
	}
	ai, err := peer.AddrInfoFromP2pAddr(ma)
	if err != nil {
		return peer.AddrInfo{}, err
	}
	return *ai, nil
}
