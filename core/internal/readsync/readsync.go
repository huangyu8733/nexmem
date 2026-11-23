// Package readsync 实现 C-04「多设备并行在线同步」中的跨设备已读水位。
//
// 需求原文（:35）：同一身份多台设备同时上线，私聊多端通过共用同一个私聊 S3 存储桶
// 拉取离线消息并标记已读。离线拉取链路（dm.FetchOffline）已完整实现账号级前缀、
// msg_uuid 幂等去重与 lifecycle 清理；本包补齐"已读水位跨设备可见"这一缺口。
//
// 设计：把每条会话的已读水位写成一个账号签名的对象，放在共用收件箱前缀下的
// `readstate/v1/` 子目录。任何一台设备 markRead 后发布水位；其他设备上线拉取时
// 读取全部水位、按 conversation 取最大值，经 DAO MarkConversationRead 推进本机状态。
// 签名用账号 ed25519 私钥，防止共用桶内被其他账号伪造水位；域隔离与 account/qrshare
// 分开，避免-cross-protocol 重放。
//
// 云端真实多端并发/桶策略仍需公网验证（R-17），本地用内存对象存储替身闭环验证
// 编解码、验签、取最大值与幂等，不伪造公网指标。

package readsync

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/nexmem/core/internal/blob"
)

const (
	// Prefix 是已读水位对象在共用收件箱下的子前缀（拼在 InboxPrefix 之后）。
	Prefix = "readstate/v1/"
	// Version 是水位对象格式版本。
	Version = 1
	// ObjectContentType 是水位对象 MIME。
	ObjectContentType = "application/json"

	signDomain = "nexmem/readstate/v1\x00"
)

// 语义错误。
var (
	ErrBadWatermark = errors.New("已读水位对象非法")
	ErrBadSignature = errors.New("已读水位签名非法")
)

// Watermark 是一台设备对一条会话的已读水位。
type Watermark struct {
	ConversationID string `json:"c"`
	UpTo           int64  `json:"u"`
	AccountPub     string `json:"a"` // base64url 账号公钥，绑定归属
	UpdatedAt      int64  `json:"t"` // Unix 毫秒
	DeviceID       string `json:"d"` // base64url device pub，来源标识
	Signature      string `json:"s"` // base64url 账号签名
}

// ObjectKey 返回水位对象键：{inboxPrefix}readstate/v1/{conversation}.json。
// conversationID 用 base64url 编码成安全文件名；accountPub 经 inboxPrefix 隔离。
func ObjectKey(inboxPrefix, conversationID string) string {
	return inboxPrefix + Prefix + base64.RawURLEncoding.EncodeToString([]byte(conversationID)) + ".json"
}

// ParseObjectKey 从对象键反解 conversationID；非水位对象返回 ok=false。
func ParseObjectKey(inboxPrefix, key string) (string, bool) {
	if !strings.HasPrefix(key, inboxPrefix+Prefix) {
		return "", false
	}
	name := strings.TrimSuffix(strings.TrimPrefix(key, inboxPrefix+Prefix), ".json")
	raw, err := base64.RawURLEncoding.DecodeString(name)
	if err != nil || len(raw) == 0 {
		return "", false
	}
	return string(raw), true
}

// signPayload 构造域隔离签名原文：domain || accountPub || conversation || upTo || updatedAt || deviceID。
func signPayload(accountPub []byte, w Watermark) []byte {
	var buf bytes.Buffer
	buf.WriteString(signDomain)
	buf.Write(accountPub)
	buf.WriteString("\x00")
	buf.WriteString(w.ConversationID)
	fmt.Fprintf(&buf, "\x00%d\x00%d\x00", w.UpTo, w.UpdatedAt)
	buf.WriteString(w.DeviceID)
	return buf.Bytes()
}

