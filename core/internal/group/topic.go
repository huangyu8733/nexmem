// Package group 实现群聊（P4）的 GossipSub 传输：私有主题、信封验签、
// 成员校验与 TTL/指纹去重。
//
// 主题名固定为 /nexmem/group/<base64url(sha256(group_id))>，与工程方案 §3.3 一致。
// 群消息正文由群密钥加密（P4-03 起启用），本阶段只负责在线广播通道本身。
package group

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/identity"
)

const (
	// TopicPrefix 是群聊私有主题的固定前缀。
	TopicPrefix = "/nexmem/group/"

	// envelopeDomain 做签名域隔离，避免群信封签名被复用到其他协议。
	envelopeDomain = "nexmem/group-envelope/v1"

	// MaxBodySize 限制单条群消息正文；留出信封与签名余量后不超过 GossipSub 1 MiB 上限。
	MaxBodySize = 512 << 10

	// DefaultMaxAge 是信封发送时间允许的最大偏差。
	DefaultMaxAge = 7 * 24 * time.Hour

	// DefaultDedupeTTL 是入站指纹去重窗口。
	DefaultDedupeTTL = 10 * time.Minute

	// DefaultDedupeCapacity 是去重窗口的最大条目数。
	DefaultDedupeCapacity = 8192
)

// 语义错误。
var (
	ErrGroupIDRequired = errors.New("群 ID 不能为空")
	ErrEmptyBody       = errors.New("群消息正文不能为空")
	ErrBodyTooLarge    = fmt.Errorf("群消息正文超过 %d 字节", MaxBodySize)
	ErrNotMember       = errors.New("发送方不是群成员")
	ErrBadEnvelope     = errors.New("群消息信封非法")
	ErrPeerUnreached   = errors.New("对端不可达")
	ErrPeerRejected    = errors.New("对端拒绝接收")
	ErrAckInvalid      = errors.New("对端 ACK 非法")

	// ErrRecallUUIDInvalid 表示群撤回控制帧的目标消息标识非法（P6-14）。
	ErrRecallUUIDInvalid = errors.New("撤回目标消息标识非法")
)

// TopicFor 返回群 ID 对应的 GossipSub 私有主题名。
func TopicFor(groupID []byte) string {
	sum := sha256.Sum256(groupID)
	return TopicPrefix + base64.RawURLEncoding.EncodeToString(sum[:])
}

// canonicalEnvelope 生成参与签名的确定性字节。
// 每段带 4 字节长度前缀，整数用大端定长，避免字段拼接歧义。
func canonicalEnvelope(env *nexmemv1.GroupEnvelope) []byte {
	var buf bytes.Buffer
	writeChunk(&buf, []byte(envelopeDomain))
	writeChunk(&buf, env.GetGroupId())
	writeChunk(&buf, env.GetSenderAccount())
	writeChunk(&buf, env.GetMsgUuid())
	var tmp [8]byte
	binary.BigEndian.PutUint64(tmp[:], uint64(env.GetSentAt()))
	buf.Write(tmp[:])
	binary.BigEndian.PutUint32(tmp[:4], env.GetKeyVersion())
	buf.Write(tmp[:4])
	writeChunk(&buf, env.GetBody())
	return buf.Bytes()
}

func writeChunk(w *bytes.Buffer, b []byte) {
	var l [4]byte
	binary.BigEndian.PutUint32(l[:], uint32(len(b)))
	w.Write(l[:])
	w.Write(b)
}

// VerifyEnvelope 校验群信封的签名、时间偏差与正文大小。
// 成员资格由调用方另行校验，因为成员列表可能随群变更。
func VerifyEnvelope(env *nexmemv1.GroupEnvelope, now time.Time, maxAge time.Duration) error {
	if env == nil {
		return ErrBadEnvelope
	}
	if len(env.GetGroupId()) == 0 {
		return ErrGroupIDRequired
	}
	if len(env.GetSenderAccount()) != 32 {
		return fmt.Errorf("%w: 发送方账号公钥长度 %d", ErrBadEnvelope, len(env.GetSenderAccount()))
	}
	if len(env.GetMsgUuid()) == 0 {
		return fmt.Errorf("%w: 缺少 msg_uuid", ErrBadEnvelope)
	}
	if len(env.GetBody()) == 0 {
		return ErrEmptyBody
	}
	if len(env.GetBody()) > MaxBodySize {
		return ErrBodyTooLarge
	}
	if maxAge <= 0 {
		maxAge = DefaultMaxAge
	}
	sent := time.UnixMilli(env.GetSentAt())
	if env.GetSentAt() <= 0 || now.Sub(sent) > maxAge || sent.Sub(now) > maxAge {
		return fmt.Errorf("%w: 发送时间 %s 超出允许偏差", ErrBadEnvelope, sent)
	}
	if err := identity.VerifyAccountSignature(env.GetSenderAccount(), canonicalEnvelope(env), env.GetSignature()); err != nil {
		return fmt.Errorf("%w: %v", ErrBadEnvelope, err)
	}
	return nil
}
