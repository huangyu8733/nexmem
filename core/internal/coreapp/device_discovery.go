package coreapp

// net.discoverDevices：汇总当前本机可见的设备，而不是主动发起全网扫描。
//
// 发现源包括本地地址簿、mDNS 局域网缓存、libp2p 已连接节点与 peerstore。
// 这里只返回身份/地址/连接性质，不做 IP 归属查询，也不会把位置信息上传。

import (
	"context"
	"encoding/json"
	"net"
	"sort"
	"strings"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	ma "github.com/multiformats/go-multiaddr"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/wire"
)

const (
	defaultDiscoverLimit  = 200
	maxDiscoverLimit      = 1000
	maxDiscoverCandidates = 10000
)

type discoveredDeviceRecord struct {
	peerID    string
	accountID string
	label     string
	addrs     []string
	ip        string
	connected bool
	direct    bool
	relayed   bool
	// verified 表示该节点由 address book / mDNS 明确标注为 Nexmem 节点；
	// 仅凭 peerstore 见过的节点必须支持 Nexmem 业务协议才会展示。
	verified bool
	sources  map[string]struct{}
	lastSeen int64
}

func (d *discoveredDeviceRecord) addAddrs(addrs []string, seen int64) {
	known := make(map[string]struct{}, len(d.addrs))
	for _, a := range d.addrs {
		known[a] = struct{}{}
	}
	for _, raw := range addrs {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if _, ok := known[raw]; ok {
			continue
		}
		known[raw] = struct{}{}
		d.addrs = append(d.addrs, raw)
	}
	// 每次地址集合变化后重算，保证后到的直连地址能覆盖先到的中继 IP。
	d.ip = firstIPFromAddrs(d.addrs)
	if seen > d.lastSeen {
		d.lastSeen = seen
	}
}

func (d *discoveredDeviceRecord) addSource(source string) {
	if d.sources == nil {
		d.sources = map[string]struct{}{}
	}
	d.sources[source] = struct{}{}
}

func (d *discoveredDeviceRecord) toJSON() map[string]any {
	sourceList := make([]string, 0, len(d.sources))
	for s := range d.sources {
		sourceList = append(sourceList, s)
	}
	sort.Strings(sourceList)
	return map[string]any{
		"peer_id":    d.peerID,
		"account_id": d.accountID,
		"label":      d.label,
		"addrs":      d.addrs,
		"ip":         d.ip,
		"connected":  d.connected,
		"direct":     d.direct,
		"relayed":    d.relayed,
		"source":     strings.Join(sourceList, ","),
		"last_seen":  d.lastSeen,
	}
}

