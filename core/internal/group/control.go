package group

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"unicode/utf8"
)

// recallNoticePrefix 是群撤回控制帧的固定前缀（P6-14）。
//
// 群消息正文是端到端加密的 UTF-8 文本，撤回通知与普通文本共用同一通道；
// 前缀以不可见控制字符开头，正常聊天文本不会与之冲突。旧版本客户端收到
// 该帧时只会当作普通文本展示，不影响消息收发与解密。
const recallNoticePrefix = "\x01nexmem:recall:"

// EncodeRecallNotice 生成群撤回控制帧正文，msgUUID 为目标消息的十六进制标识。
func EncodeRecallNotice(msgUUID string) (string, error) {
	uuid := strings.TrimSpace(msgUUID)
	raw, err := hex.DecodeString(uuid)
	if err != nil || len(raw) != 16 {
		return "", ErrRecallUUIDInvalid
	}
	return recallNoticePrefix + hex.EncodeToString(raw), nil
}

// ParseRecallNotice 解析群撤回控制帧；非撤回正文返回 ok=false。
func ParseRecallNotice(body []byte) (string, bool) {
	text := string(body)
	if !strings.HasPrefix(text, recallNoticePrefix) {
		return "", false
	}
	uuid := text[len(recallNoticePrefix):]
	raw, err := hex.DecodeString(uuid)
	if err != nil || len(raw) != 16 {
		return "", false
	}
	return hex.EncodeToString(raw), true
}

// controlFrameDomain 是全部群控制帧的公共前缀，便于本机跳过控制帧的本地落库。
const controlFrameDomain = "\x01nexmem:"

// dissolveNotice 是群解散控制帧正文（P4-12）。
//
// 管理员解散群时广播该帧；成员收到后校验发送方是管理员，再清理本地群记录、
// 密钥与订阅。控制帧本身不落库，也不生成聊天气泡。
const dissolveNotice = controlFrameDomain + "dissolve"

// DissolveNotice 返回群解散控制帧正文。
func DissolveNotice() string {
	return dissolveNotice
}

// IsDissolveNotice 判断正文是否为群解散控制帧。
func IsDissolveNotice(body []byte) bool {
	return strings.TrimSpace(string(body)) == dissolveNotice
}

// IsControlFrame 判断正文是否为群控制帧（撤回、解散、公告等）。
// 控制帧只用于协议通知，不应写入本地消息库。
func IsControlFrame(body []byte) bool {
	return strings.HasPrefix(string(body), controlFrameDomain)
}

// announcementNoticePrefix 是群公告控制帧的固定前缀（P6-26）。
// 公告正文按 base64url 编码携带，控制帧本身不落库、不生成聊天气泡。
const announcementNoticePrefix = controlFrameDomain + "announcement:"

// MaxAnnouncementRunes 是群公告允许的最大 UTF-8 字符数。
const MaxAnnouncementRunes = 512

// ErrAnnouncementTooLong 表示群公告超过长度上限。
var ErrAnnouncementTooLong = errors.New("群公告最多 512 字")

// ValidateAnnouncement 校验群公告字符数；空串表示清除，合法。
func ValidateAnnouncement(text string) error {
	if utf8.RuneCountInString(text) > MaxAnnouncementRunes {
		return ErrAnnouncementTooLong
	}
	return nil
}

// EncodeAnnouncementNotice 生成群公告控制帧正文，空串表示清除公告。
func EncodeAnnouncementNotice(text string) (string, error) {
	if err := ValidateAnnouncement(text); err != nil {
		return "", err
	}
	return announcementNoticePrefix + base64.RawURLEncoding.EncodeToString([]byte(text)), nil
}

// ParseAnnouncementNotice 解析群公告控制帧；非公告正文或超过长度上限返回 ok=false。
func ParseAnnouncementNotice(body []byte) (string, bool) {
	text := string(body)
	if !strings.HasPrefix(text, announcementNoticePrefix) {
		return "", false
	}
	raw, err := base64.RawURLEncoding.DecodeString(text[len(announcementNoticePrefix):])
	if err != nil || !utf8.Valid(raw) {
		return "", false
	}
	out := string(raw)
	if ValidateAnnouncement(out) != nil {
		return "", false
	}
	return out, true
}
