package dm

// 跨设备已读水位同步（C-04）。
//
// 同一身份多台设备共用同一个私聊 S3 收件箱桶（账号级前缀 im_offline/{acct}/inbox/）。
// 每台设备 markRead 后把已读水位签名为对象写入该桶的 readstate/v1/ 子目录；
// 其他设备上线拉取时读取全部水位、按会话取最大值并推进本机 messages.state=read，
// 发出 message.updated 事件。这样多端无需新增设备间直连协议即可同步已读状态。
//
// 依赖可注入：ReadSyncStore 只需 Put/List/Get（*blob.Client 与测试内存替身均满足），
// 不依赖真实公网 S3；水位签名为账号 ed25519，防止共用桶内跨账号伪造。

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"

	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/readsync"
)

// ReadSyncStore 是发布/拉取已读水位所需的对象存储能力，*blob.Client 天然实现。
type ReadSyncStore interface {
	Put(ctx context.Context, key string, data []byte, contentType string) (blob.ObjectInfo, error)
	Get(ctx context.Context, key string) ([]byte, blob.ObjectInfo, error)
	List(ctx context.Context, prefix string) ([]blob.ObjectInfo, error)
}

// ErrReadSyncDisabled 表示未注入可写收件箱，无法发布/拉取已读水位。
var ErrReadSyncDisabled = errors.New("跨设备已读同步未启用（未配置可写收件箱）")

// PublishReadWatermark 把本机会话已读水位签名为对象写入共用收件箱桶。
// 同一会话重复发布覆盖同名对象（幂等）；失败返回错误由调用方记日志、不阻断 markRead。
func (s *Service) PublishReadWatermark(ctx context.Context, conversationID string, upTo int64) error {
	if s.readSyncStore == nil || s.account == nil {
		return ErrReadSyncDisabled
	}
	if upTo <= 0 {
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	deviceID := ""
	if s.deviceKey != nil {
		pub, err := peerIDFromDeviceKey(s.deviceKey)
		if err == nil {
			deviceID = pub
		}
	}
	raw, err := readsync.Produce(s.account.Sign, s.account.Pub(), conversationID, upTo,
		time.Now().UnixMilli(), deviceID)
	if err != nil {
		return fmt.Errorf("签发已读水位: %w", err)
	}
	prefix := blob.InboxPrefix(s.account.Pub())
	key := readsync.ObjectKey(prefix, conversationID) + "-" + deviceID + ".json"
	if _, err := s.readSyncStore.Put(ctx, key, raw, readsync.ObjectContentType); err != nil {
		return fmt.Errorf("写入已读水位: %w", err)
	}
	return nil
}

// SyncReadStates 从共用收件箱桶拉取全部已读水位，按会话取最大值推进本机已读状态。
// 返回被推进的会话 ID 列表（供上层发 conversation.changed）；失败返回错误由调用方记日志。
// 单条水位应用失败不中断其他会话，已成功推进的会话仍在返回值中。
func (s *Service) SyncReadStates(ctx context.Context) ([]string, error) {
	if s.readSyncStore == nil || s.account == nil || s.dao == nil {
		return nil, ErrReadSyncDisabled
	}
	if ctx == nil {
		ctx = context.Background()
	}
	prefix := blob.InboxPrefix(s.account.Pub())
	ws, err := readsync.ListWatermarks(ctx, s.readSyncStore, prefix, s.account.Pub())
	if err != nil {
		return nil, err
	}
	best := readsync.MaxByConversation(ws)
	changed := make([]string, 0, len(best))
	var firstErr error
	for _, w := range best {
		uuids, aerr := s.dao.MarkConversationRead(ctx, w.ConversationID, w.UpTo)
		if aerr != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("应用会话 %s 已读水位: %w", w.ConversationID, aerr)
			}
			continue
		}
		if len(uuids) > 0 || len(changed) >= 0 {
			// 即使本会话无消息状态变化，也把会话列入，便于上层刷新未读计数。
			changed = append(changed, w.ConversationID)
		}
	}
	return changed, firstErr
}

// peerIDFromDeviceKey 把设备密钥公钥转成 PeerID 字符串（来源标识，与 devices 契约一致）。
func peerIDFromDeviceKey(key crypto.PrivKey) (string, error) {
	if key == nil {
		return "", errors.New("设备密钥为空")
	}
	id, err := peer.IDFromPublicKey(key.GetPublic())
	if err != nil {
		return "", err
	}
	return id.String(), nil
}
