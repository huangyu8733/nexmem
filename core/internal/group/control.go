package group

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
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

// storageRemovedNotice 是群盘移除控制帧正文（C-05）。
//
// 管理员移除群盘后广播该帧；成员收到后校验发送方为管理员，清掉本机群盘配置，
// 之后不再写入/拉取群盘密文。与解散帧类似，控制帧不落库、不生成聊天气泡。
const storageRemovedNotice = controlFrameDomain + "storage-removed"

// StorageRemovedNotice 返回群盘移除控制帧正文。
func StorageRemovedNotice() string {
	return storageRemovedNotice
}

// IsStorageRemovedNotice 判断正文是否为群盘移除控制帧。
func IsStorageRemovedNotice(body []byte) bool {
	return strings.TrimSpace(string(body)) == storageRemovedNotice
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

// levelsNoticePrefix 是群等级配置控制帧前缀。
// 帧正文为 base64url(JSON(LevelConfig))，字段名与 group.setLevelConfig 契约一致；
// 控制帧不落库、不生成聊天气泡。
const levelsNoticePrefix = controlFrameDomain + "levels:"

// EncodeLevelsNotice 生成群等级配置控制帧正文。
func EncodeLevelsNotice(cfg LevelConfig) (string, error) {
	if err := ValidateLevelConfig(cfg); err != nil {
		return "", err
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return levelsNoticePrefix + base64.RawURLEncoding.EncodeToString(raw), nil
}

// ParseLevelsNotice 解析群等级配置控制帧；非本类正文或配置非法返回 ok=false。
func ParseLevelsNotice(body []byte) (LevelConfig, bool) {
	text := string(body)
	if !strings.HasPrefix(text, levelsNoticePrefix) {
		return LevelConfig{}, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(text[len(levelsNoticePrefix):])
	if err != nil {
		return LevelConfig{}, false
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return LevelConfig{}, false
	}
	if _, ok := fields["enabled"]; !ok {
		return LevelConfig{}, false
	}
	if _, ok := fields["levels"]; !ok {
		return LevelConfig{}, false
	}
	var cfg LevelConfig
	if err := json.Unmarshal(raw, &cfg); err != nil || ValidateLevelConfig(cfg) != nil {
		return LevelConfig{}, false
	}
	return cfg, true
}

// memberProfileNoticePrefix 是成员本群资料控制帧前缀。
// 帧正文为 base64url(JSON(MemberProfile))，字段名与 group.setMemberProfile 契约一致。
const memberProfileNoticePrefix = controlFrameDomain + "member-profile:"

// EncodeMemberProfileNotice 生成成员本群资料控制帧正文。
func EncodeMemberProfileNotice(profile MemberProfile) (string, error) {
	if profile.Account == "" {
		return "", ErrMemberNotFound
	}
	if err := ValidateNickname(profile.Nickname); err != nil {
		return "", err
	}
	raw, err := json.Marshal(profile)
	if err != nil {
		return "", err
	}
	return memberProfileNoticePrefix + base64.RawURLEncoding.EncodeToString(raw), nil
}

// ParseMemberProfileNotice 解析成员本群资料控制帧；非本类正文或字段缺失返回 ok=false。
func ParseMemberProfileNotice(body []byte) (MemberProfile, bool) {
	text := string(body)
	if !strings.HasPrefix(text, memberProfileNoticePrefix) {
		return MemberProfile{}, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(text[len(memberProfileNoticePrefix):])
	if err != nil {
		return MemberProfile{}, false
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return MemberProfile{}, false
	}
	for _, name := range []string{"account", "nickname", "level_id"} {
		if _, ok := fields[name]; !ok {
			return MemberProfile{}, false
		}
	}
	var profile MemberProfile
	if err := json.Unmarshal(raw, &profile); err != nil ||
		profile.Account == "" || ValidateNickname(profile.Nickname) != nil {
		return MemberProfile{}, false
	}
	return profile, true
}

// allowFriendAddNoticePrefix 是「允许成员互加好友」群设置控制帧前缀。
// 帧正文只携带 0/1，控制帧不落库、不生成聊天气泡。
const allowFriendAddNoticePrefix = controlFrameDomain + "allow-friend:"

// EncodeAllowFriendAddNotice 生成加好友开关控制帧正文。
func EncodeAllowFriendAddNotice(enabled bool) string {
	if enabled {
		return allowFriendAddNoticePrefix + "1"
	}
	return allowFriendAddNoticePrefix + "0"
}

// ParseAllowFriendAddNotice 解析加好友开关控制帧；非本类正文返回 ok=false。
func ParseAllowFriendAddNotice(body []byte) (bool, bool) {
	text := strings.TrimSpace(string(body))
	if !strings.HasPrefix(text, allowFriendAddNoticePrefix) {
		return false, false
	}
	switch text[len(allowFriendAddNoticePrefix):] {
	case "1":
		return true, true
	case "0":
		return false, true
	default:
		return false, false
	}
}
