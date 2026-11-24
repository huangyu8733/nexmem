package contacts

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/store"
)

// Bind 把联系人能力接入网关的 contact.* 方法。
func Bind(g *gateway.Gateway, svc *Service) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	if svc == nil {
		return errors.New("缺少联系人服务")
	}
	return BindProvider(g, func() *Service { return svc })
}

// BindProvider 以提供者形式接入联系人能力：提供者返回 nil 时（内核未启动）
// 统一返回 NOT_STARTED，便于 core.start 在启动前后切换实现。
func BindProvider(g *gateway.Gateway, provider func() *Service) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	if provider == nil {
		return errors.New("缺少联系人服务提供者")
	}
	wrap := func(inner func(*Service) gateway.HandlerFunc) gateway.HandlerFunc {
		return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
			svc := provider()
			if svc == nil {
				return nil, gateway.NewError(gateway.CodeNotStarted, "联系人服务尚未接入内核")
			}
			return inner(svc)(ctx, params)
		}
	}
	handlers := map[string]gateway.HandlerFunc{
		"contact.list":     wrap(listHandler),
		"contact.add":      wrap(addHandler),
		"contact.block":    wrap(blockHandler),
		"contact.remark":   wrap(remarkHandler),
		"contact.setGroup": wrap(setGroupHandler),
		"contact.delete":   wrap(deleteHandler),
	}
	for method, h := range handlers {
		if err := g.SetHandler(method, h); err != nil {
			return err
		}
	}
	return nil
}

// ParseAccountID 解析契约中的 peer 字符串：支持十六进制（identity.Account.ID）
// 与无填充 base64url 两种编码。
func ParseAccountID(s string) ([]byte, error) {
	if s == "" {
		return nil, ErrEmptyPeer
	}
	if raw, err := hex.DecodeString(s); err == nil {
		if len(raw) == 32 {
			return raw, nil
		}
	}
	if raw, err := base64.RawURLEncoding.DecodeString(s); err == nil {
		if len(raw) == 32 {
			return raw, nil
		}
	}
	return nil, ErrInvalidPeer
}

func listHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Limit int `json:"limit"`
		}
		if len(params) > 0 {
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.list 参数不是合法 JSON: %v", err)
			}
		}
		rows, err := svc.List(ctx, req.Limit)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取联系人失败: %v", err)
		}
		items := make([]map[string]any, 0, len(rows))
		for _, c := range rows {
			items = append(items, contactJSON(c))
		}
		return map[string]any{"items": items}, nil
	}
}

func addHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer  string `json:"peer"`
			Alias string `json:"alias"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.add 参数不是合法 JSON: %v", err)
		}
		peer, err := ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.add 的 peer 非法: %v", err)
		}
		if _, err := svc.AddWithAlias(ctx, peer, req.Alias); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "添加联系人失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

func blockHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer    string `json:"peer"`
			Blocked *bool  `json:"blocked"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.block 参数不是合法 JSON: %v", err)
		}
		if req.Blocked == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.block 缺少 blocked")
		}
		peer, err := ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.block 的 peer 非法: %v", err)
		}
		if err := svc.SetBlocked(ctx, peer, *req.Blocked); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "更新拉黑状态失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

func remarkHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer   string `json:"peer"`
			Remark string `json:"remark"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.remark 参数不是合法 JSON: %v", err)
		}
		peer, err := ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.remark 的 peer 非法: %v", err)
		}
		if err := svc.Remark(ctx, peer, req.Remark); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "更新备注失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

func setGroupHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer  string `json:"peer"`
			Group string `json:"group"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.setGroup 参数不是合法 JSON: %v", err)
		}
		peer, err := ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.setGroup 的 peer 非法: %v", err)
		}
		if err := ValidateContactGroup(strings.TrimSpace(req.Group)); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%v", err)
		}
		group, err := svc.SetGroup(ctx, peer, req.Group)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "更新好友分组失败: %v", err)
		}
		return map[string]any{"group": group}, nil
	}
}

// deleteHandler 处理 contact.delete：仅删除本机联系人记录与备注，
// 不影响对端，也不删除已有聊天记录。
func deleteHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer string `json:"peer"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.delete 参数不是合法 JSON: %v", err)
		}
		peer, err := ParseAccountID(req.Peer)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "contact.delete 的 peer 非法: %v", err)
		}
		if err := svc.Remove(ctx, peer); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "删除联系人失败: %v", err)
		}
		return map[string]any{"peer": req.Peer}, nil
	}
}

func contactJSON(c store.Contact) map[string]any {
	return map[string]any{
		"account_pub": hex.EncodeToString(c.AccountPub),
		"alias":       c.Alias,
		"group_name":  c.GroupName,
		"blocked":     c.Blocked,
		"updated_at":  c.UpdatedAt,
	}
}
