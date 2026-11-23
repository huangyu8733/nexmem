package dm

import (
	"bytes"
	"context"
	"fmt"

	"github.com/libp2p/go-libp2p/core/network"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/wire"
)

// TypingEvent 描述对端输入状态变化，供上层发出 typing 事件（七-3）。
type TypingEvent struct {
	PeerAccount    []byte
	ConversationID string
	Typing         bool
}

// SendTyping 向对端发送输入状态（七-3）。
//
// typing 是瞬时状态：不落库、不入离线队列、不重试、不等 ACK，
// 对端不可达时静默返回错误由调用方忽略。
func (s *Service) SendTyping(ctx context.Context, t Target, typing bool) error {
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

	payload, err := proto.Marshal(&nexmemv1.TypingNotice{
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		ConversationId:  []byte(ConversationID(s.account.Pub(), t.AccountPub)),
		Typing:          typing,
	})
	if err != nil {
		return fmt.Errorf("序列化输入状态: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_TYPING,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}
	return s.deliver(ctx, t, frame, "")
}

// validTypingNotice 校验输入状态通知与本机身份一致。
func (s *Service) validTypingNotice(notice *nexmemv1.TypingNotice) bool {
	if notice == nil {
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
	return bytes.Equal(notice.GetConversationId(),
		[]byte(ConversationID(s.account.Pub(), notice.GetSenderAccount())))
}

// handleTypingFrame 校验并转发对端输入状态。
func (s *Service) handleTypingFrame(st network.Stream, frame *nexmemv1.Frame) {
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}
	notice := &nexmemv1.TypingNotice{}
	if err := proto.Unmarshal(frame.Payload, notice); err != nil {
		s.writeAck(st, "", AckReject)
		return
	}
	if !s.validTypingNotice(notice) {
		s.writeAck(st, "", AckReject)
		return
	}
	if s.onTyping != nil {
		s.onTyping(TypingEvent{
			PeerAccount:    notice.GetSenderAccount(),
			ConversationID: string(notice.GetConversationId()),
			Typing:         notice.GetTyping(),
		})
	}
	s.writeAck(st, "", AckOK)
}
