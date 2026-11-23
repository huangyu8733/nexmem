package dm

import (
	"context"
	"errors"
	"fmt"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/store"
)

const (
	// DefaultAckTimeout 是单次直连投递等待对端 ACK 的默认超时。
	DefaultAckTimeout = 8 * time.Second
	// DefaultMaxAttempts 是直连投递的最大尝试次数（含首次）。
	DefaultMaxAttempts = 3
)

// deliverWithRetry 按 ack 超时重复投递，直到收到 ACK、被拒或次数用尽。
func (s *Service) deliverWithRetry(ctx context.Context, t Target, frame *nexmemv1.Frame, msgID string) error {
	var lastErr error
	for attempt := 0; attempt < s.maxAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			if lastErr != nil {
				return lastErr
			}
			return fmt.Errorf("%w: %v", ErrPeerUnreached, err)
		}
		attemptCtx, cancel := context.WithTimeout(ctx, s.ackTimeout)
		err := s.deliver(attemptCtx, t, frame, msgID)
		cancel()
		if err == nil {
			return nil
		}
		lastErr = err
		// 对端明确拒收属于终态，重试与离线投递都没有意义。
		if errors.Is(err, ErrPeerRejected) {
			return err
		}
	}
	return lastErr
}

// enqueueOutbox 把投递失败的消息写入离线队列，供后续离线投递链路使用。
func (s *Service) enqueueOutbox(ctx context.Context, t Target, frame *nexmemv1.Frame, msgID string) error {
	payload, err := proto.Marshal(frame)
	if err != nil {
		return fmt.Errorf("序列化离线队列载荷: %w", err)
	}
	return s.dao.EnqueueOutbox(ctx, store.OutboxEntry{
		MsgUUID:     msgID,
		PeerAccount: t.AccountPub,
		NextRetryAt: time.Now().Unix(),
		Payload:     payload,
	})
}
