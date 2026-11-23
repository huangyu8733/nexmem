package dm

import (
	"bytes"
	"context"
	"fmt"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/wire"
)

// SendReadReceipt 把本机对单聊会话的已读位置回传给对端（P6-07）。
//
// 回执是尽力而为的在线能力：对端不可达时不入离线队列、不重试，
// 只返回错误供上层记录；已读位置以时间戳水位表达，对端据此把水位之前的出站消息置为已读。
func (s *Service) SendReadReceipt(ctx context.Context, t Target, upTo int64) error {
	if !validAccountPub(t.AccountPub) {
		return ErrInvalidTarget
	}
	if bytes.Equal(t.AccountPub, s.account.Pub()) {
		return ErrSelfSend
	}
	if upTo <= 0 {
		return fmt.Errorf("已读位置非法: %d", upTo)
	}
	if upTo > time.Now().Add(readReceiptMaxFuture).UnixMilli() {
		return fmt.Errorf("已读位置超前: %d", upTo)
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

	payload, err := proto.Marshal(&nexmemv1.ReadReceipt{
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		ConversationId:  []byte(ConversationID(s.account.Pub(), t.AccountPub)),
		UpToTimestamp:   upTo,
	})
	if err != nil {
		return fmt.Errorf("序列化已读回执: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_READ,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}
	if err := s.deliver(ctx, t, frame, ""); err != nil {
		return err
	}
	return nil
}