// discoverDevicesHandler 实现 net.discoverDevices。
// limit/offset 只做分页，不承诺调用期间集合不变；客户端可重复调用刷新。
func (a *App) discoverDevicesHandler() gateway.HandlerFunc {
	return func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Limit  int `json:"limit"`
			Offset int `json:"offset"`
		}
		if len(params) > 0 {
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"net.discoverDevices 参数不是合法 JSON: %v", err)
			}
		}
		if req.Limit <= 0 {
			req.Limit = defaultDiscoverLimit
		}
		if req.Limit > maxDiscoverLimit {
			req.Limit = maxDiscoverLimit
		}
		if req.Offset < 0 {
			req.Offset = 0
		}

		a.mu.RLock()
		h, book, mdns, cfg, mdnsErr, lanBeacon := a.host, a.book, a.mdns, a.cfg, a.mdnsErr, a.lanBeacon
		a.mu.RUnlock()
		if h == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}

		// bootstrap / 中继节点只是基础设施，不能当成可添加好友的账号。
		infra := make(map[peer.ID]struct{})
		for _, raw := range append(append([]string{}, cfg.Bootstraps...), cfg.RelayAddrs...) {
			if info, err := peer.AddrInfoFromString(raw); err == nil {
				infra[info.ID] = struct{}{}
			}
		}

		self := h.ID().String()
		// 诊断计数：让客户端能区分"没发现""被过滤""host 无局域网地址"三种空态。
		// lanBeacon 非空表示 UDP 局域网广播发现已启动（即便 mDNS 被系统拦截，
		// 只要原生注入了局域网 IP，就仍可被同网段设备发现）。
		diag := &discoveryDiagnostics{LANBeaconActive: lanBeacon != nil}
		if lanBeacon != nil {
			diag.LANBroadcastErr = lanBeacon.BroadcastError()
			diag.LANBroadcastAddr = lanBeacon.BroadcastLocalAddr()
			diag.LANBroadcastSent = lanBeacon.BroadcastSent()
		}
		records := make(map[string]*discoveredDeviceRecord)
		get := func(peerID string) *discoveredDeviceRecord {
			peerID = strings.TrimSpace(peerID)
			if peerID == "" || peerID == self {
				return nil
			}
			if id, err := peer.Decode(peerID); err == nil {
				if _, ok := infra[id]; ok {
					diag.FilteredInfra++
					return nil
				}
			}
			r, ok := records[peerID]
			if !ok {
				r = &discoveredDeviceRecord{peerID: peerID, sources: map[string]struct{}{}}
				records[peerID] = r
			}
			return r
		}

		// 本地地址簿：唯一自带账号 ID 与备注的发现源。
		if book != nil {
			diag.PeerbookRaw = len(book.List())
			for _, e := range book.List() {
				r := get(e.PeerID)
				if r == nil {
					continue
				}
				r.accountID = e.AccountID
				if r.label == "" {
					r.label = e.Label
				}
				r.addAddrs(e.Addrs, e.UpdatedAt)
				r.addSource("peerbook")
				r.verified = true
			}
		}

		// mDNS 局域网缓存：只在 TTL 内的记录参与展示。
		diag.MDNSErr = mdnsErr
		if mdns != nil {
			diag.MDNSEnabled = true
			mdnsSnapshot := mdns.Snapshot()
			diag.MDNSRaw = len(mdnsSnapshot)
			for _, found := range mdnsSnapshot {
				r := get(found.ID.String())
				if r == nil {
					continue
				}
				addrs := make([]string, 0, len(found.Addrs))
				for _, addr := range found.Addrs {
					addrs = append(addrs, addr.String())
				}
				r.addAddrs(addrs, found.LastSeen)
				r.addSource("mdns")
				r.verified = true
			}
		}

		// 同 WiFi 账号发现：UDP 广播验签得到的名片，自带 accountID 与昵称，
		// 可直接加好友。这是 Android 上 mDNS 不可用时的可靠替代。
		if lanBeacon != nil {
			lanPeers := lanBeacon.Snapshot()
			diag.LANRaw = len(lanPeers)
			for _, lp := range lanPeers {
				r := get(lp.PeerID)
				if r == nil {
					continue
				}
				r.accountID = lp.AccountID
				if r.label == "" {
					r.label = lp.DisplayName
				}
				r.addAddrs([]string{lp.Addr}, lp.LastSeen.UnixMilli())
				r.addSource("lan")
				r.verified = true
			}
		}

		now := time.Now().UnixMilli()
		// 已连接节点：连接性质由 netnode.InspectPeer 统一判定。
		connectedPeers := h.Network().Peers()
		diag.ConnectedRaw = len(connectedPeers)
		for _, p := range connectedPeers {
			r := get(p.String())
			if r == nil {
				continue
			}
			info := netnode.InspectPeer(h, p)
			r.connected = info.Connected
			r.direct = info.Direct
			r.relayed = info.Relayed
			r.addAddrs(info.Addrs, now)
			r.addSource("connected")
		}

		// peerstore：曾经见过但未连接的节点，网页/移动端重启后仍可快速重连。
		diag.PeerstoreRaw = len(h.Peerstore().Peers())
		known := 0
		for _, p := range h.Peerstore().Peers() {
			if known >= maxDiscoverCandidates {
				break
			}
			r := get(p.String())
			if r == nil {
				continue
			}
			addrs := make([]string, 0)
			for _, addr := range h.Peerstore().Addrs(p) {
				addrs = append(addrs, addr.String())
			}
			if len(addrs) == 0 {
				continue
			}
			known++
			r.addAddrs(addrs, 0)
			r.addSource("peerstore")
		}

		all := make([]*discoveredDeviceRecord, 0, len(records))
		for _, r := range records {
			if len(r.addrs) == 0 {
				continue
			}
			// 账号发现只展示可添加好友的 Nexmem 节点。peerstore 里残留的
			// DHT 探测节点、中继节点没有业务协议，必须过滤掉。
			if !r.verified {
				id, err := peer.Decode(r.peerID)
				if err != nil || !supportsNexmem(h, id) {
					diag.FilteredNoProtocol++
					continue
				}
			}
			all = append(all, r)
		}
		sort.Slice(all, func(i, j int) bool {
			if all[i].connected != all[j].connected {
				return all[i].connected
			}
			if all[i].lastSeen != all[j].lastSeen {
				return all[i].lastSeen > all[j].lastSeen
			}
			return all[i].peerID < all[j].peerID
		})

		total := len(all)
		end := req.Offset + req.Limit
		if req.Offset > total {
			req.Offset = total
		}
		if end > total {
			end = total
		}
		items := make([]map[string]any, 0, end-req.Offset)
		for _, r := range all[req.Offset:end] {
			items = append(items, r.toJSON())
		}

		// 本机监听地址：mDNS 只能广播这里出现的局域网地址。若为空或只剩
		// 回环/中继地址，说明 host 没拿到局域网接口（Android SELinux 拒绝
		// netlink、iOS 未授权本地网络都会导致），此时同网段节点无法互相发现。
		for _, addr := range h.Addrs() {
			s := addr.String()
			diag.SelfAddrs = append(diag.SelfAddrs, s)
			if ip := firstIPFromAddrs([]string{s}); ip != "" {
				parsed := net.ParseIP(ip)
				if parsed != nil && !parsed.IsLoopback() && !parsed.IsUnspecified() &&
					!isRelayAddr(s) {
					diag.HasLANAddr = true
				}
			}
		}
		diag.SelfID = self
		diag.InjectedLan = cfg.LanAddrs
		// 原始监听地址（不经过 AddrsFactory/接口展开）：确认 host 是否真的
		// 绑了 TCP/QUIC 端口。若这里有地址而 self_addrs 为空，说明只是
		// 接口枚举被拦截，原生注入 IP 即可修复。
		for _, addr := range h.Network().ListenAddresses() {
			diag.ListenAddrs = append(diag.ListenAddrs, addr.String())
		}
		// Go 侧枚举的网卡地址：mDNS 的 InterfaceListenAddresses 依赖它展开
		// /ip4/0.0.0.0。若为空，说明系统接口枚举被拦截（Android SELinux）。
		diag.NetIfaces = goInterfaceAddresses()

		return map[string]any{
			"items":       items,
			"total":       total,
			"offset":      req.Offset,
			"limit":       req.Limit,
			"diagnostics": diag.toJSON(),
		}, nil
	}
}

