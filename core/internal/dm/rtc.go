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
	"github.com/nexmem/core/internal/wire"
)

// MaxRTCSignalSize 是单条 RTC 信令载荷上限，与跨通道 64 KiB 约束保持一致。
const MaxRTCSignalSize = 64 * 1024

// RTC 信令语义错误。
var (
	ErrEmptySignal    = errors.New("RTC 信令不能为空")
	ErrSignalTooLarge = errors.New("RTC 信令超过 64 KiB")
)

// RTCSignalEvent 描述一条收到的 RTC 信令，Payload 为客户端不透明字节。
type RTCSignalEvent struct {
	PeerAccount []byte
	Payload     []byte
}

// SendSignal 把一条 RTC 信令透传给在线对端并等待 ACK。
//
// 信令不落库、不重试、不走离线通道：呼叫建立失败由客户端重新协商。
func (s *Service) SendSignal(ctx context.Context, t Target, payload []byte) error {
	switch {
	case len(payload) == 0:
		return ErrEmptySignal
	case len(payload) > MaxRTCSignalSize:
		return ErrSignalTooLarge
	}
	if !validAccountPub(t.AccountPub) {
		return ErrInvalidTarget
	}
	if bytes.Equal(t.AccountPub, s.account.Pub()) {
		return ErrSelfSend
	}
	if blocked, err := s.isBlocked(ctx, t.AccountPub); err != nil {
		return err
	} else if blocked {
		return ErrPeerBlocked
	}
	if t.PeerID == "" {
		return fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached)
	}
	if ctx == nil {
		ctx = context.Background()
	}

	sig := &nexmemv1.RtcSignal{
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		Payload:         payload,
	}
	body, err := proto.Marshal(sig)
	if err != nil {
		return fmt.Errorf("序列化 RTC 信令: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_RTC_SIGNAL,
		Payload: body,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}

	if err := s.connect(ctx, t); err != nil {
		return err
	}
	streamCtx := network.WithAllowLimitedConn(ctx, "nexmem-rtc")
	stream, err := s.host.NewStream(streamCtx, t.PeerID, wire.PIDRTC)
	if err != nil {
		return fmt.Errorf("%w: 打开流: %v", ErrPeerUnreached, err)
	}
	defer stream.Close()

	if err := stream.SetDeadline(time.Now().Add(s.ackTimeout)); err != nil {
		return fmt.Errorf("设置流超时: %w", err)
	}
	if err := wire.WriteFrame(stream, frame); err != nil {
		return fmt.Errorf("发送 RTC 信令: %w", err)
	}
	ackFrame, err := wire.ReadFrame(stream)
	if err != nil {
		return fmt.Errorf("等待 ACK: %w", err)
	}
	if err := wire.VerifyFrame(stream.Conn().RemotePublicKey(), ackFrame); err != nil {
		return fmt.Errorf("%w: %v", ErrAckInvalid, err)
	}
	if ackFrame.Type != nexmemv1.FrameType_FRAME_TYPE_ACK {
		return fmt.Errorf("%w: 帧类型 %s", ErrAckInvalid, ackFrame.Type)
	}
	ack := &nexmemv1.Ack{}
	if err := proto.Unmarshal(ackFrame.Payload, ack); err != nil {
		return fmt.Errorf("%w: 解析 ACK: %v", ErrAckInvalid, err)
	}
	switch ack.Code {
	case AckOK:
		return nil
	case AckReject:
		return ErrPeerRejected
	default:
		return fmt.Errorf("%w: 错误码 %d", ErrAckInvalid, ack.Code)
	}
}

// handleRTCStream 处理一条入站 RTC 信令流：验签、校验身份后回调上层并回 ACK。
func (s *Service) handleRTCStream(st network.Stream) {
	defer st.Close()
	_ = st.SetDeadline(time.Now().Add(streamTimeout))

	frame, err := wire.ReadFrame(st)
	if err != nil {
		return
	}
	if frame.Version != wire.Version || frame.Type != nexmemv1.FrameType_FRAME_TYPE_RTC_SIGNAL {
		s.writeAck(st, "", AckReject)
		return
	}
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}
	sig := &nexmemv1.RtcSignal{}
	if err := proto.Unmarshal(frame.Payload, sig); err != nil {
		s.writeAck(st, "", AckReject)
		return
	}
	if !s.validSignal(sig) {
		s.writeAck(st, "", AckReject)
		return
	}
	if s.onRTCSignal != nil {
		// 拷贝载荷，避免回调方持有帧内切片。
		payload := append([]byte(nil), sig.GetPayload()...)
		s.onRTCSignal(RTCSignalEvent{
			PeerAccount: sig.GetSenderAccount(),
			Payload:     payload,
		})
	}
	s.writeAck(st, "", AckOK)
}

// validSignal 校验 RTC 信令的收发方身份与载荷边界，防止串号与超大载荷。
func (s *Service) validSignal(sig *nexmemv1.RtcSignal) bool {
	if sig == nil {
		return false
	}
	if !validAccountPub(sig.GetSenderAccount()) || !validAccountPub(sig.GetReceiverAccount()) {
		return false
	}
	if !bytes.Equal(sig.GetReceiverAccount(), s.account.Pub()) {
		return false
	}
	if bytes.Equal(sig.GetSenderAccount(), s.account.Pub()) {
		return false
	}
	n := len(sig.GetPayload())
	return n > 0 && n <= MaxRTCSignalSize
}
