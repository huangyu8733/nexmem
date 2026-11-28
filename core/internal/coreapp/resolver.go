package coreapp

import (
	"context"
	"errors"
	"fmt"
	"time"

	dht "github.com/libp2p/go-libp2p-kad-dht"
	lpcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"

	"github.com/nexmem/core/internal/directory"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/group"
	"github.com/nexmem/core/internal/store"
)

// directoryResolver 通过索引服务档案中的设备公钥 + DHT 定位对端。
//
// 档案里的每个设备公钥都能唯一推出 PeerID；命中后向 DHT 查询地址，
// 冷启动首次查询可能失败，因此按固定间隔重试，区分「未收敛」与「真正不可达」。
type directoryResolver struct {
	client *directory.Client
	dht    *dht.IpfsDHT
}

func newDirectoryResolver(client *directory.Client, kad *dht.IpfsDHT) dm.PeerResolver {
	return &directoryResolver{client: client, dht: kad}
}

// ResolvePeerIDs 只做信令服务器的「账号 → 设备 PeerID」身份映射，不查询地址。
//
// 拆出这一步是为了让 CascadingResolver 先拿到 PeerID，再按
// 「公网 DHT → 私有 DHT → 信令服务器兜底」的顺序发现地址：
// DHT 只能按 PeerID 检索，若把 directory 的整体解析放在最前，
// 中心服务器就会抢在分布式的 DHT 之前决定对端地址。
func (r *directoryResolver) ResolvePeerIDs(ctx context.Context, accountPub []byte) ([]peer.ID, error) {
	if len(accountPub) != 32 {
		return nil, dm.ErrInvalidTarget
	}
	if r.client == nil {
		return nil, fmt.Errorf("%w: 索引服务未就绪", dm.ErrPeerUnreached)
	}
	ctx, cancel := context.WithTimeout(ctx, defaultResolveTimeout)
	defer cancel()

	profile, err := r.client.GetProfile(ctx, accountPub)
	if err != nil {
		return nil, fmt.Errorf("%w: 读取档案: %v", dm.ErrPeerUnreached, err)
	}
	ids := make([]peer.ID, 0, len(profile.GetDevices()))
	for _, dev := range profile.GetDevices() {
		pub, err := lpcrypto.UnmarshalPublicKey(dev.GetDevicePub())
		if err != nil {
			continue
		}
		id, err := peer.IDFromPublicKey(pub)
		if err != nil {
			continue
		}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, fmt.Errorf("%w: 档案中没有可用设备", dm.ErrPeerUnreached)
	}
	return ids, nil
}

// ResolvePeer 实现 dm.PeerResolver：走完整的信令服务器链路（身份映射 + DHT 地址查询）。
// 作为级联解析的最后一级，DHT 阶段都未命中时才由它兜底。
func (r *directoryResolver) ResolvePeer(ctx context.Context, accountPub []byte) (dm.Target, error) {
	if r.dht == nil {
		return dm.Target{}, fmt.Errorf("%w: DHT 未就绪", dm.ErrPeerUnreached)
	}
	ctx, cancel := context.WithTimeout(ctx, defaultResolveTimeout)
	defer cancel()

	ids, err := r.ResolvePeerIDs(ctx, accountPub)
	if err != nil {
		return dm.Target{}, err
	}
	var lastErr error
	for _, id := range ids {
		info, err := r.findPeer(ctx, id)
		if err != nil {
			lastErr = err
			continue
		}
		if len(info.Addrs) == 0 {
			lastErr = errors.New("DHT 未返回地址")
			continue
		}
		return dm.Target{PeerID: info.ID, Addrs: info.Addrs, AccountPub: accountPub}, nil
	}
	if lastErr == nil {
		lastErr = errors.New("档案中没有可用设备")
	}
	// 即使 DHT 查不到地址也保留 PeerID，让上层能用 relay / 离线投递兜底。
	return dm.Target{PeerID: ids[0], AccountPub: accountPub},
		fmt.Errorf("%w: %v", dm.ErrPeerUnreached, lastErr)
}

// findPeer 对单个 PeerID 执行带重试的 DHT 查询。
func (r *directoryResolver) findPeer(ctx context.Context, id peer.ID) (peer.AddrInfo, error) {
	var lastErr error
	for _, delay := range resolveAttempts {
		if delay > 0 {
			select {
			case <-ctx.Done():
				return peer.AddrInfo{}, ctx.Err()
			case <-time.After(delay):
			}
		}
		info, err := r.dht.FindPeer(ctx, id)
		if err == nil {
			return info, nil
		}
		lastErr = err
	}
	return peer.AddrInfo{}, lastErr
}

// directoryXPub 通过索引服务档案解析账号 X25519 公钥，供群密钥信封封装使用。
type directoryXPub struct {
	client *directory.Client
}

