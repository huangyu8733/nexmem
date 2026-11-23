package dm

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/libp2p/go-libp2p/core/network"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

// RecallMaxAge 是撤回的有效期：只允许撤回 2 分钟内发出的消息。
const RecallMaxAge = 2 * time.Minute

// recallMaxFuture 允许撤回时间戳不超过本机时间的安全余量。
const recallMaxFuture = 5 * time.Minute

// RecallEvent 描述一条对端撤回通知，供上层发出 message.recalled 事件。
type RecallEvent struct {
	PeerAccount    []byte
	ConversationID string
	MsgUUID        string
}

// SendRecall 通知对端撤回一条已发送的消息（P6-12）。
//
// 撤回是尽力而为的在线能力：对端不可达时不入离线队列、不重试，
// 只返回错误供调用方记录；本地消息由调用方在调用前删除。
func (s *Service) SendRecall(ctx context.Context, t Target, msgUUID string) error {
	if msgUUID == "" {
		return fmt.Errorf("撤回缺少 msg_uuid")
	}
	if !validAccountPub(t.AccountPub) {
		return ErrInvalidTarget
	}
	if bytes.Equal(t.AccountPub, s.account.Pub()) {
		return ErrSelfSend
	}
	if t.PeerID == "" {
		return fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if blocked, err := s.isBlocked(ctx, t.AccountPub); err != nil {
		return err
	} else if blocked {
		return ErrPeerBlocked
	}

	payload, err := proto.Marshal(&nexmemv1.RecallNotice{
		MsgUuid:         msgUUID,
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		ConversationId:  []byte(ConversationID(s.account.Pub(), t.AccountPub)),
		RecalledAt:      time.Now().UnixMilli(),
	})
	if err != nil {
		return fmt.Errorf("序列化撤回通知: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_RECALL,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}
	return s.deliver(ctx, t, frame, "")
}

// handleRecallFrame 校验并处理对端撤回通知：删除本机消息后回调上层发事件。
func (s *Service) handleRecallFrame(st network.Stream, frame *nexmemv1.Frame) {
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}
	notice := &nexmemv1.RecallNotice{}
	if err := proto.Unmarshal(frame.Payload, notice); err != nil {
		s.writeAck(st, "", AckReject)
		return
	}
	if !s.validRecallNotice(notice) {
		s.writeAck(st, "", AckReject)
		return
	}
	err := s.dao.DeleteMessage(context.Background(), notice.GetMsgUuid())
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.writeAck(st, "", AckReject)
		return
	}
	if s.onRecall != nil {
		s.onRecall(RecallEvent{
			PeerAccount:    notice.GetSenderAccount(),
			ConversationID: string(notice.GetConversationId()),
			MsgUUID:        notice.GetMsgUuid(),
		})
	}
	s.writeAck(st, "", AckOK)
}

// validRecallNotice 校验撤回通知与本机身份一致，并拒绝未来时间戳。
func (s *Service) validRecallNotice(notice *nexmemv1.RecallNotice) bool {
	if notice == nil || notice.GetMsgUuid() == "" || notice.GetRecalledAt() <= 0 {
		return false
	}
	if !validAccountPub(notice.GetSenderAccount()) || !validAccountPub(notice.GetReceiverAccount()) {
		return false
	}
	if !bytes.Equal(notice.GetReceiverAccount(), s.account.Pub()) {
		return false
	}
	if bytes.Equal(notice.GetSenderAccount(), s.account.Pub()) {
		return false
	}
	if !bytes.Equal(notice.GetConversationId(),
		[]byte(ConversationID(s.account.Pub(), notice.GetSenderAccount()))) {
		return false
	}
	return notice.GetRecalledAt() <= time.Now().Add(recallMaxFuture).UnixMilli()
}
