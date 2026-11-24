package discovery

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/discovery/mdns"
	ma "github.com/multiformats/go-multiaddr"
)

// MDNSServiceName 是 Nexmem 局域网发现的 mDNS 服务名。
// 同网段内运行相同服务名的节点会互相发现。
const MDNSServiceName = "_nexmem._udp"

// mdnsNotifee 接收 mDNS 发现事件，把发现的 PeerID/地址存入本地缓存。
type mdnsNotifee struct {
	mu    sync.RWMutex
	addrs map[peer.ID]cachedAddr
	host  host.Host
}

type cachedAddr struct {
	addrs []ma.Multiaddr
	seen  time.Time
}

// HandlePeerFound 实现 mdns.Notifee。发现对端后记录地址并尝试自动连接，
// 这样同一 WiFi 下的电脑/手机无需任何服务器即可建立 P2P 链路。
func (n *mdnsNotifee) HandlePeerFound(info peer.AddrInfo) {
	if info.ID == "" || len(info.Addrs) == 0 || (n.host != nil && info.ID == n.host.ID()) {
		return
	}
	n.mu.Lock()
	n.addrs[info.ID] = cachedAddr{addrs: append([]ma.Multiaddr(nil), info.Addrs...), seen: time.Now()}
	n.mu.Unlock()

	if n.host != nil && n.host.Network().Connectedness(info.ID) != network.Connected {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = n.host.Connect(ctx, info)
	}
}

// addressesFor 返回某 PeerID 的未过期地址。
func (n *mdnsNotifee) addressesFor(id peer.ID) []ma.Multiaddr {
	n.mu.RLock()
	c, ok := n.addrs[id]
	n.mu.RUnlock()
	if !ok || time.Since(c.seen) > addrTTL {
		return nil
	}
	return append([]ma.Multiaddr(nil), c.addrs...)
}

// MDNS 是局域网发现源。它不直接知道账号，只维护 PeerID -> 地址，
// 供 CascadingResolver 在拿到账号对应的 PeerID 后补齐地址。
type MDNS struct {
	service mdns.Service
	notifee *mdnsNotifee
	host    host.Host
}

// StartMDNS 启动 mDNS 广播与发现。失败时返回错误，调用方可降级为其他源。
func StartMDNS(h host.Host) (*MDNS, error) {
	n := &mdnsNotifee{addrs: map[peer.ID]cachedAddr{}, host: h}
	svc := mdns.NewMdnsService(h, MDNSServiceName, n)
	if err := svc.Start(); err != nil {
		return nil, err
	}
	return &MDNS{service: svc, notifee: n, host: h}, nil
}

// Close 停止 mDNS 服务。
func (m *MDNS) Close() error {
	if m.service == nil {
		return nil
	}
	return m.service.Close()
}

// AddressesFor 返回 mDNS 发现的某 PeerID 的地址（未过期）。
func (m *MDNS) AddressesFor(id peer.ID) []ma.Multiaddr {
	if m == nil || m.notifee == nil {
		return nil
	}
	return m.notifee.addressesFor(id)
}

// ConnectManual 主动连接一个手动输入的 multiaddr（手动发现源的即时连接路径）。
// addr 必须包含 /p2p/<PeerID> 后缀。
func ConnectManual(ctx context.Context, h host.Host, raw string) (peer.AddrInfo, error) {
	raw = strings.TrimSpace(raw)
	info, err := peer.AddrInfoFromString(raw)
	if err != nil {
		return peer.AddrInfo{}, err
	}
	if len(info.Addrs) == 0 {
		return peer.AddrInfo{}, errNoAddress
	}
	if err := h.Connect(ctx, *info); err != nil {
		return peer.AddrInfo{}, err
	}
	return *info, nil
}
