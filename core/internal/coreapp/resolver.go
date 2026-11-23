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

// ResolvePeer 实现 dm.PeerResolver。
func (r *directoryResolver) ResolvePeer(ctx context.Context, accountPub []byte) (dm.Target, error) {
	if len(accountPub) != 32 {
		return dm.Target{}, dm.ErrInvalidTarget
	}
	if r.client == nil || r.dht == nil {
		return dm.Target{}, fmt.Errorf("%w: 索引服务或 DHT 未就绪", dm.ErrPeerUnreached)
	}
	ctx, cancel := context.WithTimeout(ctx, defaultResolveTimeout)
	defer cancel()

	profile, err := r.client.GetProfile(ctx, accountPub)
	if err != nil {
		return dm.Target{}, fmt.Errorf("%w: 读取档案: %v", dm.ErrPeerUnreached, err)
	}
	var lastErr error
	for _, dev := range profile.GetDevices() {
		pub, err := lpcrypto.UnmarshalPublicKey(dev.GetDevicePub())
		if err != nil {
			lastErr = err
			continue
		}
		id, err := peer.IDFromPublicKey(pub)
		if err != nil {
			lastErr = err
			continue
		}
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
	return dm.Target{}, fmt.Errorf("%w: %v", dm.ErrPeerUnreached, lastErr)
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
