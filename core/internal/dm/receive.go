package dm

import (
	"bytes"
	"context"
	"crypto/sha256"
	"time"

	"github.com/libp2p/go-libp2p/core/network"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/wire"
)

// handleStream 处理一条入站单聊流：按帧类型分别处理 MSG 与 READ，并回一帧 ACK。
func (s *Service) handleStream(st network.Stream) {
	defer st.Close()
	_ = st.SetDeadline(time.Now().Add(streamTimeout))

	frame, err := wire.ReadFrame(st)
	if err != nil {
		return
	}
	if frame.Version != wire.Version {
		s.writeAck(st, "", AckReject)
		return
	}
	switch frame.Type {
	case nexmemv1.FrameType_FRAME_TYPE_MSG:
		s.handleMessageFrame(st, frame)
	case nexmemv1.FrameType_FRAME_TYPE_READ:
		s.handleReadFrame(st, frame)
	case nexmemv1.FrameType_FRAME_TYPE_RECALL:
		s.handleRecallFrame(st, frame)
	case nexmemv1.FrameType_FRAME_TYPE_TYPING:
		s.handleTypingFrame(st, frame)
	case nexmemv1.FrameType_FRAME_TYPE_EDIT:
		s.handleEditFrame(st, frame)
	default:
		s.writeAck(st, "", AckReject)
	}
}

// handleMessageFrame 校验并入库一条单聊消息（P1-11）。
func (s *Service) handleMessageFrame(st network.Stream, frame *nexmemv1.Frame) {
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}

	msg := &nexmemv1.DirectMessage{}
	if err := proto.Unmarshal(frame.Payload, msg); err != nil {
		s.writeAck(st, "", AckReject)
		return
	}

	if !s.validMessage(msg) {
		s.writeAck(st, msg.GetMsgUuid(), AckReject)
		return
	}
	code := s.acceptInbound(context.Background(), msg, frame.Payload)
	s.writeAck(st, msg.GetMsgUuid(), code)
}

// handleReadFrame 校验并处理对端已读回执（P6-07）；回执尽力而为，不接受离线补发。
func (s *Service) handleReadFrame(st network.Stream, frame *nexmemv1.Frame) {
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}
	rc := &nexmemv1.ReadReceipt{}
	if err := proto.Unmarshal(frame.Payload, rc); err != nil {
		s.writeAck(st, "", AckReject)
		return
	}
	if !s.validReadReceipt(rc) {
		s.writeAck(st, "", AckReject)
		return
	}
	if s.onRead != nil {
		s.onRead(ReadEvent{
			PeerAccount:    rc.GetSenderAccount(),
			ConversationID: string(rc.GetConversationId()),
			UpTo:           rc.GetUpToTimestamp(),
		})
	}
	s.writeAck(st, "", AckOK)
}

// validReadReceipt 校验已读回执与本机身份一致，并拒绝未来时间水位。
func (s *Service) validReadReceipt(rc *nexmemv1.ReadReceipt) bool {
	if rc == nil || rc.GetUpToTimestamp() <= 0 {
		return false
	}
	if !validAccountPub(rc.GetSenderAccount()) || !validAccountPub(rc.GetReceiverAccount()) {
		return false
	}
	if !bytes.Equal(rc.GetReceiverAccount(), s.account.Pub()) {
		return false
	}
	if bytes.Equal(rc.GetSenderAccount(), s.account.Pub()) {
		return false
	}
	if !bytes.Equal(rc.GetConversationId(), []byte(ConversationID(s.account.Pub(), rc.GetSenderAccount()))) {
		return false
	}
	return rc.GetUpToTimestamp() <= time.Now().Add(readReceiptMaxFuture).UnixMilli()
}

// validMessage 校验消息与本地身份的一致性，防止伪造或串号。
func (s *Service) validMessage(msg *nexmemv1.DirectMessage) bool {
	if msg == nil || msg.MsgUuid == "" || len(msg.Inner) == 0 {
		return false
	}
	if !validAccountPub(msg.SenderAccount) || !validAccountPub(msg.ReceiverAccount) {
		return false
	}
	if !bytes.Equal(msg.ReceiverAccount, s.account.Pub()) {
		return false
	}
	if bytes.Equal(msg.SenderAccount, s.account.Pub()) {
		return false
	}
	if !bytes.Equal(msg.ConversationId, []byte(ConversationID(s.account.Pub(), msg.SenderAccount))) {
		return false
	}
	if msg.ContentType != nexmemv1.ContentType_CONTENT_TYPE_TEXT &&
		msg.ContentType != nexmemv1.ContentType_CONTENT_TYPE_FILE &&
		msg.ContentType != nexmemv1.ContentType_CONTENT_TYPE_GROUP_META {
		return false
	}
	skew := time.Since(time.UnixMilli(msg.Timestamp))
	if skew > maxClockSkew || skew < -maxClockSkew {
		return false
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(msg.Inner, inner); err != nil {
		return false
	}
	switch msg.ContentType {
	case nexmemv1.ContentType_CONTENT_TYPE_FILE:
		return validFileAttachment(inner)
	case nexmemv1.ContentType_CONTENT_TYPE_GROUP_META:
		return validGroupMeta(inner)
	default:
		return inner.GetText() != ""
	}
}

// validGroupMeta 校验群密钥信封消息：正文必须携带非空信封字节。
func validGroupMeta(inner *nexmemv1.InnerMessage) bool {
	return inner != nil && len(inner.GetGroupKeyEnvelope()) > 0
}

// validFileAttachment 校验文件消息的附件元数据，避免接收端按非法参数落盘。
func validFileAttachment(inner *nexmemv1.InnerMessage) bool {
	if inner == nil || len(inner.Attachments) != 1 {
		return false
	}
	att := inner.Attachments[0]
	if att.GetName() == "" || att.GetSize() == 0 {
		return false
	}
	if len(att.GetKey()) != crypto.FileKeySize || len(att.GetSha256()) != sha256.Size {
		return false
	}
	return true
}

func (s *Service) writeAck(st network.Stream, msgID string, code int32) {
	payload, err := proto.Marshal(&nexmemv1.Ack{
		MsgUuid: msgID,
		Code:    code,
		At:      time.Now().UnixMilli(),
	})
	if err != nil {
		return
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_ACK,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return
	}
	_ = wire.WriteFrame(st, frame)
}