// isRelayAddr 判断 multiaddr 是否为中继地址（其 IP 属于中继服务器，不是本机）。
func isRelayAddr(raw string) bool {
	return strings.Contains(raw, "/p2p-circuit") || strings.Contains(raw, "/p2p-webrtc-star")
}

// discoveryDiagnostics 描述一次账号发现的各发现源与过滤计数，
// 供客户端在空态时给出准确原因，不暴露对端隐私。
type discoveryDiagnostics struct {
	MDNSEnabled        bool     `json:"mdns_enabled"`
	MDNSRaw            int      `json:"mdns_raw"`
	PeerbookRaw        int      `json:"peerbook_raw"`
	ConnectedRaw       int      `json:"connected_raw"`
	PeerstoreRaw       int      `json:"peerstore_raw"`
	FilteredInfra      int      `json:"filtered_infra"`
	FilteredNoProtocol int      `json:"filtered_no_protocol"`
	HasLANAddr         bool     `json:"has_lan_addr"`
	SelfAddrs          []string `json:"self_addrs"`
	SelfID             string   `json:"self_id"`
	NetIfaces          []string `json:"net_ifaces"`
	ListenAddrs        []string `json:"listen_addrs"`
	InjectedLan        []string `json:"injected_lan"`
	MDNSErr            string   `json:"mdns_error"`
	LANRaw             int      `json:"lan_raw"`
	LANBeaconActive    bool     `json:"lan_beacon_active"`
	LANBroadcastErr    string   `json:"lan_broadcast_error"`
	LANBroadcastAddr   string   `json:"lan_broadcast_addr"`
	LANBroadcastSent   uint64   `json:"lan_broadcast_sent"`
}

