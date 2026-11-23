// Package qrshare 实现「二维码交换 PeerID 加好友」的可移植载荷编解码。
//
// 系统无中心注册、靠账号公钥（PeerID 同源）加人。二维码内容是一段自描述的
// 文本载荷（前缀 + base64url JSON），包含版本、账号 ID、设备 PeerID 与昵称。
// 载荷由持有账号私钥的一方签名，扫描方用载荷内公钥验签，防止二维码被篡改
// 成他人身份。本包只负责编码/解码/验签，二维码的图形渲染与相机扫码在客户端：
// 显示端可本地闭环，相机扫码依赖真机权限（见剩余开发进度）。
package qrshare

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/nexmem/core/internal/identity"
)

const (
	// Prefix 是二维码文本的可识别前缀，便于扫描后判断是否为 Nexmem 名片。
	Prefix = "nexmem://add/"

	payloadVersion = 1
	maxNameLen     = 64
)

var (
	// ErrFormat 表示载荷格式非法（前缀、base64、JSON 或字段缺失）。
	ErrFormat = errors.New("二维码名片格式非法")
	// ErrVersion 表示载荷版本不受支持。
	ErrVersion = errors.New("二维码名片版本不支持")
	// ErrSignature 表示签名校验失败（被篡改或公钥不符）。
	ErrSignature = errors.New("二维码名片签名校验失败")
)

// Card 是二维码名片的可读内容。
type Card struct {
	AccountID  string `json:"a"` // 账号 ID（ed25519 公钥十六进制）
	DeviceID   string `json:"d"` // 设备 PeerID（可由调用方留空）
	DisplayName string `json:"n"` // 昵称，可空
}

// signedDoc 是实际被签名的确定性 JSON（签名不覆盖自身）。
type signedDoc struct {
	Version int    `json:"v"`
	Account string `json:"a"`
	Device  string `json:"d"`
	Name    string `json:"n"`
}

type envelope struct {
	Payload   signedDoc `json:"p"`
	Signature string    `json:"s"` // base64url(ed25519 signature)
}

// Encode 用账号私钥把名片编码为二维码文本。accountID 必须是 64 位十六进制
// ed25519 公钥；签名覆盖 version/account/device/name 的规范化 JSON。
func Encode(acc *identity.Account, deviceID, displayName string) (string, error) {
	if acc == nil {
		return "", errors.New("账号为空")
	}
	accountID := acc.ID()
	pub, err := hex.DecodeString(accountID)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return "", fmt.Errorf("%w: 账号 ID 非法", ErrFormat)
	}
	if len([]rune(displayName)) > maxNameLen {
		return "", fmt.Errorf("%w: 昵称超过 %d 字符", ErrFormat, maxNameLen)
	}
	doc := signedDoc{
		Version: payloadVersion,
		Account: strings.ToLower(accountID),
		Device:  strings.TrimSpace(deviceID),
		Name:    displayName,
	}
	canonical, err := json.Marshal(doc)
	if err != nil {
		return "", fmt.Errorf("序列化名片: %w", err)
	}
	sig := acc.Sign(domainSeparate(canonical))
	env := envelope{
		Payload:   doc,
		Signature: base64.RawURLEncoding.EncodeToString(sig),
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return "", fmt.Errorf("序列化信封: %w", err)
	}
	return Prefix + base64.RawURLEncoding.EncodeToString(raw), nil
}

// Decode 解析并校验二维码文本，返回名片内容。任何格式错误或验签失败都拒绝，
// 避免扫描到伪造载荷时被引导添加错误身份。
func Decode(text string) (Card, error) {
	var card Card
	raw := strings.TrimSpace(text)
	if !strings.HasPrefix(raw, Prefix) {
		return card, fmt.Errorf("%w: 缺少前缀 %s", ErrFormat, Prefix)
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(raw, Prefix))
	if err != nil || len(data) == 0 {
		return card, fmt.Errorf("%w: base64url 解码失败", ErrFormat)
	}
	var env envelope
	if err := json.Unmarshal(data, &env); err != nil {
		return card, fmt.Errorf("%w: JSON 解析失败", ErrFormat)
	}
	if env.Payload.Version != payloadVersion {
		return card, fmt.Errorf("%w: %d", ErrVersion, env.Payload.Version)
	}
	pub, err := hex.DecodeString(env.Payload.Account)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return card, fmt.Errorf("%w: 账号 ID 非法", ErrFormat)
	}
	sig, err := base64.RawURLEncoding.DecodeString(env.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return card, fmt.Errorf("%w: 签名长度非法", ErrSignature)
	}
	canonical, err := json.Marshal(env.Payload)
	if err != nil {
		return card, fmt.Errorf("序列化待验签内容: %w", err)
	}
	if err := identity.VerifyAccountSignature(pub, domainSeparate(canonical), sig); err != nil {
		return card, ErrSignature
	}
	if len([]rune(env.Payload.Name)) > maxNameLen {
		return card, fmt.Errorf("%w: 昵称过长", ErrFormat)
	}
	return Card{
		AccountID:   strings.ToLower(env.Payload.Account),
		DeviceID:    env.Payload.Device,
		DisplayName: env.Payload.Name,
	}, nil
}

// domainSeparate 为签名加域隔离前缀，避免与账号密钥的其它签名场景复用。
func domainSeparate(data []byte) []byte {
	const domain = "nexmem/qrshare/v1\x00"
	out := make([]byte, 0, len(domain)+len(data))
	out = append(out, domain...)
	out = append(out, data...)
	return out
}
