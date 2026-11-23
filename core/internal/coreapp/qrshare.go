package coreapp

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/qrshare"
)

// qrPayloadHandler 实现 account.qrPayload：用当前账号私钥签发加好友二维码名片。
func (a *App) qrPayloadHandler() gateway.HandlerFunc {
	return func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
		a.mu.RLock()
		acc := a.account
		cfg := a.cfg
		h := a.host
		a.mu.RUnlock()
		if acc == nil || h == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		payload, err := qrshare.Encode(acc, h.ID().String(), cfg.DisplayName)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "生成二维码名片失败: %v", err)
		}
		return map[string]any{
			"payload":    payload,
			"account_id": acc.ID(),
			"device_id":  h.ID().String(),
		}, nil
	}
}

// qrParseHandler 实现 account.qrParse：解析并验签扫描到的二维码名片。
func (a *App) qrParseHandler() gateway.HandlerFunc {
	return func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Payload string `json:"payload"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "account.qrParse 参数不是合法 JSON: %v", err)
		}
		if req.Payload == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "account.qrParse 缺少必填参数 payload")
		}
		card, err := qrshare.Decode(req.Payload)
		if err != nil {
			switch {
			case errors.Is(err, qrshare.ErrSignature):
				return nil, gateway.NewError(gateway.CodeInvalidArg, "二维码名片验签失败，可能被篡改")
			case errors.Is(err, qrshare.ErrVersion):
				return nil, gateway.NewError(gateway.CodeInvalidArg, "二维码名片版本不支持")
			default:
				return nil, gateway.NewError(gateway.CodeInvalidArg, "二维码名片格式非法: %v", err)
			}
		}
		return map[string]any{
			"account_id":   card.AccountID,
			"device_id":    card.DeviceID,
			"display_name": card.DisplayName,
		}, nil
	}
}
