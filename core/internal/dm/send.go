package dm

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/expiry"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

// SendText 向对端发送一条文本消息，等待应用层 ACK 后返回消息 UUID。
//
// 消息在发送前已写入本地库（pending），按 DefaultAckTimeout 重试至多
// DefaultMaxAttempts 次；收到 ACK 置为 sent，全部失败置为 failed 并写入离线队列。
// 即便返回错误，msg_uuid 也可能非空，调用方可用它做重试去重。
func (s *Service) SendText(ctx context.Context, t Target, text, replyTo string) (string, error) {
	return s.SendTextWithMentions(ctx, t, text, replyTo, nil)
}

// SendTextWithMentions 与 SendText 相同，但在 InnerMessage 中携带被 @ 的成员账号
// 列表（七-1）。mentions 随正文一起加密传输与入库，接收端原样解出供 UI 高亮。
func (s *Service) SendTextWithMentions(ctx context.Context, t Target, text, replyTo string, mentions []string) (string, error) {
	return s.SendTextWithOptions(ctx, t, text, replyTo, mentions, 0)
}

// SendTextWithOptions 是单聊文本发送的完整入口：mentions 供 @ 高亮，ttlHours 为
// 定时消息存活小时数（0 表示永不过期，1～168 合法）。ttl 随加密正文到达双方，
// 双方各自按 sent_at + ttl 计算本机销毁时间（推荐功能：定时消息）。
func (s *Service) SendTextWithOptions(ctx context.Context, t Target, text, replyTo string, mentions []string, ttlHours uint32) (string, error) {
	if err := expiry.Validate(ttlHours); err != nil {
		return "", err
	}
	if text == "" {
		return "", ErrEmptyText
	}
	if !validAccountPub(t.AccountPub) {
		return "", ErrInvalidTarget
	}
	if bytes.Equal(t.AccountPub, s.account.Pub()) {
		return "", ErrSelfSend
	}
	if blocked, err := s.isBlocked(ctx, t.AccountPub); err != nil {
		return "", err
	} else if blocked {
		return "", ErrPeerBlocked
	}
	if t.PeerID == "" && !s.OfflineEnabled() {
		return "", fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached)
	}
	if ctx == nil {
		ctx = context.Background()
	}

	s.sendMu.Lock()
	defer s.sendMu.Unlock()

	convID := ConversationID(s.account.Pub(), t.AccountPub)
	ts := s.nextTimestamp()
	msgID, err := newUUIDv7(ts)
	if err != nil {
		return "", err
	}

	inner, err := proto.Marshal(&nexmemv1.InnerMessage{
		Text: text, ReplyTo: replyTo, Mentions: mentions, TtlHours: ttlHours,
	})
	if err != nil {
		return msgID, fmt.Errorf("序列化消息正文: %w", err)
	}
	payload, err := proto.Marshal(&nexmemv1.DirectMessage{
		MsgUuid:         msgID,
		Timestamp:       ts,
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		ConversationId:  []byte(convID),
		ContentType:     nexmemv1.ContentType_CONTENT_TYPE_TEXT,
		Inner:           inner,
	})
	if err != nil {
		return msgID, fmt.Errorf("序列化单聊消息: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_MSG,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return msgID, err
	}

	if err := s.dao.EnsureConversation(ctx, store.Conversation{
		ID:   convID,
		Kind: store.ConversationKindDM,
	}); err != nil {
		return msgID, err
	}
	if err := s.dao.PutMessage(ctx, store.Message{
		MsgUUID:        msgID,
		ConversationID: convID,
		SenderAccount:  s.account.Pub(),
		SentAt:         ts,
		Direction:      store.DirectionOut,
		ContentType:    int(nexmemv1.ContentType_CONTENT_TYPE_TEXT),
		BodyEnc:        inner,
		State:          store.MessageStatePending,
		Raw:            payload,
		ExpiresAt:      expiry.ExpiresAt(ts, ttlHours),
		Body:           text,
	}); err != nil {
		return msgID, err
	}

	directErr := error(fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached))
	if t.PeerID != "" {
		directErr = s.deliverWithRetry(ctx, t, frame, msgID)
	}
	if directErr != nil {
		if errors.Is(directErr, ErrPeerRejected) {
			s.markState(ctx, msgID, store.MessageStateFailed)
			return msgID, directErr
		}
		// 直连不可达：走离线投递链路上传密文（P3-06）。
		if s.OfflineEnabled() {
			oerr := s.sendOffline(ctx, t.AccountPub, msgID, convID, ts,
				nexmemv1.ContentType_CONTENT_TYPE_TEXT, inner)
			if oerr == nil {
				s.markOfflineSent(ctx, msgID, convID, ts)
				return msgID, nil
			}
			directErr = fmt.Errorf("%w（离线投递失败: %w）", directErr, oerr)
		}
		// 对端关闭离线存储属于确定性失败：标出原因码，UI 常驻「仅支持在线发送」提示。
		reason := ""
		if errors.Is(directErr, ErrOfflineDisabled) {
			reason = ReasonOfflineStorageDisabled
		}
		s.markStateReason(ctx, msgID, store.MessageStateFailed, reason)
		if qerr := s.enqueueOutbox(ctx, t, frame, msgID); qerr != nil {
			return msgID, fmt.Errorf("%w（写入离线队列失败: %v）", directErr, qerr)
		}
		return msgID, directErr
	}

	s.markState(ctx, msgID, store.MessageStateSent)
	if err := s.dao.TouchConversation(ctx, convID, ts); err != nil {
		return msgID, err
	}
	return msgID, nil
}

