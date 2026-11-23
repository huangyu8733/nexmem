package dm

// 接收端离线拉取（P3-07）。
//
// 接收方用自己的 S3 凭证定期列出 im_offline/{account}/inbox/ 下的对象，
// 逐个验签、解密、按 msg_uuid 幂等入库，并推进本设备游标。
//
// 桶内对象的清理有两种模式（需求 L66/L103 允许二选一）：
//   - lifecycle（默认）：不删除对象，由桶生命周期规则过期清理。多端共用同一
//     前缀时必须使用本模式，否则一台设备删除后其他设备将永远拉不到该消息。
//   - deleteAfterRead：入库成功后由客户端显式调用 S3 Delete 删除对象，适用于
//     单设备独占桶且未配置生命周期规则的场景。由 Options.DeleteAfterRead 开启，
//     且仅当 Inbox 实现 OfflineObjectDeleter 时生效（*blob.Client 天然满足）。
//     删除失败不阻断入库（对象已落本地库、游标已推进），由生命周期规则兜底。

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"sort"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
)

const (
	// DefaultOfflineFetchInterval 是后台拉取扫描间隔，保证上线后 5s 内可见。
	DefaultOfflineFetchInterval = 5 * time.Second
	// MaxOfflineObjectSize 是单个离线对象的大小上限，超出直接丢弃（P3-08 会补诊断事件）。
	MaxOfflineObjectSize = 1 << 20
	// offlineFetchOverlap 是游标水位向前的重叠窗口，覆盖客户端与对象存储的时钟偏差。
	offlineFetchOverlap = time.Minute
	// offlineFetchPassTimeout 是单次后台拉取的总超时。
	offlineFetchPassTimeout = 2 * time.Minute
)

// ErrOfflineFetchDisabled 表示未注入接收方对象存储客户端。
var ErrOfflineFetchDisabled = errors.New("未配置离线拉取")

// OfflineStore 是接收方访问自己桶的只读能力，由 *blob.Client 实现。
type OfflineStore interface {
	List(ctx context.Context, prefix string) ([]blob.ObjectInfo, error)
	Get(ctx context.Context, key string) ([]byte, blob.ObjectInfo, error)
}

// OfflineObjectDeleter 是可选的「已读后删除」能力。OfflineStore 不强制实现它，
// 以便多端共用桶的默认 lifecycle 模式保持只读语义；*blob.Client 天然实现。
type OfflineObjectDeleter interface {
	Delete(ctx context.Context, key string) error
}

// OfflineScope 返回本设备单聊离线收件箱的游标 scope。
func OfflineScope(accountPub []byte) string {
	return "dm:" + base64.RawURLEncoding.EncodeToString(accountPub)
}

// FetchReport 汇总一次离线拉取的结果。
type FetchReport struct {
	Scanned   int // 本次扫描到的对象数
	Imported  int // 解密验签通过并首次入库
	Duplicate int // 已入库（直连或之前拉取过），本次跳过
	Skipped   int // 非法、超限或已过期的对象
	Failed    int // 对象存储读写失败
	Deleted   int // deleteAfterRead 模式下成功删除的已读对象数
}

// importOutcome 是单个对象的导入结果。
type importOutcome int

const (
	importSkipped importOutcome = iota
	importImported
	importDuplicate
)

// OfflineFetchEnabled 表示离线拉取链路是否已配置。
func (s *Service) OfflineFetchEnabled() bool { return s.inbox != nil }

