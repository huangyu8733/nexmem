package dm

// 发送端离线投递链路（P3-06）。
//
// 直连投递失败（对端离线、打洞/中继均不可达）时，自动向索引服务领取一张
// 接收方预置的 presigned PUT 票据，用接收方 account_x_pub 混合加密正文后
// 上传到对象存储。发送方全程不接触接收方 S3 凭证，索引服务也读不到正文。

import (
	"context"
	"errors"
	"fmt"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/store"
)

const (
	// DefaultOfflineTTL 是离线对象的默认保留时长，与桶生命周期 7 天一致。
	DefaultOfflineTTL = 7 * 24 * time.Hour
	// offlineUploadAttempts 是单条消息的上传尝试次数：失败后换一张票据再试一次。
	offlineUploadAttempts = 2

	minOfflineTTL = time.Hour
	maxOfflineTTL = 7 * 24 * time.Hour
)

// 离线投递语义错误。
var (
	// ErrOfflineNotConfigured 表示未注入索引客户端或上传器。
	ErrOfflineNotConfigured = errors.New("未配置离线投递")
	// ErrOfflineDisabled 表示对端未开启离线存储（对应 OFFLINE_STORAGE_DISABLED）。
	ErrOfflineDisabled = errors.New("对方未开启离线存储")
	// ErrOfflineNoTickets 表示对方票据池已空，本次无法离线投递。
	ErrOfflineNoTickets = errors.New("对方离线票据池为空")
)

// OfflineDirectory 是离线投递所需的索引服务能力。
type OfflineDirectory interface {
	GetProfile(ctx context.Context, accountPub []byte) (*nexmemv1.PublicProfile, error)
	TakeTickets(ctx context.Context, accountPub []byte, take int) ([]blob.Ticket, error)
}

// PresignedUploader 用一次性票据上传密文对象。
type PresignedUploader interface {
	PutPresigned(ctx context.Context, rawURL string, data []byte) error
}

// UploaderFunc 把普通函数适配为 PresignedUploader。
type UploaderFunc func(ctx context.Context, rawURL string, data []byte) error

// PutPresigned 实现 PresignedUploader。
func (f UploaderFunc) PutPresigned(ctx context.Context, rawURL string, data []byte) error {
	return f(ctx, rawURL, data)
}

// DeliveryEvent 是发送状态变化事件，供上层映射为 message.updated。
//
// Reason 仅在确定性失败时非空（如 ReasonOfflineStorageDisabled），
// 让 UI 能区分「重试可恢复」与「对端未开启离线存储」。
type DeliveryEvent struct {
	MsgUUID        string
	ConversationID string
	State          int
	Offline        bool
	Reason         string
}

// ReasonOfflineStorageDisabled 表示对端公开档案声明未开启离线存储，
// 直连不可达时无法投递，只能等对方上线后由离队队列补发。
const ReasonOfflineStorageDisabled = "OFFLINE_STORAGE_DISABLED"

// OfflineAAD 生成离线消息正文的附加认证数据：msg_uuid + 收发双方账号公钥。
// 收发两端必须使用同一算法，缺一不可。
func OfflineAAD(msgUUID string, senderAccount, receiverAccount []byte) []byte {
	out := make([]byte, 0, len(msgUUID)+len(senderAccount)+len(receiverAccount))
	out = append(out, msgUUID...)
	out = append(out, senderAccount...)
	out = append(out, receiverAccount...)
	return out
}

// OfflineEnabled 表示离线投递链路是否已配置。
func (s *Service) OfflineEnabled() bool {
	return s.directory != nil && s.uploader != nil
}

// sendOffline 把已入库的正文加密后经票据上传到接收方对象存储。
func (s *Service) sendOffline(ctx context.Context, receiver []byte, msgID, convID string, ts int64, ct nexmemv1.ContentType, inner []byte) error {
	if !s.OfflineEnabled() {
		return ErrOfflineNotConfigured
	}

	profile, err := s.directory.GetProfile(ctx, receiver)
	if err != nil {
		return fmt.Errorf("拉取对方公开档案: %w", err)
	}
	if !profile.OfflineEnabled {
		return ErrOfflineDisabled
	}
	if len(profile.AccountXPub) != 32 {
		return fmt.Errorf("对方档案 X25519 公钥长度错误: %d", len(profile.AccountXPub))
	}

	aad := OfflineAAD(msgID, s.account.Pub(), receiver)
	sealed, err := crypto.SealMessage(profile.AccountXPub, inner, aad)
	if err != nil {
		return fmt.Errorf("加密离线消息: %w", err)
	}

	msg := &nexmemv1.OfflineMessage{
		MsgUuid:         msgID,
		Timestamp:       ts,
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: receiver,
		ConversationId:  []byte(convID),
		EncryptedKey:    sealed.EncryptedKey,
		Nonce:           sealed.Nonce,
		Ciphertext:      sealed.Ciphertext,
		KeyAlg:          sealed.KeyAlg,
		ContentType:     ct,
		TtlHours:        uint32(s.offlineTTL / time.Hour),
	}
	if err := s.account.SignOfflineMessage(msg); err != nil {
		return fmt.Errorf("签名离线消息: %w", err)
	}
	payload, err := proto.Marshal(msg)
	if err != nil {
		return fmt.Errorf("序列化离线消息: %w", err)
	}

	var lastErr error
	for attempt := 0; attempt < offlineUploadAttempts; attempt++ {
		tickets, err := s.directory.TakeTickets(ctx, receiver, 1)
		if err != nil {
			return fmt.Errorf("领取上传票据: %w", err)
		}
		if s.onTicketTake != nil {
			s.onTicketTake(len(tickets))
		}
		if len(tickets) == 0 {
			return ErrOfflineNoTickets
		}
		if err := s.uploader.PutPresigned(ctx, tickets[0].URL, payload); err != nil {
			lastErr = err
			continue
		}
		if s.onOfflineUpload != nil {
			s.onOfflineUpload(int64(len(payload)), true)
		}
		// 投递成功后再唤醒接收方；异步节流，不影响本条消息的返回。
		s.notifyWake(receiver)
		return nil
	}
	if s.onOfflineUpload != nil {
		s.onOfflineUpload(0, false)
	}
	return fmt.Errorf("上传离线对象失败: %w", lastErr)
}

// markOfflineSent 把消息置为已发送并触发一次投递事件。
func (s *Service) markOfflineSent(ctx context.Context, msgID, convID string, ts int64) {
	s.markStateDetail(ctx, msgID, convID, store.MessageStateSent, true, "")
	_ = s.dao.TouchConversation(ctx, convID, ts)
}

func (s *Service) emitDelivery(ev DeliveryEvent) {
	if s.onDelivery != nil {
		s.onDelivery(ev)
	}
}
