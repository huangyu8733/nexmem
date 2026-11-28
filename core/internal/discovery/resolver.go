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

// peerIDSource 只需把账号映射到设备 PeerID，不负责查地址。
// 信令服务器的这一能力是公网 DHT 检索的前置：DHT 按 PeerID 而非账号查找。
type peerIDSource interface {
	ResolvePeerIDs(ctx context.Context, accountPub []byte) ([]peer.ID, error)
}

// CascadingResolver 按网络范围从小到大串联发现源，实现 dm.PeerResolver。
//
// 局域网广播（LAN Beacon / mDNS / 已连接）无法跨路由器，所以先在本地网段内
// 找；找不到再用公网 DHT 按 PeerID 查；两者都拿不到地址时最后走信令/索引服务。
// 命中顺序：本地地址簿/局域网 -> 公网 DHT -> 私有 DHT -> 信令服务器。
type CascadingResolver struct {
	peerbook   *Peerbook
	mdns       *MDNS
	lanBeacon  *LANBeacon
	host       host.Host
	privateDHT *dht.IpfsDHT
	publicDHT  *dht.IpfsDHT
	// fallback 是原有的 directoryResolver（账号->设备->地址），可为 nil。
	// 只在局域网与 DHT 都失败时调用，避免中心服务器抢在分布式发现之前。
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

// ResolvePeer 实现 dm.PeerResolver：按网络范围从小到大依次尝试各发现源。
//
// 阶段一（局域网）：地址簿、LAN Beacon、mDNS / 已连接节点，都不跨路由器，
// 但同网段直连最快且不依赖任何中心服务。
// 阶段二（公网 DHT）：局域网找不到时，先向信令服务器取账号对应的设备 PeerID
// （仅身份映射，不查地址），再依次查公共 DHT、私有 DHT 拿到公网地址。
// 阶段三（信令服务器）：DHT 都没有地址时，最后走 directoryResolver 的
// 完整链路（档案 + DHT 重试）兜底。
func (r *CascadingResolver) ResolvePeer(ctx context.Context, accountPub []byte) (dm.Target, error) {
	if len(accountPub) != 32 {
		return dm.Target{}, dm.ErrInvalidTarget
	}
	ctx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()

	// 阶段一：本地地址簿，完全离线可用。
	if infos, ok := r.peerbook.Discover(ctx, accountPub); ok && len(infos) > 0 {
		info := infos[0]
		r.warmConnect(ctx, info)
		return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
	}

	// 阶段一：同 WiFi 局域网发现。对端 UDP 广播的签名名片自带 accountID，
	// 不依赖目录服务；同网段直连，命中后优先于任何公网发现。
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

	// 阶段二：先取 PeerID（DHT 检索的前置），再按公共 DHT -> 私有 DHT 查地址。
	// 两个 DHT 都只做分布式地址发现，不接触消息内容。
	ids, idErr := r.resolvePeerIDs(ctx, accountPub)
	for _, id := range ids {
		for _, kad := range []*dht.IpfsDHT{r.publicDHT, r.privateDHT} {
			if kad == nil {
				continue
			}
			info, err := kad.FindPeer(ctx, id)
			if err != nil || len(info.Addrs) == 0 {
				continue
			}
			// DHT 可能返回过期地址，同网段时用 mDNS / 已连接地址补齐。
			if local := r.enhanceWithLocal(ctx, info.ID, info.Addrs); len(local.Addrs) > 0 {
				return dm.Target{PeerID: local.ID, Addrs: local.Addrs, AccountPub: accountPub}, nil
			}
			return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
		}
	}

	// 阶段三：信令服务器兜底。若 DHT 已拿到 PeerID 但没有地址，仍把 PeerID
	// 交给下层（relay / 离线投递）使用；否则才把错误抛给调用方。
	if r.fallback != nil {
		candidate, err := r.fallback.ResolvePeer(ctx, accountPub)
		if err == nil && len(candidate.Addrs) > 0 {
			if info := r.enhanceWithLocal(ctx, candidate.PeerID, candidate.Addrs); len(info.Addrs) > 0 {
				return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
			}
			return candidate, nil
		}
		if candidate.PeerID != "" {
			return dm.Target{PeerID: candidate.PeerID, AccountPub: accountPub}, nil
		}
		if err != nil {
			return dm.Target{}, err
		}
	}

	if idErr != nil {
		return dm.Target{}, idErr
	}
	return dm.Target{}, fmt.Errorf("%w: 所有发现源均未命中", dm.ErrPeerUnreached)
}

// resolvePeerIDs 从信令服务器的身份映射能力取账号对应的设备 PeerID。
// fallback 未实现 peerIDSource 时（例如测试替身或旧实现），退回用其
// ResolvePeer 结果里的 PeerID，保证级联对任意 dm.PeerResolver 都能工作。
func (r *CascadingResolver) resolvePeerIDs(ctx context.Context, accountPub []byte) ([]peer.ID, error) {
	if src, ok := r.fallback.(peerIDSource); ok {
		return src.ResolvePeerIDs(ctx, accountPub)
	}
	if r.fallback != nil {
		target, err := r.fallback.ResolvePeer(ctx, accountPub)
		if target.PeerID != "" {
			return []peer.ID{target.PeerID}, err
		}
		return nil, err
	}
	return nil, nil
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
