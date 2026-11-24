package dm

import (
	"context"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/expiry"
	"github.com/nexmem/core/internal/store"
)

const (
	// replayTTL 是内存重放缓存的保留时长，覆盖直连重试、重连补发与短暂断网的常见窗口。
	replayTTL = 10 * time.Minute
	// replayCapacity 限制缓存条目数，避免长时间运行时内存无界增长。
	replayCapacity = 4096
)

// replayEntry 是重放缓存中的一个消息 ID 及其受理时间。
type replayEntry struct {
	id string
	at time.Time
}

// replayGuard 记录最近受理过的入站消息 ID。
//
// 数据库主键已能对未删除的消息去重；这里再加一层内存窗口，用于：
//  1. 重复帧在落库前直接短路，省掉一次事务；
//  2. 即便本地消息被清理，同一帧的再次投递（重放）仍会被拒绝。
type replayGuard struct {
	mu       sync.Mutex
	ttl      time.Duration
	capacity int
	order    []replayEntry
	seen     map[string]time.Time
}

func newReplayGuard(ttl time.Duration, capacity int) *replayGuard {
	if ttl <= 0 {
		ttl = replayTTL
	}
	if capacity <= 0 {
		capacity = replayCapacity
	}
	return &replayGuard{
		ttl:      ttl,
		capacity: capacity,
		seen:     make(map[string]time.Time),
	}
}

// check 判断 msg_uuid 是否仍在防重放窗口内。
func (g *replayGuard) check(id string) bool {
	if id == "" {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.pruneLocked(time.Now())
	_, ok := g.seen[id]
	return ok
}

// mark 记录一条已受理消息；超出容量时按受理时间淘汰最旧条目。
func (g *replayGuard) mark(id string) {
	if id == "" {
		return
	}
	now := time.Now()
	g.mu.Lock()
	defer g.mu.Unlock()
	g.pruneLocked(now)
	if _, ok := g.seen[id]; ok {
		return
	}
	g.seen[id] = now
	g.order = append(g.order, replayEntry{id: id, at: now})
	for len(g.order) > g.capacity {
		old := g.order[0]
		g.order = g.order[1:]
		if at, ok := g.seen[old.id]; ok && at.Equal(old.at) {
			delete(g.seen, old.id)
		}
	}
}

// pruneLocked 丢弃过期条目，调用方必须持有锁。
func (g *replayGuard) pruneLocked(now time.Time) {
	cutoff := now.Add(-g.ttl)
	i := 0
	for ; i < len(g.order); i++ {
		e := g.order[i]
		if e.at.After(cutoff) {
			break
		}
		if at, ok := g.seen[e.id]; ok && at.Equal(e.at) {
			delete(g.seen, e.id)
		}
	}
	if i > 0 {
		g.order = append(g.order[:0], g.order[i:]...)
	}
}

// acceptInbound 是入站消息的唯一落库入口。
//
// 顺序：重放窗口短路 → 数据库事务内幂等入库（同时创建会话、推进时间、未读 +1）。
// 群密钥信封（P4-08）不写消息表，交给专门的回调处理。
// 返回 AckDup 表示重复投递（或重放），不会重复计数。
func (s *Service) acceptInbound(ctx context.Context, msg *nexmemv1.DirectMessage, payload []byte) int32 {
	// 拉黑后本机拒绝受理该账号的一切入站单聊流量（P2-06）。
	if blocked, err := s.isBlocked(ctx, msg.GetSenderAccount()); err != nil || blocked {
		return AckReject
	}
	if s.replay.check(msg.GetMsgUuid()) {
		return AckDup
	}
	if msg.GetContentType() == nexmemv1.ContentType_CONTENT_TYPE_GROUP_META {
		return s.acceptGroupMeta(msg)
	}
	// 社交控制帧在落库前拦截：不产生聊天气泡，交给上层处理业务。
	if msg.GetContentType() == nexmemv1.ContentType_CONTENT_TYPE_TEXT && s.onControlText != nil {
		if text := searchableText(msg); text != "" && s.onControlText(ctx, msg.GetSenderAccount(), text) {
			s.replay.mark(msg.GetMsgUuid())
			return AckOK
		}
	}

	convID := ConversationID(s.account.Pub(), msg.GetSenderAccount())
	inserted, err := s.dao.AcceptInboundMessage(ctx, store.ConversationKindDM, store.Message{
		MsgUUID:        msg.GetMsgUuid(),
		ConversationID: convID,
		SenderAccount:  msg.GetSenderAccount(),
		SentAt:         msg.GetTimestamp(),
		Direction:      store.DirectionIn,
		ContentType:    int(msg.GetContentType()),
		BodyEnc:        msg.GetInner(),
		State:          store.MessageStateReceived,
		Raw:            payload,
		ExpiresAt:      inboundExpiry(msg),
		Body:           searchableText(msg),
	})
	if err != nil {
		return AckReject
	}
	if !inserted {
		s.replay.mark(msg.GetMsgUuid())
		return AckDup
	}
	s.replay.mark(msg.GetMsgUuid())
	if s.onMessage != nil {
		s.onMessage(InboundEvent{
			ConversationID: convID,
			MsgUUID:        msg.GetMsgUuid(),
			ContentType:    int(msg.GetContentType()),
		})
	}
	return AckOK
}

// inboundExpiry 从入站正文 InnerMessage.ttl_hours 计算本机销毁时间；
// 正文无法解析或 TTL 越界时按永不过期处理（攻击者篡改的 TTL 不影响本机）。
func inboundExpiry(msg *nexmemv1.DirectMessage) int64 {
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(msg.GetInner(), inner); err != nil {
		return 0
	}
	hours := inner.GetTtlHours()
	if expiry.Validate(hours) != nil {
		return 0
	}
	return expiry.ExpiresAt(msg.GetTimestamp(), hours)
}

// searchableText 从入站消息中提取可检索纯文本：文本消息取正文，文件消息取文件名，
// 其余类型（如群密钥信封）不入全文索引。
func searchableText(msg *nexmemv1.DirectMessage) string {
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(msg.GetInner(), inner); err != nil {
		return ""
	}
	switch msg.GetContentType() {
	case nexmemv1.ContentType_CONTENT_TYPE_TEXT:
		return inner.GetText()
	case nexmemv1.ContentType_CONTENT_TYPE_FILE:
		if len(inner.GetAttachments()) == 1 {
			return inner.GetAttachments()[0].GetName()
		}
	}
	return ""
}