// goInterfaceAddresses 返回 Go runtime 枚举到的本机网卡 IP，
// 用于确认 Android 上 net.Interfaces() 是否因 SELinux 被拦截，
// 导致 mDNS 的 InterfaceListenAddresses 无法展开 /ip4/0.0.0.0。
func goInterfaceAddresses() []string {
	out := []string{}
	ifaces, err := net.Interfaces()
	if err != nil {
		return append(out, "error:"+err.Error())
	}
	for _, iface := range ifaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			out = append(out, iface.Name+"="+addr.String())
		}
	}
	return out
}

func (d *discoveryDiagnostics) toJSON() map[string]any {
	if d.SelfAddrs == nil {
		d.SelfAddrs = []string{}
	}
	if d.NetIfaces == nil {
		d.NetIfaces = []string{}
	}
	if d.ListenAddrs == nil {
		d.ListenAddrs = []string{}
	}
	if d.InjectedLan == nil {
		d.InjectedLan = []string{}
	}
	return map[string]any{
		"mdns_enabled":         d.MDNSEnabled,
		"mdns_raw":             d.MDNSRaw,
		"peerbook_raw":         d.PeerbookRaw,
		"connected_raw":        d.ConnectedRaw,
		"peerstore_raw":        d.PeerstoreRaw,
		"filtered_infra":       d.FilteredInfra,
		"filtered_no_protocol": d.FilteredNoProtocol,
		"has_lan_addr":         d.HasLANAddr,
		"self_addrs":           d.SelfAddrs,
		"self_id":              d.SelfID,
		"net_ifaces":           d.NetIfaces,
		"listen_addrs":         d.ListenAddrs,
		"injected_lan":         d.InjectedLan,
		"mdns_error":           d.MDNSErr,
		"lan_raw":              d.LANRaw,
		"lan_beacon_active":    d.LANBeaconActive,
		"lan_broadcast_error":  d.LANBroadcastErr,
		"lan_broadcast_addr":   d.LANBroadcastAddr,
		"lan_broadcast_sent":   d.LANBroadcastSent,
	}
}

// supportsNexmem 判断节点是否宣告了 Nexmem 业务协议；identify 握手后可用。
func supportsNexmem(h host.Host, id peer.ID) bool {
	if h == nil {
		return false
	}
	proto, err := h.Peerstore().FirstSupportedProtocol(
		id,
		wire.PIDDM,
		wire.PIDFile,
		wire.PIDMeta,
		wire.PIDRTC,
		wire.PIDFs,
	)
	return err == nil && proto != ""
}

// firstIPFromAddrs 从 multiaddr 列表中提取第一个 IP，供客户端展示与后续地图标注。
func firstIPFromAddrs(addrs []string) string {
	// 两轮扫描：优先直连地址，只有没有直连 IP 时才退回中继地址里的 IP，
	// 避免把中继服务器的地理位置当成被控设备的位置。
	for _, preferDirect := range []bool{true, false} {
		for _, raw := range addrs {
			isRelay := strings.Contains(raw, "/p2p-circuit")
			if preferDirect == isRelay {
				continue
			}
			a, err := ma.NewMultiaddr(raw)
			if err != nil {
				continue
			}
			for _, code := range []int{ma.P_IP4, ma.P_IP6} {
				if v, err := a.ValueForProtocol(code); err == nil && v != "" {
					return v
				}
			}
		}
	}
	return ""
}