// deliver 建立连接、发送一帧并校验 ACK。
func (s *Service) deliver(ctx context.Context, t Target, frame *nexmemv1.Frame, msgID string) error {
	if err := s.connect(ctx, t); err != nil {
		return err
	}

	streamCtx := network.WithAllowLimitedConn(ctx, "nexmem-dm")
	stream, err := s.host.NewStream(streamCtx, t.PeerID, wire.PIDDM)
	if err != nil {
		return fmt.Errorf("%w: 打开流: %v", ErrPeerUnreached, err)
	}
	defer stream.Close()

	if err := stream.SetDeadline(time.Now().Add(s.ackTimeout)); err != nil {
		return fmt.Errorf("设置流超时: %w", err)
	}
	if err := wire.WriteFrame(stream, frame); err != nil {
		return fmt.Errorf("发送消息: %w", err)
	}

	ackFrame, err := wire.ReadFrame(stream)
	if err != nil {
		return fmt.Errorf("等待 ACK: %w", err)
	}
	remotePub := stream.Conn().RemotePublicKey()
	if err := wire.VerifyFrame(remotePub, ackFrame); err != nil {
		return fmt.Errorf("%w: %v", ErrAckInvalid, err)
	}
	if ackFrame.Type != nexmemv1.FrameType_FRAME_TYPE_ACK {
		return fmt.Errorf("%w: 帧类型 %s", ErrAckInvalid, ackFrame.Type)
	}
	ack := &nexmemv1.Ack{}
	if err := proto.Unmarshal(ackFrame.Payload, ack); err != nil {
		return fmt.Errorf("%w: 解析 ACK: %v", ErrAckInvalid, err)
	}
	if msgID != "" && ack.MsgUuid != msgID {
		return fmt.Errorf("%w: ACK 消息 ID 不匹配", ErrAckInvalid)
	}
	switch ack.Code {
	case AckOK, AckDup:
		return nil
	case AckReject:
		return ErrPeerRejected
	default:
		return fmt.Errorf("%w: 错误码 %d", ErrAckInvalid, ack.Code)
	}
}

func (s *Service) connect(ctx context.Context, t Target) error {
	if s.host.Network().Connectedness(t.PeerID) == network.Connected {
		return nil
	}
	if len(t.Addrs) == 0 {
		return fmt.Errorf("%w: 未提供对端地址", ErrPeerUnreached)
	}
	if err := s.host.Connect(ctx, peer.AddrInfo{ID: t.PeerID, Addrs: t.Addrs}); err != nil {
		return fmt.Errorf("%w: %v", ErrPeerUnreached, err)
	}
	return nil
}

func (s *Service) markState(ctx context.Context, msgID string, state int) {
	s.markStateDetail(ctx, msgID, "", state, false, "")
}

// markStateReason 更新消息状态并附带失败原因码，用于让 UI 展示确定性降级提示。
func (s *Service) markStateReason(ctx context.Context, msgID string, state int, reason string) {
	s.markStateDetail(ctx, msgID, "", state, false, reason)
}

// markStateDetail 更新消息状态并上报投递事件；convID 为空时回查消息补齐。
func (s *Service) markStateDetail(ctx context.Context, msgID, convID string, state int, offline bool, reason string) {
	if err := s.dao.UpdateMessageState(ctx, msgID, state); err != nil {
		return
	}
	if s.onDelivery == nil {
		return
	}
	if convID == "" {
		msg, err := s.dao.GetMessage(ctx, msgID)
		if err != nil {
			return
		}
		convID = msg.ConversationID
	}
	s.emitDelivery(DeliveryEvent{
		MsgUUID:        msgID,
		ConversationID: convID,
		State:          state,
		Offline:        offline,
		Reason:         reason,
	})
}
