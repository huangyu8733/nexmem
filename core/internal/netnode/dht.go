package netnode

import (
	"context"
	"fmt"

	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
)

// DHTProtocol 是 Nexmem 私有 DHT 的协议前缀，避免污染公网 IPFS DHT。
const DHTProtocol protocol.ID = "/nexmem"

// NewDHT 创建私有 Kademlia DHT。bootstrap 节点用 ModeServer，
// 普通客户端用 ModeAuto（可被外部拨号，但会根据 AutoNAT 结果自适应）。
func NewDHT(ctx context.Context, h host.Host, mode dht.ModeOpt, bootstraps []peer.AddrInfo) (*dht.IpfsDHT, error) {
	return newDHT(ctx, h, mode, DHTProtocol, bootstraps)
}

// NewPublicDHT 创建接入公共 IPFS 网络的 DHT（标准 /ipfs 前缀）。
// 它只用于在没有自建 bootstrap 时解析对端地址，不承载任何 Nexmem 业务数据。
func NewPublicDHT(ctx context.Context, h host.Host, bootstraps []peer.AddrInfo) (*dht.IpfsDHT, error) {
	return newDHT(ctx, h, dht.ModeClient, dht.DefaultPrefix, bootstraps)
}

func newDHT(ctx context.Context, h host.Host, mode dht.ModeOpt, prefix protocol.ID, bootstraps []peer.AddrInfo) (*dht.IpfsDHT, error) {
	d, err := dht.New(h,
		dht.Mode(mode),
		dht.ProtocolPrefix(prefix),
		dht.BootstrapPeers(bootstraps...),
	)
	if err != nil {
		return nil, fmt.Errorf("创建 DHT: %w", err)
	}
	if err := d.Bootstrap(ctx); err != nil {
		return nil, fmt.Errorf("DHT bootstrap: %w", err)
	}
	return d, nil
}
