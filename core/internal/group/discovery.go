// 群成员地址预热（P4-02）。
//
// 群聊走 GossipSub 私有主题，成员之间必须先建立 libp2p 连接才能形成 mesh。
// 新成员入群时本机只知道成员账号公钥，因此在受理密钥信封并订阅主题后，
// 需要通过 PeerResolver 把成员账号解析为 PeerID + 地址并主动拨号，
// 保证「新成员入群后 10s 内 mesh 连通」。
//
// 预热是有界重试：入群后立即拨一轮，之后按 interval 重试，直到全部成员连通
// 或达到 window 上限；解析失败（对端离线 / 索引服务不可用）不会中断其他成员。
package group

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p/core/peer"
)

const (
	// DefaultWarmupInterval 是成员地址预热的重试间隔。
	DefaultWarmupInterval = 2 * time.Second
	// DefaultWarmupWindow 是新成员入群后的预热窗口，超出后不再后台重试。
	DefaultWarmupWindow = 10 * time.Second
	// warmupConcurrency 限制单轮并发拨号数量，避免同时打满套接字。
	warmupConcurrency = 8
	// warmupDialTimeout 是单个成员单次拨号的超时。
	warmupDialTimeout = 5 * time.Second
)

// ErrNoPeerResolver 表示未配置成员地址解析器，无法预热群成员地址。
var ErrNoPeerResolver = errors.New("群成员地址预热缺少对端地址解析器")

// PeerResolver 把成员账号公钥解析为 libp2p 可达地址。
// 同一账号可绑定多台设备，因此返回 AddrInfo 列表；地址为空时由 host 通过 DHT 寻址。
type PeerResolver interface {
	ResolvePeer(ctx context.Context, accountPub []byte) ([]peer.AddrInfo, error)
}

// PeerResolverFunc 把普通函数适配为 PeerResolver。
type PeerResolverFunc func(ctx context.Context, accountPub []byte) ([]peer.AddrInfo, error)

// ResolvePeer 实现 PeerResolver。
func (f PeerResolverFunc) ResolvePeer(ctx context.Context, accountPub []byte) ([]peer.AddrInfo, error) {
	return f(ctx, accountPub)
}

// WarmupReport 是一轮成员地址预热的结果。
type WarmupReport struct {
	GroupID []byte
	// Members 是成员表人数（含本机）。
	Members int
	// Attempted 是需要解析的非本机成员数。
	Attempted int
	// Connected 是拨号成功的成员设备数；已连接的连接也计入。
	Connected int
	// Failed 是解析或拨号失败的成员设备数。
	Failed int
	// Skipped 是本机账号被跳过的次数。
	Skipped int
	// Peers 是预热结束后群主题的 mesh 邻居数。
	Peers int
}

// Warmup 对群成员做一轮地址预热：解析成员账号后主动拨号，促使 mesh 尽快成形。
// 单个成员失败不影响其他成员；未配置解析器返回 ErrNoPeerResolver。
func (s *Service) Warmup(ctx context.Context, groupID []byte) (WarmupReport, error) {
	if len(groupID) == 0 {
		return WarmupReport{}, ErrGroupIDRequired
	}
	if s.peers == nil {
		return WarmupReport{}, ErrNoPeerResolver
	}
	if ctx == nil {
		ctx = context.Background()
	}
	report := WarmupReport{GroupID: append([]byte(nil), groupID...)}

	members, err := s.members.Members(ctx, groupID)
	if err != nil {
		return report, err
	}
	report.Members = len(members)

	targets := make([][]byte, 0, len(members))
	for _, m := range members {
		if len(m) == 0 || bytes.Equal(m, s.account.Pub()) {
			report.Skipped++
			continue
		}
		targets = append(targets, m)
	}
	report.Attempted = len(targets)

	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		sem     = make(chan struct{}, warmupConcurrency)
		dialCtx = ctx
	)
	for _, account := range targets {
		wg.Add(1)
		sem <- struct{}{}
		go func(accountPub []byte) {
			defer wg.Done()
			defer func() { <-sem }()
			ok, hit := s.warmupMember(dialCtx, accountPub)
			mu.Lock()
			report.Connected += ok
			report.Failed += hit - ok
			mu.Unlock()
		}(account)
	}
	wg.Wait()
	report.Peers = s.Peers(groupID)
	return report, nil
}

// warmupMember 解析并拨通单个成员的全部设备。返回成功数与解析到的目标数。
func (s *Service) warmupMember(ctx context.Context, accountPub []byte) (ok, total int) {
	addrs, err := s.peers.ResolvePeer(ctx, accountPub)
	if err != nil || len(addrs) == 0 {
		return 0, 1
	}
	seen := make(map[peer.ID]struct{}, len(addrs))
	for _, info := range addrs {
		if info.ID == "" {
			continue
		}
		if _, dup := seen[info.ID]; dup {
			continue
		}
		seen[info.ID] = struct{}{}
		total++
		dialCtx, cancel := context.WithTimeout(ctx, warmupDialTimeout)
		err := s.connect(dialCtx, info.ID, info.Addrs)
		cancel()
		if err == nil {
			ok++
		}
	}
	if total == 0 {
		return 0, 1
	}
	return ok, total
}

// startWarmupLocked 在订阅群主题后启动有界预热协程；调用方必须持有 s.mu。
func (s *Service) startWarmupLocked(name string, groupID []byte) {
	if s.noWarmup || s.peers == nil {
		return
	}
	if _, running := s.warmups[name]; running {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, s.warmWindow)
	s.warmups[name] = cancel
	gid := append([]byte(nil), groupID...)
	s.wait.Add(1)
	go func() {
		defer s.wait.Done()
		defer cancel()
		defer func() {
			s.mu.Lock()
			delete(s.warmups, name)
			s.mu.Unlock()
		}()
		s.warmupLoop(ctx, gid)
	}()
}

// warmupLoop 立即预热一轮，之后按间隔重试，直到全部成员连通或窗口结束。
func (s *Service) warmupLoop(ctx context.Context, groupID []byte) {
	ticker := time.NewTicker(s.warmInterval)
	defer ticker.Stop()
	for {
		report, err := s.Warmup(ctx, groupID)
		if err == nil && report.Failed == 0 {
			// 全部成员设备已拨通（或成员表只有本机），提前结束。
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// stopWarmupLocked 取消指定群主题的预热协程；调用方必须持有 s.mu。
func (s *Service) stopWarmupLocked(name string) {
	if cancel, ok := s.warmups[name]; ok {
		cancel()
		delete(s.warmups, name)
	}
}
