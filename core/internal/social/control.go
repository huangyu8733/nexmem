// Package social 实现 QQ 式好友申请、入群审批、在线状态、通知、动态与投票。
//
// 跨端信令复用单聊的加密文本通道：所有控制帧以不可见前缀开头，正文为 JSON。
// 这样无需新增 protobuf 类型（当前环境无 protoc），同时保持端到端加密与
// 现有 ACK/离线补发机制。控制帧不生成本地聊天气泡。
package social

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"
)

// controlPrefix 是所有社交控制帧的公共前缀，与群控制帧 \x01nexmem: 区分。
const controlPrefix = "\x01nexmem:social:"

// 控制帧类型。
const (
	KindFriendRequest   = "friend.request"    // 发好友申请
	KindFriendAccept    = "friend.accept"     // 同意好友申请
	KindFriendReject    = "friend.reject"     // 拒绝好友申请
	KindGroupJoinReq    = "group.joinRequest" // 申请入群
	KindGroupJoinAccept = "group.joinAccept"  // 同意入群
	KindGroupJoinReject = "group.joinReject"  // 拒绝入群
	KindGroupMute       = "group.mute"        // 禁言成员
	KindGroupRole       = "group.role"        // 角色变更
	KindMomentNew       = "moment.new"        // 新动态广播
	KindPresenceProbe   = "presence.probe"    // 在线探测
	KindPresencePong    = "presence.pong"     // 在线应答
)

// Frame 是控制帧的 JSON 载荷。
type Frame struct {
	Kind      string            `json:"kind"`
	ID        string            `json:"id,omitempty"`
	From      string            `json:"from"` // 发送方账号公钥 hex
	To        string            `json:"to,omitempty"`
	GroupID   string            `json:"group_id,omitempty"`
	Text      string            `json:"text,omitempty"`
	Timestamp int64             `json:"ts"`
	Extra     map[string]string `json:"extra,omitempty"`
}

// Encode 把控制帧编码为可放入单聊文本正文的字符串。
func Encode(f Frame) string {
	if f.Timestamp == 0 {
		f.Timestamp = time.Now().Unix()
	}
	raw, _ := json.Marshal(f)
	return controlPrefix + base64.RawURLEncoding.EncodeToString(raw)
}

// Decode 解析文本控制帧；非控制帧或非法载荷返回 ok=false。
func Decode(text string) (Frame, bool) {
	if !strings.HasPrefix(text, controlPrefix) {
		return Frame{}, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(text, controlPrefix))
	if err != nil {
		return Frame{}, false
	}
	var f Frame
	if err := json.Unmarshal(raw, &f); err != nil || f.Kind == "" || f.From == "" {
		return Frame{}, false
	}
	return f, true
}

// IsControlFrame 判断一段文本是否为社交控制帧。
func IsControlFrame(text string) bool {
	return strings.HasPrefix(text, controlPrefix)
}
