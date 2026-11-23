package dm

import (
	"bytes"
	"context"
	"fmt"
	"time"

	"github.com/libp2p/go-libp2p/core/network"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/wire"
)

// editMaxFuture 允许编辑时间戳不超过本机时间的安全余量。
const editMaxFuture = 5 * time.Minute

// EditEvent 描述对端编辑通知，供上层更新本机消息并发出 message.edited（七-2）。
type EditEvent struct {
	PeerAccount    []byte
	ConversationID string
	MsgUUID        string
	Text           string
	EditedAt       int64
}

// SendEdit 通知对端一条已发出消息的新正文（七-2）。
//
// 编辑是尽力而为的在线能力：对端不可达时不入离线队列、不重试，
// 只返回错误供调用方记录；本机消息由调用方在调用前更新。
func (s *Service) SendEdit(ctx context.Context, t Target, msgUUID, text string, editedAt int64) error {
	if msgUUID == "" || text == "" {
		return fmt.Errorf("编辑通知缺少 msg_uuid 或正文")
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

	payload, err := proto.Marshal(&nexmemv1.EditNotice{
		MsgUuid:         msgUUID,
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		ConversationId:  []byte(ConversationID(s.account.Pub(), t.AccountPub)),
		Text:            text,
		EditedAt:        editedAt,
	})
	if err != nil {
		return fmt.Errorf("序列化编辑通知: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_EDIT,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}
	return s.deliver(ctx, t, frame, "")
}

// validEditNotice 校验编辑通知与本机身份一致，并拒绝空正文与未来时间戳。
func (s *Service) validEditNotice(notice *nexmemv1.EditNotice) bool {
	if notice == nil || notice.GetMsgUuid() == "" || notice.GetText() == "" || notice.GetEditedAt() <= 0 {
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
	return notice.GetEditedAt() <= time.Now().Add(editMaxFuture).UnixMilli()
}

// handleEditFrame 校验并处理对端编辑通知：更新本机消息后回调上层发事件。
func (s *Service) handleEditFrame(st network.Stream, frame *nexmemv1.Frame) {
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}
	notice := &nexmemv1.EditNotice{}
	if err := proto.Unmarshal(frame.Payload, notice); err != nil {
		s.writeAck(st, "", AckReject)
		return
	}
	if !s.validEditNotice(notice) {
		s.writeAck(st, "", AckReject)
		return
	}
	if s.onEdit != nil {
		s.onEdit(EditEvent{
			PeerAccount:    notice.GetSenderAccount(),
			ConversationID: string(notice.GetConversationId()),
			MsgUUID:        notice.GetMsgUuid(),
			Text:           notice.GetText(),
			EditedAt:       notice.GetEditedAt(),
		})
	}
	s.writeAck(st, "", AckOK)
}
