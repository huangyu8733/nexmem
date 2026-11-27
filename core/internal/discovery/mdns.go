package discovery

import (
	"context"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	libp2pmdns "github.com/libp2p/go-libp2p/p2p/discovery/mdns"
	"github.com/libp2p/zeroconf/v2"
	ma "github.com/multiformats/go-multiaddr"
)

// MDNSServiceName 是 Nexmem 局域网发现的 mDNS 服务名。
// 同网段内运行相同服务名的节点会互相发现。
const MDNSServiceName = "_nexmem._udp"

const (
	mdnsDomain     = "local."
	dnsaddrPrefix  = "dnsaddr="
	mdnsInstanceID = "nexmem"
)

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

// HandlePeerFound 实现发现回调：记录地址并尝试自动连接，
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
	service libp2pmdns.Service
	server  *zeroconf.Server
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	notifee *mdnsNotifee
	host    host.Host
	ifaces  []net.Interface
}

// multicastInterfacesFromSysfs 从 /sys/class/net 读取网卡名与索引，
// 构造 zeroconf 组播所需的最小 net.Interface（只需 Index）。
// 这是 Android SELinux 拦截 netlink 导致 net.Interfaces() 失败时的兜底。
func multicastInterfacesFromSysfs() []net.Interface {
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return nil
	}
	out := make([]net.Interface, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, "lo") || strings.HasPrefix(name, "dummy") {
			continue
		}
		raw, err := os.ReadFile("/sys/class/net/" + name + "/ifindex")
		if err != nil {
			continue
		}
		index, err := strconv.Atoi(strings.TrimSpace(string(raw)))
		if err != nil || index <= 0 {
			continue
		}
		out = append(out, net.Interface{
			Name:  name,
			Index: index,
			Flags: net.FlagUp | net.FlagMulticast,
		})
	}
	return out
}

// StartMDNS 启动 mDNS 广播与发现。失败时返回错误，调用方可降级为其他源。
func StartMDNS(h host.Host) (*MDNS, error) {
	return StartMDNSWithLan(h, nil)
}

// StartMDNSWithLan 启动 mDNS，允许注入宿主提供的局域网 IP。
//
// 标准 libp2p mDNS 通过 net.Interfaces() 展开 /ip4/0.0.0.0 得到广播地址，
// 但 Android 上该调用常被 SELinux 拦截（route ip+net: netlinkrib: permission
// denied），导致无地址可广播。注入 lanIPs 后改用 zeroconf 直接广播这些 IP，
// 使同一 WiFi 下的设备仍可互相发现。
func StartMDNSWithLan(h host.Host, lanIPs []string) (*MDNS, error) {
	n := &mdnsNotifee{addrs: map[peer.ID]cachedAddr{}, host: h}
	m := &MDNS{notifee: n, host: h}
	if len(lanIPs) == 0 {
		// 标准路径：libp2p 自行枚举接口。
		svc := libp2pmdns.NewMdnsService(h, MDNSServiceName, n)
		if err := svc.Start(); err != nil {
			return nil, err
		}
		m.service = svc
		return m, nil
	}
	// 注入路径：用 zeroconf 直接广播/发现，绕开 net.Interfaces()。
	if err := m.startInjected(lanIPs); err != nil {
		return nil, err
	}
	return m, nil
}