// Produce 用账号签名器签发一条已读水位并返回对象内容（JSON）。
// sign 通常传 (*identity.Account).Sign——调用方负责域隔离，此处 signPayload 已做。
func Produce(sign func([]byte) []byte, accountPub []byte, conversationID string, upTo, updatedAt int64, deviceID string) ([]byte, error) {
	if sign == nil {
		return nil, fmt.Errorf("%w: 缺少签名器", ErrBadSignature)
	}
	if strings.TrimSpace(conversationID) == "" {
		return nil, fmt.Errorf("%w: 会话 ID 为空", ErrBadWatermark)
	}
	if upTo <= 0 {
		return nil, fmt.Errorf("%w: 水位必须为正", ErrBadWatermark)
	}
	w := Watermark{
		ConversationID: conversationID,
		UpTo:           upTo,
		AccountPub:     base64.RawURLEncoding.EncodeToString(accountPub),
		UpdatedAt:      updatedAt,
		DeviceID:       deviceID,
	}
	sig := sign(signPayload(accountPub, w))
	w.Signature = base64.RawURLEncoding.EncodeToString(sig)
	raw, err := json.Marshal(w)
	if err != nil {
		return nil, err
	}
	return raw, nil
}

// Consume 校验并解析水位对象：版本由结构自描述，验签与账号归属一致才接受。
func Consume(raw []byte, accountPub []byte) (Watermark, error) {
	var w Watermark
	if err := json.Unmarshal(raw, &w); err != nil {
		return Watermark{}, fmt.Errorf("%w: %v", ErrBadWatermark, err)
	}
	if strings.TrimSpace(w.ConversationID) == "" || w.UpTo <= 0 {
		return Watermark{}, fmt.Errorf("%w: 字段缺失", ErrBadWatermark)
	}
	pub, err := base64.RawURLEncoding.DecodeString(w.AccountPub)
	if err != nil || !bytes.Equal(pub, accountPub) {
		return Watermark{}, fmt.Errorf("%w: 账号归属不符", ErrBadWatermark)
	}
	sig, err := base64.RawURLEncoding.DecodeString(w.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return Watermark{}, fmt.Errorf("%w: 签名长度非法", ErrBadSignature)
	}
	key := ed25519.PublicKey(accountPub)
	if !ed25519.Verify(key, signPayload(accountPub, w), sig) {
		return Watermark{}, ErrBadSignature
	}
	return w, nil
}

// MaxByConversation 把多条水位按会话取最大 up_to（同水位取 updatedAt 较新者）。
// 只保留 upTo>0 的条目，返回按 conversationID 排序的切片，结果确定性便于落库与测试。
func MaxByConversation(ws []Watermark) []Watermark {
	best := make(map[string]Watermark, len(ws))
	for _, w := range ws {
		cur, ok := best[w.ConversationID]
		if !ok || w.UpTo > cur.UpTo || (w.UpTo == cur.UpTo && w.UpdatedAt > cur.UpdatedAt) {
			best[w.ConversationID] = w
		}
	}
	out := make([]Watermark, 0, len(best))
	for _, w := range best {
		out = append(out, w)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ConversationID < out[j].ConversationID })
	return out
}

// ListWatermarks 从共用桶列出并解析某账号的全部水位对象；非法对象跳过不阻断。
// store 只需 List/Get 能力（与 dm.OfflineStore 同构），便于注入内存替身。
func ListWatermarks(ctx context.Context, store interface {
	List(ctx context.Context, prefix string) ([]blob.ObjectInfo, error)
	Get(ctx context.Context, key string) ([]byte, blob.ObjectInfo, error)
}, inboxPrefix string, accountPub []byte) ([]Watermark, error) {
	objs, err := store.List(ctx, inboxPrefix+Prefix)
	if err != nil {
		return nil, fmt.Errorf("列出已读水位: %w", err)
	}
	ws := make([]Watermark, 0, len(objs))
	for _, obj := range objs {
		raw, _, gerr := store.Get(ctx, obj.Key)
		if gerr != nil {
			continue // 单个对象读取失败跳过
		}
		w, perr := Consume(raw, accountPub)
		if perr != nil {
			continue // 伪造/损坏对象跳过
		}
		ws = append(ws, w)
	}
	return ws, nil
}
