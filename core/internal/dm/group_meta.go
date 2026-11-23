package dm

// 群密钥信封经单聊通道投递（P4-08）。
//
// 群密钥原本只走 /nexmem/group-meta/1.0.0 直连流，对端离线时无法入群。
// 这里把信封塞进单聊链路的 InnerMessage，复用应用层 ACK、重试、离线票据
// 上传与接收端拉取，使被邀请的成员离线也能在下次上线时完成入群。
//
// 群密钥信封不是聊天消息：收发两端都不写消息表，会话列表与未读数不受影响。

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/wire"
)

// ErrGroupMetaInvalid 表示群密钥信封非法或与投递目标不一致。
var ErrGroupMetaInvalid = errors.New("群密钥信封非法")

// GroupMetaHook 在接收端处理一条群密钥信封；返回错误时回 ACK 拒收。
type GroupMetaHook func(env *nexmemv1.GroupKeyEnvelope) error

// SendGroupMeta 经单聊通道把群密钥信封投递给一个成员。
//
// 优先直连投递并等待应用层 ACK；对端不可达且本机配置了离线投递时，
// 改为加密上传到对端收件箱；仍然失败则写入离线队列等待补发。
// 返回 nil 表示已送达、已上传离线对象或已进入补发队列。
// 本方法不写消息表，消息 UUID 仅用于 ACK 与去重。
func (s *Service) SendGroupMeta(ctx context.Context, accountPub []byte, peerID peer.ID, addrs []multiaddr.Multiaddr, env *nexmemv1.GroupKeyEnvelope) error {
	return s.SendGroupMetaTo(ctx, Target{PeerID: peerID, Addrs: addrs, AccountPub: accountPub}, env)
}

// SendGroupMetaTo 是 SendGroupMeta 的目标结构版本。
func (s *Service) SendGroupMetaTo(ctx context.Context, t Target, env *nexmemv1.GroupKeyEnvelope) error {
	if env == nil {
		return ErrGroupMetaInvalid
	}
	if !validAccountPub(t.AccountPub) {
		return ErrInvalidTarget
	}
	if !bytes.Equal(env.GetMemberAccount(), t.AccountPub) {
		return fmt.Errorf("%w: 信封接收方与目标不一致", ErrGroupMetaInvalid)
	}
	if bytes.Equal(t.AccountPub, s.account.Pub()) {
		return ErrSelfSend
	}
	if t.PeerID == "" && !s.OfflineEnabled() {
		return fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached)
	}
	if ctx == nil {
		ctx = context.Background()
	}

	rawEnv, err := proto.Marshal(env)
	if err != nil {
		return fmt.Errorf("序列化群密钥信封: %w", err)
	}
	inner, err := proto.Marshal(&nexmemv1.InnerMessage{GroupKeyEnvelope: rawEnv})
	if err != nil {
		return fmt.Errorf("序列化群密钥正文: %w", err)
	}

	// 发送侧串行，保持与文本消息一致的时间单调性。
	s.sendMu.Lock()
	defer s.sendMu.Unlock()

	convID := ConversationID(s.account.Pub(), t.AccountPub)
	ts := s.nextTimestamp()
	msgID, err := newUUIDv7(ts)
	if err != nil {
		return err
	}
	payload, err := proto.Marshal(&nexmemv1.DirectMessage{
		MsgUuid:         msgID,
		Timestamp:       ts,
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		ConversationId:  []byte(convID),
		ContentType:     nexmemv1.ContentType_CONTENT_TYPE_GROUP_META,
		Inner:           inner,
	})
	if err != nil {
		return fmt.Errorf("序列化群密钥消息: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_MSG,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}

	directErr := error(fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached))
	if t.PeerID != "" {
		directErr = s.deliverWithRetry(ctx, t, frame, msgID)
	}
	if directErr == nil {
		return nil
	}
	if errors.Is(directErr, ErrPeerRejected) {
		return directErr
	}
	if s.OfflineEnabled() {
		if oerr := s.sendOffline(ctx, t.AccountPub, msgID, convID, ts,
			nexmemv1.ContentType_CONTENT_TYPE_GROUP_META, inner); oerr == nil {
			return nil
		} else {
			directErr = fmt.Errorf("%w（离线投递失败: %w）", directErr, oerr)
		}
	}
	if qerr := s.enqueueOutbox(ctx, t, frame, msgID); qerr != nil {
		return fmt.Errorf("%w（写入离线队列失败: %v）", directErr, qerr)
	}
	// 已进入补发队列，等对端上线后由 ResumeOutbox 继续投递。
	return nil
}

// acceptGroupMeta 受理一条入站群密钥信封：交给回调验签解封，成功后记入重放窗口。
// 不写消息表，因此不会创建会话或增加未读数。
func (s *Service) acceptGroupMeta(msg *nexmemv1.DirectMessage) int32 {
	if s.onGroupMeta == nil {
		return AckReject
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(msg.GetInner(), inner); err != nil {
		return AckReject
	}
	env := &nexmemv1.GroupKeyEnvelope{}
	if err := proto.Unmarshal(inner.GetGroupKeyEnvelope(), env); err != nil {
		return AckReject
	}
	if !bytes.Equal(env.GetMemberAccount(), s.account.Pub()) {
		return AckReject
	}
	if err := s.onGroupMeta(env); err != nil {
		return AckReject
	}
	s.replay.mark(msg.GetMsgUuid())
	return AckOK
}