// startInjected 用注入的局域网 IP 启动 zeroconf 广播与浏览。
func (m *MDNS) startInjected(lanIPs []string) error {
	h := m.host
	if h == nil {
		return fmt.Errorf("mDNS: host 为空")
	}
	// 从 libp2p 的原始监听地址里取 TCP 端口（/ip4/0.0.0.0/tcp/PORT）。
	port := lanTCPPort(h)
	if port <= 0 {
		return fmt.Errorf("mDNS: 未找到局域网 TCP 监听端口")
	}
	// TXT 记录携带可对端直连的 p2p 地址。
	txts := make([]string, 0, len(lanIPs))
	for _, ip := range lanIPs {
		addr := fmt.Sprintf("/ip4/%s/tcp/%d/p2p/%s", ip, port, h.ID().String())
		txts = append(txts, dnsaddrPrefix+addr)
	}
	// Android 上 net.Interfaces() 因 SELinux 拒绝 netlink 而失败，zeroconf
	// 内部的 listMulticastInterfaces() 会拿到空列表导致组播绑定失败。这里
	// 从 sysfs 构造网卡（只需 Index），绕开 netlink 枚举。
	ifaces := multicastInterfacesFromSysfs()
	if len(ifaces) == 0 {
		return fmt.Errorf("mDNS: 无法枚举组播网卡（net.Interfaces 被拦截且 sysfs 不可用）")
	}
	server, err := zeroconf.RegisterProxy(
		mdnsInstanceID, MDNSServiceName, mdnsDomain, port,
		mdnsInstanceID, lanIPs, txts, ifaces,
	)
	if err != nil {
		return fmt.Errorf("mDNS 广播启动失败: %w", err)
	}
	m.server = server
	m.ifaces = ifaces

	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	entries := make(chan *zeroconf.ServiceEntry, 256)
	m.wg.Add(2)
	go func() {
		defer m.wg.Done()
		for entry := range entries {
			infos := parseEntries(entry)
			for _, info := range infos {
				m.notifee.HandlePeerFound(info)
			}
		}
	}()
	go func() {
		defer m.wg.Done()
		if err := zeroconf.Browse(ctx, MDNSServiceName, mdnsDomain, entries, zeroconf.SelectIfaces(ifaces)); err != nil && ctx.Err() == nil {
			// 浏览失败时静默降级：账号发现仍可从地址簿/已连接节点工作。
			_ = err
		}
	}()
	return nil
}

// lanTCPPort 从 host 的原始监听地址里提取 IPv4 TCP 端口。
func lanTCPPort(h host.Host) int {
	for _, addr := range h.Network().ListenAddresses() {
		if v, err := addr.ValueForProtocol(ma.P_TCP); err == nil {
			var port int
			if _, err := fmt.Sscanf(v, "%d", &port); err == nil && port > 0 {
				return port
			}
		}
	}
	return 0
}

// parseEntries 从 zeroconf 服务记录的 TXT 里解析出对端 AddrInfo。
func parseEntries(entry *zeroconf.ServiceEntry) []peer.AddrInfo {
	if entry == nil {
		return nil
	}
	addrs := make([]ma.Multiaddr, 0, len(entry.Text))
	for _, txt := range entry.Text {
		if !strings.HasPrefix(txt, dnsaddrPrefix) {
			continue
		}
		addr, err := ma.NewMultiaddr(strings.TrimPrefix(txt, dnsaddrPrefix))
		if err != nil {
			continue
		}
		addrs = append(addrs, addr)
	}
	if len(addrs) == 0 {
		return nil
	}
	infos, err := peer.AddrInfosFromP2pAddrs(addrs...)
	if err != nil {
		return nil
	}
	return infos
}

// Close 停止 mDNS 服务。
func (m *MDNS) Close() error {
	if m.server != nil {
		m.server.Shutdown()
		m.server = nil
	}
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.wg.Wait()
	if m.service != nil {
		return m.service.Close()
	}
	return nil
}

// AddressesFor 返回 mDNS 发现的某 PeerID 的地址（未过期）。
func (m *MDNS) AddressesFor(id peer.ID) []ma.Multiaddr {
	if m == nil || m.notifee == nil {
		return nil
	}
	return m.notifee.addressesFor(id)
}

// DiscoveredPeer 是 mDNS 缓存中的一条未过期发现记录。
// 供 net.discoverDevices 汇总给客户端，不暴露对接服务内部状态。
type DiscoveredPeer struct {
	ID       peer.ID
	Addrs    []ma.Multiaddr
	LastSeen int64 // Unix 毫秒
}

// Snapshot 返回当前未过期的 mDNS 发现结果。
// 只做只读取样，不会触发新的主动连接。
func (m *MDNS) Snapshot() []DiscoveredPeer {
	if m == nil || m.notifee == nil {
		return nil
	}
	now := time.Now()
	m.notifee.mu.RLock()
	defer m.notifee.mu.RUnlock()
	out := make([]DiscoveredPeer, 0, len(m.notifee.addrs))
	for id, c := range m.notifee.addrs {
		age := now.Sub(c.seen)
		if age < 0 || age > addrTTL {
			continue
		}
		out = append(out, DiscoveredPeer{
			ID:       id,
			Addrs:    append([]ma.Multiaddr(nil), c.addrs...),
			LastSeen: c.seen.UnixMilli(),
		})
	}
	return out
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