// FetchOffline 执行一次离线收件箱拉取。
//
// 只处理上次水位之后的对象（带 1 分钟重叠窗口），按 LastModified 升序导入，
// 保证同一 msg_uuid 重复拉取不会重复入库或重复计数未读。
func (s *Service) FetchOffline(ctx context.Context) (FetchReport, error) {
	var rep FetchReport
	if s.inbox == nil {
		return rep, ErrOfflineFetchDisabled
	}
	if ctx == nil {
		ctx = context.Background()
	}

	s.fetchMu.Lock()
	defer s.fetchMu.Unlock()

	prefix := blob.InboxPrefix(s.account.Pub())
	scope := OfflineScope(s.account.Pub())
	scanStart := time.Now()

	objs, err := s.inbox.List(ctx, prefix)
	if err != nil {
		return rep, fmt.Errorf("列出离线收件箱: %w", err)
	}

	cur, err := s.dao.GetCursor(ctx, scope)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return rep, err
	}
	cutoff := int64(0)
	if cur != nil && cur.SeenAt > 0 {
		cutoff = cur.SeenAt - offlineFetchOverlap.Milliseconds()
	}

	sort.SliceStable(objs, func(i, j int) bool {
		if !objs[i].LastModified.Equal(objs[j].LastModified) {
			return objs[i].LastModified.Before(objs[j].LastModified)
		}
		return objs[i].Key < objs[j].Key
	})

	lastKey, lastETag := "", ""
	if cur != nil {
		lastKey, lastETag = cur.ObjectKey, cur.ETag
	}
	for _, obj := range objs {
		if !bytes.HasPrefix([]byte(obj.Key), []byte(prefix)) || len(obj.Key) <= len(prefix) {
			continue
		}
		rep.Scanned++
		if cutoff > 0 && !obj.LastModified.IsZero() && obj.LastModified.UnixMilli() <= cutoff {
			continue
		}
		if obj.Size > MaxOfflineObjectSize {
			rep.Skipped++
			s.rejectOffline(OfflineRejectEvent{ObjectKey: obj.Key, Size: obj.Size, Reason: ReasonOversize})
			lastKey, lastETag = obj.Key, obj.ETag
			continue
		}

		data, info, err := s.inbox.Get(ctx, obj.Key)
		if err != nil {
			rep.Failed++
			return rep, fmt.Errorf("拉取离线对象 %s: %w", obj.Key, err)
		}
		var outcome importOutcome
		switch outcome = s.importOfflineObject(ctx, obj.Key, info.Size, data); outcome {
		case importImported:
			rep.Imported++
		case importDuplicate:
			rep.Duplicate++
		default:
			rep.Skipped++
		}
		// C-02：显式删除已读密文对象（可选）。仅入库成功（含重复入库）才删，
		// 非法对象保留给生命周期/诊断。删除失败不阻断游标推进（本地已入库）。
		if s.deleteAfterRead && (outcome == importImported || outcome == importDuplicate) {
			if deleter, ok := s.inbox.(OfflineObjectDeleter); ok {
				if err := deleter.Delete(ctx, obj.Key); err != nil {
					// 删除失败不是「丢弃对象」——消息已成功入库，仅做诊断告警，
					// 由桶生命周期规则兜底清理，不影响游标推进。
					if s.diag != nil {
						s.diag.Warn(OfflineRejectModule, "已读对象删除失败", map[string]any{
							"object_key": obj.Key,
							"error":      err.Error(),
						})
					}
				} else {
					rep.Deleted++
				}
			}
		}
		lastKey, lastETag = obj.Key, info.ETag
	}

	if err := s.dao.PutCursor(ctx, store.InboxCursor{
		Scope:     scope,
		ObjectKey: lastKey,
		ETag:      lastETag,
		SeenAt:    scanStart.UnixMilli(),
	}); err != nil {
		return rep, err
	}
	return rep, nil
}

