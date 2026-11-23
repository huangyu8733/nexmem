package dm

import (
	"context"
	"errors"
	"time"

	"github.com/libp2p/go-libp2p/core/network"
	"github.com/multiformats/go-multiaddr"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/store"
)

const (
	// DefaultResumeInterval 是后台补发扫描离线队列的间隔。
	DefaultResumeInterval = 30 * time.Second
	// DefaultResumeRetryDelay 是单条补发失败后的退避时间。
	DefaultResumeRetryDelay = 30 * time.Second
	// resumeBatchSize 是单次扫描的条目上限。
	resumeBatchSize = 200
	// resumePassTimeout 是单次补发扫描的总超时。
	resumePassTimeout = 2 * time.Minute
)

// ErrNoPeerResolver 表示未配置对端地址解析器，离线队列无法补发。
var ErrNoPeerResolver = errors.New("离线补发缺少对端地址解析器")

// PeerResolver 把对端账号公钥解析为可直连目标（PeerID + 地址）。
// 实现方可来自通讯录、DHT 寻址或本地地址簿。
type PeerResolver interface {
	ResolvePeer(ctx context.Context, accountPub []byte) (Target, error)
}

// PeerResolverFunc 把普通函数适配为 PeerResolver。
type PeerResolverFunc func(ctx context.Context, accountPub []byte) (Target, error)

// ResolvePeer 实现 PeerResolver。
func (f PeerResolverFunc) ResolvePeer(ctx context.Context, accountPub []byte) (Target, error) {
	return f(ctx, accountPub)
}

// ResumeReport 汇总一次补发扫描的结果。
type ResumeReport struct {
	Scanned   int // 扫描到的到期条目
	Delivered int // 补发成功并出队
	Dropped   int // 被对端拒收或载荷损坏，已出队并标记 failed
	Retained  int // 仍不可达，保留在队列等待下次重试
}

// peerNotifiee 在对端连接建立时触发一次补发。
type peerNotifiee struct {
	svc *Service
}

func (n peerNotifiee) Connected(network.Network, network.Conn) { n.svc.triggerResume() }

func (n peerNotifiee) Disconnected(network.Network, network.Conn) {}

func (n peerNotifiee) Listen(network.Network, multiaddr.Multiaddr) {}

func (n peerNotifiee) ListenClose(network.Network, multiaddr.Multiaddr) {}

// SetResolver 设置（或替换）对端地址解析器。设置后立即触发一次补发扫描。
func (s *Service) SetResolver(r PeerResolver) {
	s.resolverMu.Lock()
	s.resolver = r
	s.resolverMu.Unlock()
	if r != nil {
		s.triggerResume()
	}
}

func (s *Service) peerResolver() PeerResolver {
	s.resolverMu.RLock()
	defer s.resolverMu.RUnlock()
	return s.resolver
}

// triggerResume 非阻塞地唤醒补发协程。
func (s *Service) triggerResume() {
	select {
	case s.resumeCh <- struct{}{}:
	default:
	}
}

// resumeLoop 周期性扫描离线队列，并在连接事件触发时立即补发。
func (s *Service) resumeLoop() {
	defer s.closeWait.Done()
	ticker := time.NewTicker(s.resumeEvery)
	defer ticker.Stop()

	for {
		select {
		case <-s.stopCh:
			return
		case <-ticker.C:
		case <-s.resumeCh:
		}
		if s.peerResolver() == nil {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), resumePassTimeout)
		_, _ = s.ResumeOutbox(ctx)
		cancel()
	}
}

// ResumeOutbox 对当前已到期的离线队列条目做一次补发。
//
// 每个条目只尝试一次直连投递：成功则出队并把消息置为 sent；对端明确拒收
// 则出队并置为 failed；其余错误（不可达、ACK 非法等）累加重试次数后按
// ResumeRetryDelay 退避，留在队列等待下一轮扫描。
func (s *Service) ResumeOutbox(ctx context.Context) (ResumeReport, error) {
	var rep ResumeReport
	resolver := s.peerResolver()
	if resolver == nil {
		return rep, ErrNoPeerResolver
	}
	if ctx == nil {
		ctx = context.Background()
	}

	now := time.Now().Unix()
	for {
		entries, err := s.dao.ListOutboxDue(ctx, now, resumeBatchSize)
		if err != nil {
			return rep, err
		}
		for _, e := range entries {
			rep.Scanned++
			switch s.resumeEntry(ctx, resolver, e) {
			case resumeDelivered:
				rep.Delivered++
			case resumeDropped:
				rep.Dropped++
			default:
				rep.Retained++
			}
		}
		if len(entries) < resumeBatchSize {
			break
		}
	}
	return rep, nil
}