// XPub 实现 group.XPubResolver。
func (r directoryXPub) XPub(ctx context.Context, accountPub []byte) ([]byte, error) {
	if len(accountPub) != 32 {
		return nil, dm.ErrInvalidTarget
	}
	if r.client == nil {
		return nil, errors.New("索引服务客户端未就绪")
	}
	ctx, cancel := context.WithTimeout(ctx, defaultResolveTimeout)
	defer cancel()
	profile, err := r.client.GetProfile(ctx, accountPub)
	if err != nil {
		return nil, fmt.Errorf("读取档案: %w", err)
	}
	if len(profile.AccountXPub) != 32 {
		return nil, errors.New("档案缺少账号 X25519 公钥")
	}
	return profile.AccountXPub, nil
}

// contactXPub 从本地联系人缓存解析账号 X25519 公钥。
//
// 好友申请/同意控制帧在已验签的单聊通道里携带账号 XPub；这样即使没有配置
// 信令服务器公开档案，同一局域网内添加的好友也能正常接收群密钥信封。
type contactXPub struct {
	dao  func() *store.DAO
	wait func(context.Context, []byte) ([]byte, error)
}

func (r contactXPub) XPub(ctx context.Context, accountPub []byte) ([]byte, error) {
	if r.dao == nil {
		return nil, errors.New("联系人数据库未就绪")
	}
	dao := r.dao()
	if dao == nil {
		return nil, errors.New("联系人数据库未就绪")
	}
	c, err := dao.GetContact(ctx, accountPub)
	if err != nil {
		return nil, fmt.Errorf("读取联系人档案: %w", err)
	}
	if len(c.AccountXPub) != 32 {
		if r.wait == nil {
			return nil, errors.New("联系人档案缺少账号 X25519 公钥")
		}
		return r.wait(ctx, accountPub)
	}
	return append([]byte(nil), c.AccountXPub...), nil
}

// fallbackXPub 先走主解析器（索引服务/注入实现），失败时回退到本地联系人缓存。
type fallbackXPub struct {
	primary  group.XPubResolver
	fallback group.XPubResolver
}

func (r fallbackXPub) XPub(ctx context.Context, accountPub []byte) ([]byte, error) {
	if r.primary != nil {
		if xpub, err := r.primary.XPub(ctx, accountPub); err == nil && len(xpub) == 32 {
			return xpub, nil
		}
	}
	if r.fallback != nil {
		return r.fallback.XPub(ctx, accountPub)
	}
	return nil, errors.New("缺少成员 X25519 公钥解析器")
}

// defaultGroupTargets 把成员账号解析为群密钥信封投递目标。
// 对端离线（DHT 无地址）时仍返回账号 X25519 公钥，改由单聊离线通道兜底；
// 只有档案缺失导致无法封装密钥时才报错。
type defaultGroupTargets struct {
	peer dm.PeerResolver
	xpub group.XPubResolver
}

// ResolveTarget 实现 group.TargetResolver。
func (r defaultGroupTargets) ResolveTarget(ctx context.Context, accountPub []byte) (group.KeyTarget, error) {
	if len(accountPub) != 32 {
		return group.KeyTarget{}, dm.ErrInvalidTarget
	}
	target := group.KeyTarget{AccountPub: accountPub}
	if r.peer != nil {
		t, err := r.peer.ResolvePeer(ctx, accountPub)
		switch {
		case err == nil:
			target.PeerID = t.PeerID
			target.Addrs = t.Addrs
		case !errors.Is(err, dm.ErrPeerUnreached):
			return group.KeyTarget{}, err
		}
	}
	if r.xpub != nil {
		xpub, err := r.xpub.XPub(ctx, accountPub)
		if err != nil {
			return group.KeyTarget{}, err
		}
		target.XPub = xpub
	}
	if len(target.XPub) != 32 {
		return group.KeyTarget{}, errors.New("缺少成员 X25519 公钥解析器")
	}
	return target, nil
}

// groupWarmupResolver 把单聊解析结果适配为群成员地址预热来源。
type groupWarmupResolver struct {
	lookup dm.PeerResolver
}

// ResolvePeer 实现 group.PeerResolver。
func (r groupWarmupResolver) ResolvePeer(ctx context.Context, accountPub []byte) ([]peer.AddrInfo, error) {
	if r.lookup == nil {
		return nil, errors.New("未配置对端解析器")
	}
	t, err := r.lookup.ResolvePeer(ctx, accountPub)
	if err != nil {
		return nil, err
	}
	if t.PeerID == "" {
		return nil, errors.New("对端未返回 PeerID")
	}
	return []peer.AddrInfo{{ID: t.PeerID, Addrs: t.Addrs}}, nil
}
