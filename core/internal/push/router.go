package push

// 多平台推送路由：令牌带平台前缀（apns:/fcm:/web:），按前缀分发到对应发送端。
//
// 未带前缀的历史令牌按 apns: 处理，保持向后兼容；对应平台未配置凭证时返回
// ErrNotConfigured，调用方应计入失败但**不要删除令牌**（换配置后仍可恢复）。

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// ErrNotConfigured 表示该平台的推送凭证尚未由部署者配置。
var ErrNotConfigured = errors.New("该平台推送尚未配置凭证")

// Router 按令牌前缀把唤醒推送分发给不同平台的实现。
// 零值可用：所有平台都未配置，PushSilent 一律返回 ErrNotConfigured。
type Router struct {
	APNs    PushSilentSender
	FCM     PushSilentSender
	WebPush PushSilentSender
}

// PushSilentSender 与 directory.PushSender 保持同签名，便于直接注入。
type PushSilentSender interface {
	PushSilent(ctx context.Context, account, deviceToken string) error
}

// NewRouter 构造路由；任一实现为 nil 即代表该平台未配置。
func NewRouter(apns, fcm, web PushSilentSender) *Router {
	return &Router{APNs: apns, FCM: fcm, WebPush: web}
}

// PushSilent 解析前缀后调用对应发送端，并把前缀从令牌中剥离。
func (r *Router) PushSilent(ctx context.Context, account, rawToken string) error {
	platform, token := SplitToken(rawToken)
	if token == "" {
		return fmt.Errorf("%w: 设备令牌为空", ErrBadToken)
	}
	var sender PushSilentSender
	switch platform {
	case "apns":
		sender = r.APNs
	case "fcm":
		sender = r.FCM
	case "web":
		sender = r.WebPush
	default:
		return fmt.Errorf("%w: 未知推送平台 %q", ErrBadToken, platform)
	}
	if sender == nil {
		return fmt.Errorf("%w: %s", ErrNotConfigured, platform)
	}
	return sender.PushSilent(ctx, account, token)
}

// SplitToken 把 "fcm:xxx" 拆成 ("fcm", "xxx")；无前缀时默认 apns。
func SplitToken(raw string) (platform, token string) {
	raw = strings.TrimSpace(raw)
	if i := strings.IndexByte(raw, ':'); i > 0 {
		prefix := strings.ToLower(raw[:i])
		switch prefix {
		case "apns", "fcm", "web":
			return prefix, strings.TrimSpace(raw[i+1:])
		}
	}
	return "apns", raw
}

// PrefixToken 给原始设备令牌加平台前缀，供客户端上报时统一使用。
func PrefixToken(platform, raw string) string {
	platform = strings.ToLower(strings.TrimSpace(platform))
	switch platform {
	case "fcm", "web", "apns":
		return platform + ":" + strings.TrimSpace(raw)
	default:
		return "apns:" + strings.TrimSpace(raw)
	}
}