// importOfflineObject 校验一个离线对象并入库。
//
// 顺序：大小 → 解析 → 归属/签名校验 → 过期判断 → 解密 → 正文校验 → 幂等入库。
// 任一环节不合法都返回 importSkipped，不写入任何数据，并记录一条丢弃诊断事件。
func (s *Service) importOfflineObject(ctx context.Context, key string, size int64, data []byte) importOutcome {
	if size < int64(len(data)) {
		size = int64(len(data))
	}
	reject := func(msgUUID string, reason OfflineRejectReason) importOutcome {
		s.rejectOffline(OfflineRejectEvent{
			ObjectKey: key,
			Size:      size,
			MsgUUID:   msgUUID,
			Reason:    reason,
		})
		return importSkipped
	}

	if size > MaxOfflineObjectSize || len(data) > MaxOfflineObjectSize {
		return reject("", ReasonOversize)
	}
	msg := &nexmemv1.OfflineMessage{}
	if err := proto.Unmarshal(data, msg); err != nil {
		return reject("", ReasonMalformed)
	}
	if msg.GetMsgUuid() == "" || !validAccountPub(msg.GetSenderAccount()) {
		return reject(msg.GetMsgUuid(), ReasonMalformed)
	}
	if !bytes.Equal(msg.GetReceiverAccount(), s.account.Pub()) {
		return reject(msg.GetMsgUuid(), ReasonNotOwner)
	}
	if bytes.Equal(msg.GetSenderAccount(), s.account.Pub()) {
		return reject(msg.GetMsgUuid(), ReasonSelfSend)
	}
	if blocked, err := s.isBlocked(ctx, msg.GetSenderAccount()); err != nil || blocked {
		return reject(msg.GetMsgUuid(), ReasonBlocked)
	}
	if msg.GetKeyAlg() != crypto.EnvelopeKeyAlg {
		return reject(msg.GetMsgUuid(), ReasonKeyAlg)
	}
	if err := identity.VerifyOfflineMessage(msg); err != nil {
		return reject(msg.GetMsgUuid(), ReasonSignature)
	}
	if msg.GetTtlHours() > 0 {
		expireAt := time.UnixMilli(msg.GetTimestamp()).
			Add(time.Duration(msg.GetTtlHours()) * time.Hour)
		if time.Now().After(expireAt) {
			return reject(msg.GetMsgUuid(), ReasonExpired)
		}
	}

	convID := ConversationID(s.account.Pub(), msg.GetSenderAccount())
	if len(msg.GetConversationId()) > 0 && !bytes.Equal(msg.GetConversationId(), []byte(convID)) {
		return reject(msg.GetMsgUuid(), ReasonConversation)
	}

	aad := OfflineAAD(msg.GetMsgUuid(), msg.GetSenderAccount(), msg.GetReceiverAccount())
	plain, err := crypto.OpenMessage(s.account.XPriv(), &crypto.SealedMessage{
		KeyAlg:       msg.GetKeyAlg(),
		EncryptedKey: msg.GetEncryptedKey(),
		Nonce:        msg.GetNonce(),
		Ciphertext:   msg.GetCiphertext(),
	}, aad)
	if err != nil {
		return reject(msg.GetMsgUuid(), ReasonDecrypt)
	}

	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(plain, inner); err != nil {
		return reject(msg.GetMsgUuid(), ReasonMalformed)
	}
	switch msg.GetContentType() {
	case nexmemv1.ContentType_CONTENT_TYPE_TEXT:
		if inner.GetText() == "" {
			return reject(msg.GetMsgUuid(), ReasonContent)
		}
	case nexmemv1.ContentType_CONTENT_TYPE_FILE:
		if !validFileAttachment(inner) {
			return reject(msg.GetMsgUuid(), ReasonContent)
		}
	case nexmemv1.ContentType_CONTENT_TYPE_GROUP_META:
		if !validGroupMeta(inner) {
			return reject(msg.GetMsgUuid(), ReasonContent)
		}
	default:
		return reject(msg.GetMsgUuid(), ReasonContent)
	}

	direct := &nexmemv1.DirectMessage{
		MsgUuid:         msg.GetMsgUuid(),
		Timestamp:       msg.GetTimestamp(),
		SenderAccount:   msg.GetSenderAccount(),
		ReceiverAccount: msg.GetReceiverAccount(),
		ConversationId:  []byte(convID),
		ContentType:     msg.GetContentType(),
		Inner:           plain,
	}
	raw, err := proto.Marshal(direct)
	if err != nil {
		return reject(msg.GetMsgUuid(), ReasonMalformed)
	}
	if code := s.acceptInbound(ctx, direct, raw); code != AckOK {
		if code == AckDup {
			return importDuplicate
		}
		return reject(msg.GetMsgUuid(), ReasonAck)
	}
	return importImported
}

// offlineFetchLoop 启动时立即拉取一次，之后按间隔轮询，保证上线 5s 内可见。
func (s *Service) offlineFetchLoop() {
	defer s.closeWait.Done()
	s.runOfflineFetch()

	ticker := time.NewTicker(s.fetchEvery)
	defer ticker.Stop()
	for {
		select {
		case <-s.stopCh:
			return
		case <-ticker.C:
			s.runOfflineFetch()
		}
	}
}

func (s *Service) runOfflineFetch() {
	ctx, cancel := context.WithTimeout(context.Background(), offlineFetchPassTimeout)
	defer cancel()
	_, _ = s.FetchOffline(ctx)
}