// resumeOutcome 是单个条目的补发结果。
type resumeOutcome int

const (
	resumeRetained resumeOutcome = iota
	resumeDelivered
	resumeDropped
)

func (s *Service) resumeEntry(ctx context.Context, resolver PeerResolver, e store.OutboxEntry) resumeOutcome {
	frame := &nexmemv1.Frame{}
	if err := proto.Unmarshal(e.Payload, frame); err != nil {
		s.dropOutbox(ctx, e.MsgUUID)
		return resumeDropped
	}

	t, err := resolver.ResolvePeer(ctx, e.PeerAccount)
	if err != nil || t.PeerID == "" {
		// 地址解析不到时仍有机会走离线投递。
		if s.tryOfflineEntry(ctx, e) {
			return resumeDelivered
		}
		s.deferOutbox(ctx, e.MsgUUID)
		return resumeRetained
	}

	if err := s.deliver(ctx, t, frame, e.MsgUUID); err != nil {
		if errors.Is(err, ErrPeerRejected) {
			s.dropOutbox(ctx, e.MsgUUID)
			return resumeDropped
		}
		// 直连仍不可达时改走离线投递（P3-06），成功即出队。
		if s.tryOfflineEntry(ctx, e) {
			return resumeDelivered
		}
		s.deferOutbox(ctx, e.MsgUUID)
		return resumeRetained
	}

	// 已送达：先出队再改状态，重复补发最多多一次 ACK，不会重复入库。
	if err := s.dao.DeleteOutbox(ctx, e.MsgUUID); err != nil && !errors.Is(err, store.ErrNotFound) {
		s.deferOutbox(ctx, e.MsgUUID)
		return resumeRetained
	}
	s.markState(ctx, e.MsgUUID, store.MessageStateSent)
	if msg, err := s.dao.GetMessage(ctx, e.MsgUUID); err == nil {
		_ = s.dao.TouchConversation(ctx, msg.ConversationID, msg.SentAt)
	}
	return resumeDelivered
}

// tryOfflineEntry 把离线队列中的载荷改走离线投递；成功返回 true 并出队。
func (s *Service) tryOfflineEntry(ctx context.Context, e store.OutboxEntry) bool {
	if !s.OfflineEnabled() {
		return false
	}
	frame := &nexmemv1.Frame{}
	if err := proto.Unmarshal(e.Payload, frame); err != nil {
		return false
	}
	inner := &nexmemv1.DirectMessage{}
	if err := proto.Unmarshal(frame.Payload, inner); err != nil {
		return false
	}
	convID := string(inner.GetConversationId())
	if convID == "" {
		convID = ConversationID(s.account.Pub(), inner.GetReceiverAccount())
	}
	if err := s.sendOffline(ctx, inner.GetReceiverAccount(), e.MsgUUID, convID,
		inner.GetTimestamp(), inner.GetContentType(), inner.GetInner()); err != nil {
		return false
	}
	if err := s.dao.DeleteOutbox(ctx, e.MsgUUID); err != nil && !errors.Is(err, store.ErrNotFound) {
		return false
	}
	// 群密钥信封不是聊天消息，不产生投递事件与消息状态。
	if inner.GetContentType() != nexmemv1.ContentType_CONTENT_TYPE_GROUP_META {
		s.markOfflineSent(ctx, e.MsgUUID, convID, inner.GetTimestamp())
	}
	return true
}

// deferOutbox 记录一次失败重试，推迟下次补发时间。
func (s *Service) deferOutbox(ctx context.Context, msgID string) {
	_ = s.dao.UpdateOutboxRetry(ctx, msgID, time.Now().Add(s.resumeDelay).Unix())
}

// dropOutbox 丢弃无法再投递的条目并把消息标记为 failed。
func (s *Service) dropOutbox(ctx context.Context, msgID string) {
	_ = s.dao.DeleteOutbox(ctx, msgID)
	s.markState(ctx, msgID, store.MessageStateFailed)
}
