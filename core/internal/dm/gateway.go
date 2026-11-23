package dm

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/contacts"
	"github.com/nexmem/core/internal/expiry"
)

// Gateway 把单聊能力接入网关的 dm.* 方法。
//
// Service 以提供者形式注入，使 core.start 能在内核启动前后切换实现；
// 未启动时统一返回 NOT_STARTED。Resolve 负责把对端账号解析为可直连地址，
// 为空时依赖 Service 自身的离线投递能力。
type Gateway struct {
	Service func() *Service
	Resolve func(ctx context.Context, accountPub []byte) (Target, error)
}

// Bind 注册 dm.sendText / dm.sendFile。
func Bind(g *gateway.Gateway, gw *Gateway) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	if gw == nil || gw.Service == nil {
		return errors.New("缺少单聊服务")
	}
	handlers := map[string]gateway.HandlerFunc{
		"dm.sendText":    gw.sendTextHandler(),
		"dm.sendFile":    gw.sendFileHandler(),
		"dm.setTyping":   gw.setTypingHandler(),
		"rtc.sendSignal": gw.sendSignalHandler(),
	}
	for method, h := range handlers {
		if err := g.SetHandler(method, h); err != nil {
			return err
		}
	}
	return nil
}

func (gw *Gateway) service() (*Service, *gateway.Error) {
	svc := gw.Service()
	if svc == nil {
		return nil, gateway.NewError(gateway.CodeNotStarted, "单聊服务尚未接入内核")
	}
	return svc, nil
}

// target 解析对端账号；解析失败按 PEER_UNREACHABLE 返回。
func (gw *Gateway) target(ctx context.Context, accountPub []byte) (Target, *gateway.Error) {
	if gw.Resolve == nil {
		return Target{AccountPub: accountPub}, nil
	}
	t, err := gw.Resolve(ctx, accountPub)
	if err != nil {
		if errors.Is(err, ErrInvalidTarget) {
			return Target{}, gateway.NewError(gateway.CodeInvalidArg, "对端账号非法: %v", err)
		}
		return Target{}, gateway.NewError(gateway.CodePeerUnreachable, "解析对端地址失败: %v", err)
	}
	t.AccountPub = accountPub
	return t, nil
}

func (gw *Gateway) sendTextHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer     string   `json:"peer"`
			Text     string   `json:"text"`
			ReplyTo  string   `json:"reply_to"`
			Mentions []string `json:"mentions"`
			TTLHours uint32   `json:"ttl_hours"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "dm.sendText 参数不是合法 JSON: %v", err)
		}
		if err := expiry.Validate(req.TTLHours); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "dm.sendText ttl_hours 非法: %v", err)
		}
		peerPub, err := contacts.ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "对端账号非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		t, gerr := gw.target(ctx, peerPub)
		if gerr != nil {
			return nil, gerr
		}
		msgID, err := svc.SendTextWithOptions(ctx, t, req.Text, req.ReplyTo, req.Mentions, req.TTLHours)
		if err != nil && msgID == "" {
			return nil, mapSendError("发送文本失败", err)
		}
		// 已入库的消息即便直连失败也会进入离线队列重试，
		// 发送状态由 message.updated 事件推进，这里仍返回 msg_uuid。
		return map[string]any{"msg_uuid": msgID}, nil
	}
}

func (gw *Gateway) sendFileHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer string `json:"peer"`
			Path string `json:"path"`
			Mime string `json:"mime"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "dm.sendFile 参数不是合法 JSON: %v", err)
		}
		peerPub, err := contacts.ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "对端账号非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		t, gerr := gw.target(ctx, peerPub)
		if gerr != nil {
			return nil, gerr
		}
		msgID, err := svc.SendFile(ctx, t, req.Path, req.Mime)
		if err != nil && msgID == "" {
			return nil, mapSendError("发送文件失败", err)
		}
		return map[string]any{"msg_uuid": msgID}, nil
	}
}

// setTypingHandler 发送单聊输入状态（七-3）。typing 是尽力而为的瞬时能力：
// 对端不可达或拉黑时不作为业务错误返回，始终成功，避免打断用户输入。
func (gw *Gateway) setTypingHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer   string `json:"peer"`
			Typing bool   `json:"typing"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "dm.setTyping 参数不是合法 JSON: %v", err)
		}
		peerPub, err := contacts.ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "对端账号非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		t, gerr := gw.target(ctx, peerPub)
		if gerr != nil {
			return nil, gerr
		}
		_ = svc.SendTyping(ctx, t, req.Typing)
		return map[string]any{}, nil
	}
}

// sendSignalHandler 透传 RTC 信令（SDP / ICE），载荷按 base64 接收。
func (gw *Gateway) sendSignalHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer       string `json:"peer"`
			PayloadB64 string `json:"payload_b64"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "rtc.sendSignal 参数不是合法 JSON: %v", err)
		}
		peerPub, err := contacts.ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "对端账号非法: %v", err)
		}
		payload, err := decodeSignalPayload(req.PayloadB64)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "RTC 信令载荷非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		t, gerr := gw.target(ctx, peerPub)
		if gerr != nil {
			return nil, gerr
		}
		if err := svc.SendSignal(ctx, t, payload); err != nil {
			return nil, mapSignalError("发送 RTC 信令失败", err)
		}
		return map[string]any{}, nil
	}
}

// decodeSignalPayload 解析 base64 信令载荷，兼容标准/URL 与有无填充四种编码。
func decodeSignalPayload(raw string) ([]byte, error) {
	if raw == "" {
		return nil, ErrEmptySignal
	}
	// 先按编码长度上界拦截，避免超大字符串进入解码。
	if len(raw) > (MaxRTCSignalSize/3+1)*4 {
		return nil, ErrSignalTooLarge
	}
	encodings := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	var firstErr error
	for _, enc := range encodings {
		data, err := enc.DecodeString(raw)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if len(data) > MaxRTCSignalSize {
			return nil, ErrSignalTooLarge
		}
		return data, nil
	}
	return nil, firstErr
}

// mapSignalError 把 RTC 信令错误翻译为契约错误码。
func mapSignalError(prefix string, err error) *gateway.Error {
	switch {
	case errors.Is(err, ErrEmptySignal), errors.Is(err, ErrSignalTooLarge),
		errors.Is(err, ErrInvalidTarget), errors.Is(err, ErrSelfSend), errors.Is(err, ErrPeerBlocked):
		return gateway.NewError(gateway.CodeInvalidArg, "%s: %v", prefix, err)
	case errors.Is(err, ErrPeerRejected), errors.Is(err, ErrPeerUnreached):
		return gateway.NewError(gateway.CodePeerUnreachable, "%s: %v", prefix, err)
	default:
		return gateway.NewError(gateway.CodeS3IO, "%s: %v", prefix, err)
	}
}

// mapSendError 把单聊错误翻译为契约错误码。
func mapSendError(prefix string, err error) *gateway.Error {
	switch {
	case errors.Is(err, ErrEmptyText), errors.Is(err, ErrInvalidTarget):
		return gateway.NewError(gateway.CodeInvalidArg, "%s: %v", prefix, err)
	case errors.Is(err, ErrOfflineDisabled), errors.Is(err, ErrOfflineNoTickets):
		return gateway.NewError(gateway.CodeOfflineStorageDisabled, "%s: %v", prefix, err)
	case errors.Is(err, ErrOfflineNotConfigured), errors.Is(err, ErrPeerUnreached):
		return gateway.NewError(gateway.CodePeerUnreachable, "%s: %v", prefix, err)
	default:
		return gateway.NewError(gateway.CodeS3IO, "%s: %v", prefix, err)
	}
}
