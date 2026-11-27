package discovery

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	ma "github.com/multiformats/go-multiaddr"

	"github.com/nexmem/core/internal/dm"
)

var errNoAddress = errors.New("multiaddr 未提供地址")

// PublicBootstraps 是一组公共 IPFS DHT bootstrap 节点，用于无自建 bootstrap 时兜底。
// 这些节点只帮助发现 PeerID 的地址，不接触任何 Nexmem 消息内容。
var PublicBootstraps = []string{
	"/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
	"/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanqBuGT",
	"/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
	"/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
}

// CascadingResolver 按优先级串联多个发现源，实现 dm.PeerResolver。
// 命中顺序：本地地址簿 -> 已连接/mDNS -> 私有 DHT -> 公共 DHT。
type CascadingResolver struct {
	peerbook   *Peerbook
	mdns       *MDNS
	lanBeacon  *LANBeacon
	host       host.Host
	privateDHT *dht.IpfsDHT
	publicDHT  *dht.IpfsDHT
	// Fallback 是原有的 directoryResolver（账号->设备->地址），可为 nil。
	fallback dm.PeerResolver
	timeout  time.Duration
}

// NewCascadingResolver 创建级联解析器。
func NewCascadingResolver(h host.Host, book *Peerbook, md *MDNS, privateDHT, publicDHT *dht.IpfsDHT, fallback dm.PeerResolver) *CascadingResolver {
	return &CascadingResolver{
		peerbook:   book,
		mdns:       md,
		host:       h,
		privateDHT: privateDHT,
		publicDHT:  publicDHT,
		fallback:   fallback,
		timeout:    12 * time.Second,
	}
}

// SetLANBeacon 注入同 WiFi 账号发现源（在内核启动信标后调用）。
func (r *CascadingResolver) SetLANBeacon(b *LANBeacon) {
	r.lanBeacon = b
}

// ResolvePeer 实现 dm.PeerResolver：依次尝试各发现源。
func (r *CascadingResolver) ResolvePeer(ctx context.Context, accountPub []byte) (dm.Target, error) {
	if len(accountPub) != 32 {
		return dm.Target{}, dm.ErrInvalidTarget
	}
	ctx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()

	// 1) 本地地址簿：完全离线可用，最高优先级。
	if infos, ok := r.peerbook.Discover(ctx, accountPub); ok && len(infos) > 0 {
		info := infos[0]
		r.warmConnect(ctx, info)
		return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
	}

	// 1b) 同 WiFi 局域网发现：对端 UDP 广播的签名名片自带 accountID，
	// 不依赖目录服务。同网段直连，命中后优先于公网 DHT。
	wantAccount := strings.ToLower(hex.EncodeToString(accountPub))
	if r.lanBeacon != nil {
		for _, lp := range r.lanBeacon.Snapshot() {
			if strings.ToLower(lp.AccountID) != wantAccount || lp.Addr == "" {
				continue
			}
			info, err := peer.AddrInfoFromString(lp.Addr)
			if err != nil || len(info.Addrs) == 0 {
				continue
			}
			r.warmConnect(ctx, *info)
			return dm.Target{
				PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub,
			}, nil
		}
	}

	// 2) 原有 directory + DHT 链路：得到账号对应的 PeerID 候选。
	var candidate dm.Target
	var baseErr error
	if r.fallback != nil {
		candidate, baseErr = r.fallback.ResolvePeer(ctx, accountPub)
		if baseErr == nil && len(candidate.Addrs) > 0 {
			// DHT 可能返回过期地址（对端重启后端口变化），同网段时把 mDNS /
			// 已连接地址合并进来，避免拨号到陈旧地址后一直等 ACK 超时。
			if info := r.enhanceWithLocal(ctx, candidate.PeerID, candidate.Addrs); len(info.Addrs) > 0 {
				return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
			}
			return candidate, nil
		}
	}

	// 3) mDNS / 已连接对等：若已知 PeerID，补充局域网地址。
	if candidate.PeerID != "" {
		if info := r.enhanceWithLocal(ctx, candidate.PeerID, candidate.Addrs); len(info.Addrs) > 0 {
			return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
		}
	}

	// 4) 公共 DHT 兜底：使用与私有 DHT 相同的 PeerID（设备身份一致）。
	if candidate.PeerID != "" && r.publicDHT != nil {
		if info, err := r.publicDHT.FindPeer(ctx, candidate.PeerID); err == nil && len(info.Addrs) > 0 {
			return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
		}
	}

	if baseErr != nil {
		return dm.Target{}, baseErr
	}
	return dm.Target{}, fmt.Errorf("%w: 所有发现源均未命中", dm.ErrPeerUnreached)
}

// enhanceWithLocal 合并 mDNS 发现地址与已连接地址。
func (r *CascadingResolver) enhanceWithLocal(ctx context.Context, id peer.ID, existing []ma.Multiaddr) peer.AddrInfo {
	merged := append([]ma.Multiaddr(nil), existing...)
	if r.mdns != nil {
		merged = appendUnique(merged, r.mdns.AddressesFor(id))
	}
	if r.host != nil {
		// 已连接的对端地址可直接复用。
		for _, c := range r.host.Network().ConnsToPeer(id) {
			merged = appendUnique(merged, []ma.Multiaddr{c.RemoteMultiaddr()})
		}
	}
	info := peer.AddrInfo{ID: id, Addrs: merged}
	if len(merged) > 0 {
		r.warmConnect(ctx, info)
	}
	return info
}

// warmConnect 提前建连，减少首条消息的延迟；失败不影响解析结果。
func (r *CascadingResolver) warmConnect(ctx context.Context, info peer.AddrInfo) {
	if r.host == nil || len(info.Addrs) == 0 {
		return
	}
	if r.host.Network().Connectedness(info.ID) == network.Connected {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	_ = r.host.Connect(cctx, info)
}

// appendUnique 合并地址列表并去重。
func appendUnique(base, extra []ma.Multiaddr) []ma.Multiaddr {
	seen := map[string]struct{}{}
	for _, a := range base {
		seen[a.String()] = struct{}{}
	}
	for _, a := range extra {
		if _, ok := seen[a.String()]; ok {
			continue
		}
		seen[a.String()] = struct{}{}
		base = append(base, a)
	}
	return base
}

// ParsePublicBootstraps 把公共 bootstrap 字符串列表解析为 AddrInfo。
func ParsePublicBootstraps(raws []string) []peer.AddrInfo {
	out := make([]peer.AddrInfo, 0, len(raws))
	for _, raw := range raws {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if info, err := peer.AddrInfoFromString(raw); err == nil {
			out = append(out, *info)
		}
	}
	return out
}
