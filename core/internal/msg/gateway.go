// Package msg 把消息检索与已读推进接入网关的 msg.* 方法（P6-07）。
//
// DAO 以提供者形式注入，使 core.start 能在内核启动前后切换实现；
// 未启动时统一返回 NOT_STARTED，与其它运行期装配的服务保持一致。
package msg

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/store"
)

// maxListLimit 是单页消息条数上限，与契约 msg.list 的 limit.maximum 一致。
const maxListLimit = 200

// Service 提供消息检索与已读推进能力。
type Service struct {
	// DAO 返回当前已打开的本地库；返回 nil 表示内核尚未启动。
	DAO func() *store.DAO

	// Account 返回本机账号公钥，用于从单聊会话 ID 反解对端账号；
	// 未注入时 conversation.list 不返回 peer 字段。
	Account func() []byte

	// ReadNotifier 在已读位置推进后回调（P6-07 已读回执）；由核心装配注入，
	// 负责把水位经单聊通道发给对端。回调需非阻塞，不能拖慢 msg.markRead。
	ReadNotifier func(conversationID string, upTo int64)

	// OnRecalled 在本机消息删除后回调，由核心装配发出 message.recalled
	// 并异步通知对端（P6-12）。回调必须立即返回，不能阻塞撤回请求。
	OnRecalled func(conversationID, msgUUID string)

	// OnEdited 在本机消息正文更新后回调，由核心装配发出 message.edited
	// 并异步通知对端（七-2 消息编辑）。回调必须立即返回，不能阻塞编辑请求。
	OnEdited func(conversationID, msgUUID, text string, editedAt int64)
}

// Bind 把消息服务接入网关的 conversation.list 与 msg.* 方法。
func Bind(g *gateway.Gateway, svc *Service) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	if svc == nil {
		return errors.New("缺少消息服务")
	}
	handlers := map[string]gateway.HandlerFunc{
		"conversation.list":   listConversationsHandler(svc),
		"conversation.update": updateConversationHandler(svc),
		"conversation.delete": deleteConversationHandler(svc),
		"conversation.clear":  clearConversationHandler(svc),
		"msg.list":            listHandler(svc),
		"msg.listSince":       listSinceHandler(svc),
		"msg.search":          searchHandler(svc),
		"msg.markRead":        markReadHandler(svc),
		"msg.delete":          deleteMessageHandler(svc),
		"msg.recall":          recallMessageHandler(svc),
		"msg.edit":            editMessageHandler(svc),
	}
	for method, h := range handlers {
		if err := g.SetHandler(method, h); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) dao() (*store.DAO, *gateway.Error) {
	if s.DAO == nil {
		return nil, gateway.NewError(gateway.CodeNotStarted, "消息服务尚未接入内核")
	}
	dao := s.DAO()
	if dao == nil {
		return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
	}
	return dao, nil
}

// conversationDefaultLimit / conversationMaxLimit 与契约 conversation.list 一致。
const (
	conversationDefaultLimit = 50
	conversationMaxLimit     = 200
)

// listConversationsHandler 返回会话列表首页（P1-22）。
//
// 排序语义与 `store.ListConversations` 一致（最近消息时间倒序），并用
// limit+1 探测 has_more；单聊会话反解出 peer 供客户端直接调用 dm.sendText，
// 群聊会话的标题以 groups 表为准，避免多端标题不一致。
func listConversationsHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		if len(bytes.TrimSpace(params)) == 0 {
			params = json.RawMessage(`{}`)
		}
		var req struct {
			Limit int `json:"limit"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.list 参数不是合法 JSON: %v", err)
		}
		limit := req.Limit
		if limit == 0 {
			limit = conversationDefaultLimit
		}
		if limit < 1 || limit > conversationMaxLimit {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.list 的 limit 需在 1～%d 之间", conversationMaxLimit)
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		convs, err := dao.ListConversationsLimit(ctx, limit+1)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取会话列表失败: %v", err)
		}
		hasMore := len(convs) > limit
		if hasMore {
			convs = convs[:limit]
		}
		items := make([]map[string]any, 0, len(convs))
		for _, c := range convs {
			items = append(items, conversationItem(ctx, dao, svc.account(), c))
		}
		return map[string]any{"items": items, "has_more": hasMore}, nil
	}
}

// updateConversationHandler 设置会话本机标记：置顶（影响列表排序）与免打扰（P6-17）。
//
// 两个标记都只在本机生效，不上行；未提供任何标记时返回 INVALID_ARG。
func updateConversationHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
			Pinned         *bool  `json:"pinned"`
			Muted          *bool  `json:"muted"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.update 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.update 缺少 conversation_id")
		}
		if req.Pinned == nil && req.Muted == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.update 至少需要 pinned 或 muted")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		if err := dao.SetConversationFlags(ctx, conversationID, req.Pinned, req.Muted); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"会话 %s 不存在", conversationID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "更新会话标记失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

// deleteConversationHandler 删除会话列表条目（P6-07 左滑 / 右键删除）。
//
// 只移除 conversations 行，历史消息保持不动：收到新消息时会话会重新落库，
// 与 ui-spec.md §2「删除会话不删聊天记录」的语义一致。
func deleteConversationHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.delete 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.delete 缺少 conversation_id")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		if err := dao.DeleteConversation(ctx, conversationID); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"会话 %s 不存在", conversationID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "删除会话失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

// clearConversationHandler 清空会话本机历史（P6-13 更多 → 清空聊天记录）。
//
// 只删除本机 messages 与检索索引，不影响对端；conversations 行保留，
// 会话仍留在列表且未读归零，与 ui-spec.md §3「更多 → 清空」的语义一致。
func clearConversationHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.clear 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"conversation.clear 缺少 conversation_id")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		if _, err := dao.GetConversation(ctx, conversationID); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"会话 %s 不存在", conversationID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "读取会话失败: %v", err)
		}
		deleted, err := dao.ClearConversationMessages(ctx, conversationID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "清空会话失败: %v", err)
		}
		return map[string]any{"deleted": deleted}, nil
	}
}

func (s *Service) account() []byte {
	if s.Account == nil {
		return nil
	}
	return s.Account()
}

// deleteMessageHandler 本地删除单条消息（P6-11 长按 / 右键菜单）。
//
// 只删本机消息与全文索引，不通知对端，也不回退会话摘要；非本会话的消息
// 与未知消息一律 INVALID_ARG，避免越权删除。
func deleteMessageHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
			MsgUUID        string `json:"msg_uuid"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"msg.delete 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"msg.delete 缺少 conversation_id")
		}
		msgUUID := strings.TrimSpace(req.MsgUUID)
		if msgUUID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"msg.delete 缺少 msg_uuid")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		msg, err := dao.GetMessage(ctx, msgUUID)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"消息 %s 不存在", msgUUID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "读取消息失败: %v", err)
		}
		if msg.ConversationID != conversationID {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"消息 %s 不属于会话 %s", msgUUID, conversationID)
		}
		if err := dao.DeleteMessage(ctx, msgUUID); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"消息 %s 不存在", msgUUID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "删除消息失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

// recallWindow 是撤回有效期，与 ui-spec.md §3「仅自己，2 分钟内」一致。
const recallWindow = 2 * time.Minute

// recallMessageHandler 撤回自己 2 分钟内发出的单聊或群聊消息（P6-12 / P6-14）。
//
// 只负责删本机并立即返回，对端或群内通知由 OnRecalled 异步完成；通知失败时
// 本地撤回仍然生效，不会阻塞请求。
func recallMessageHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
			MsgUUID        string `json:"msg_uuid"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"msg.recall 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"msg.recall 缺少 conversation_id")
		}
		msgUUID := strings.TrimSpace(req.MsgUUID)
		if msgUUID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"msg.recall 缺少 msg_uuid")
		}
		if !strings.HasPrefix(conversationID, "dm:") &&
			!strings.HasPrefix(conversationID, "group:") {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"msg.recall 仅支持单聊或群聊会话")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		msg, err := dao.GetMessage(ctx, msgUUID)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"消息 %s 不存在", msgUUID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "读取消息失败: %v", err)
		}
		if msg.ConversationID != conversationID {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"消息 %s 不属于会话 %s", msgUUID, conversationID)
		}
		if msg.Direction != store.DirectionOut {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"只能撤回自己发送的消息")
		}
		if msg.SentAt <= 0 || time.Since(time.UnixMilli(msg.SentAt)) > recallWindow {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"消息已超过 2 分钟，无法撤回")
		}
		if err := dao.DeleteMessage(ctx, msgUUID); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"消息 %s 不存在", msgUUID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "撤回消息失败: %v", err)
		}
		if svc.OnRecalled != nil {
			svc.OnRecalled(conversationID, msgUUID)
		}
		return map[string]any{"recalled": true}, nil
	}
}

// editWindow 是消息编辑的有效期（七-2）：只允许编辑 24 小时内自己发出的消息，
// 比撤回窗口宽松，但仍避免无限期改写历史造成对端认知偏差。
const editWindow = 24 * time.Hour

// editMessageHandler 编辑自己发出消息的正文（七-2）。
//
// 只改正文与 edited 标记，保留 reply_to / mentions / 附件等其它 InnerMessage 字段；
// 本机更新后回调 OnEdited 发 message.edited 事件并尽力通知对端/群成员。
func editMessageHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
			MsgUUID        string `json:"msg_uuid"`
			Text           string `json:"text"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.edit 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		msgUUID := strings.TrimSpace(req.MsgUUID)
		newText := req.Text
		if conversationID == "" || msgUUID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.edit 缺少 conversation_id 或 msg_uuid")
		}
		if !strings.HasPrefix(conversationID, "dm:") && !strings.HasPrefix(conversationID, "group:") {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.edit 仅支持单聊或群聊会话")
		}
		if strings.TrimSpace(newText) == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.edit 正文不能为空")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		msg, err := dao.GetMessage(ctx, msgUUID)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "消息 %s 不存在", msgUUID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "读取消息失败: %v", err)
		}
		if msg.ConversationID != conversationID {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "消息 %s 不属于会话 %s", msgUUID, conversationID)
		}
		if msg.Direction != store.DirectionOut {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "只能编辑自己发送的消息")
		}
		if msg.SentAt <= 0 || time.Since(time.UnixMilli(msg.SentAt)) > editWindow {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "消息已超过 24 小时，无法编辑")
		}
		inner := &nexmemv1.InnerMessage{}
		if err := proto.Unmarshal(msg.BodyEnc, inner); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "解析消息正文失败: %v", err)
		}
		editedAt := time.Now().UnixMilli()
		inner.Text = newText
		inner.Edited = true
		inner.EditedAt = editedAt
		bodyEnc, err := proto.Marshal(inner)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "序列化编辑正文失败: %v", err)
		}
		if err := dao.UpdateMessageBody(ctx, msgUUID, newText, bodyEnc); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "消息 %s 不存在", msgUUID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "编辑消息失败: %v", err)
		}
		if svc.OnEdited != nil {
			svc.OnEdited(conversationID, msgUUID, newText, editedAt)
		}
		return map[string]any{"edited": true, "msg_uuid": msgUUID}, nil
	}
}

// conversationItem 组装单个会话条目；正文只取最后一条消息的可展示文本。
func conversationItem(ctx context.Context, dao *store.DAO, self []byte, c store.Conversation) map[string]any {
	item := map[string]any{
		"conversation_id": c.ID,
		"kind":            conversationKindName(c.Kind),
		"title":           c.Title,
		"unread":          c.Unread,
		"pinned":          c.Pinned,
		"muted":           c.Muted,
	}
	if c.LastMsgAt > 0 {
		item["last_msg_at"] = c.LastMsgAt
	}
	if c.Kind == store.ConversationKindGroup {
		if groupID, ok := groupIDFromConversation(c.ID); ok {
			item["group_id"] = base64.RawURLEncoding.EncodeToString(groupID)
			if g, err := dao.GetGroup(ctx, groupID); err == nil {
				// 本机群备注优先于群名，空串时回落群名（P6-27）。
				if g.Alias != "" {
					item["title"] = g.Alias
				} else if g.Title != "" {
					item["title"] = g.Title
				}
			}
		}
	} else if peer, ok := peerFromConversation(c.ID, self); ok {
		item["peer"] = base64.RawURLEncoding.EncodeToString(peer)
	}
	msgs, err := dao.ListMessages(ctx, c.ID, nil, 1)
	if err != nil || len(msgs) == 0 {
		return item
	}
	if text := messageText(msgs[0]); text != "" {
		item["last_text"] = text
	}
	item["last_direction"] = directionName(msgs[0].Direction)
	return item
}

func conversationKindName(kind int) string {
	if kind == store.ConversationKindGroup {
		return "group"
	}
	return "dm"
}

// messageText 从 InnerMessage 解出正文；解不出时返回空串。
func messageText(m store.Message) string {
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(m.BodyEnc, inner); err != nil {
		return ""
	}
	return inner.GetText()
}

// peerFromConversation 从 `dm:<hex>|<hex>` 反解对端账号公钥。
func peerFromConversation(conversationID string, self []byte) ([]byte, bool) {
	if len(self) == 0 || !strings.HasPrefix(conversationID, "dm:") {
		return nil, false
	}
	parts := strings.Split(strings.TrimPrefix(conversationID, "dm:"), "|")
	if len(parts) != 2 {
		return nil, false
	}
	a, err := hex.DecodeString(parts[0])
	if err != nil {
		return nil, false
	}
	b, err := hex.DecodeString(parts[1])
	if err != nil {
		return nil, false
	}
	switch {
	case bytes.Equal(a, self):
		return b, true
	case bytes.Equal(b, self):
		return a, true
	default:
		return nil, false
	}
}

// groupIDFromConversation 从 `group:<base64url>` 解出群 ID。
func groupIDFromConversation(conversationID string) ([]byte, bool) {
	if !strings.HasPrefix(conversationID, "group:") {
		return nil, false
	}
	groupID, err := base64.RawURLEncoding.DecodeString(
		strings.TrimPrefix(conversationID, "group:"))
	if err != nil || len(groupID) == 0 {
		return nil, false
	}
	return groupID, true
}

func listHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
			BeforeID       string `json:"before_id"`
			Limit          int    `json:"limit"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.list 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.list 缺少 conversation_id")
		}
		if req.Limit <= 0 || req.Limit > maxListLimit {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.list 的 limit 需在 1～%d 之间", maxListLimit)
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}

		// before_id 指向上次已经拿到的最后一条消息，用于键集分页；
		// 必须属于同一会话，避免跨会话游标读到别人的消息。
		var cursor *store.MessageCursor
		if beforeID := strings.TrimSpace(req.BeforeID); beforeID != "" {
			m, err := dao.GetMessage(ctx, beforeID)
			if err != nil {
				if errors.Is(err, store.ErrNotFound) {
					return nil, gateway.NewError(gateway.CodeInvalidArg, "before_id %s 不存在", beforeID)
				}
				return nil, gateway.NewError(gateway.CodeDBError, "读取分页游标失败: %v", err)
			}
			if m.ConversationID != conversationID {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"before_id %s 不属于会话 %s", beforeID, conversationID)
			}
			cursor = &store.MessageCursor{SentAt: m.SentAt, MsgUUID: m.MsgUUID}
		}

		msgs, err := dao.ListMessages(ctx, conversationID, cursor, req.Limit)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取会话消息失败: %v", err)
		}
		items := make([]map[string]any, 0, len(msgs))
		for _, m := range msgs {
			items = append(items, messageItem(m))
		}
		return map[string]any{
			"items":    items,
			"has_more": len(msgs) == req.Limit,
		}, nil
	}
}

// listSinceLimit 是 msg.listSince 单次返回条数：契约未暴露 limit，
// 固定按页上限返回，客户端以末条 seq 作为下一次的 after_seq 直到拿到空页。
const listSinceLimit = maxListLimit

// listSinceHandler 按本机单调 seq 增量读取会话消息（P1-21）。
func listSinceHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
			AfterSeq       int64  `json:"after_seq"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.listSince 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.listSince 缺少 conversation_id")
		}
		if req.AfterSeq < 0 {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.listSince 的 after_seq 不能为负数")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		msgs, err := dao.ListMessagesSince(ctx, conversationID, req.AfterSeq, listSinceLimit)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "增量读取会话消息失败: %v", err)
		}
		items := make([]map[string]any, 0, len(msgs))
	for _, m := range msgs {
		items = append(items, messageItem(m))
	}
	return map[string]any{"items": items}, nil
	}
}

// messageItem 把本地消息转换为契约里的列表项；正文从 InnerMessage 解出，
// 仅返回展示所需的文本与附件元数据，不回传密文与传输原始帧。
func messageItem(m store.Message) map[string]any {
	item := map[string]any{
		"msg_uuid":        m.MsgUUID,
		"conversation_id": m.ConversationID,
		"sender_account":  base64.RawURLEncoding.EncodeToString(m.SenderAccount),
		"sent_at":         m.SentAt,
		"direction":       directionName(m.Direction),
		"content_type":    m.ContentType,
		"state":           stateName(m.State),
		// seq 是本机单调事件序号：msg.list 返回它供客户端建立增量基准，
		// msg.listSince 用同一字段作为 after_seq 游标（P6-31）。
		"seq": m.Seq,
	}
	// expires_at 是定时消息的本机销毁时间（Unix 毫秒，0 表示永不过期），
	// 供客户端展示倒计时；销毁本身由内核 sweeper 执行并发 message.expired。
	if m.ExpiresAt > 0 {
		item["expires_at"] = m.ExpiresAt
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(m.BodyEnc, inner); err != nil {
		return item
	}
	if text := inner.GetText(); text != "" {
		item["text"] = text
	}
	// reply_to 是被引用消息的 msg_uuid：仅非空时回显，客户端据此渲染引用条（P6-32）。
	if replyTo := inner.GetReplyTo(); replyTo != "" {
		item["reply_to"] = replyTo
	}
	// mentions / edited / edited_at 供 UI 渲染 @ 高亮与「已编辑」标记（七-1 / 七-2）。
	if mentions := inner.GetMentions(); len(mentions) > 0 {
		item["mentions"] = mentions
	}
	if inner.GetEdited() {
		item["edited"] = true
		item["edited_at"] = inner.GetEditedAt()
	}
	if atts := inner.GetAttachments(); len(atts) > 0 {
		list := make([]map[string]any, 0, len(atts))
		for _, a := range atts {
			entry := map[string]any{
				"name": a.GetName(),
				"size": a.GetSize(),
				"mime": a.GetMime(),
			}
			// 接收端落盘后把本地绝对路径写回 BlobRef；发送端不持有该字段。
			if ref := a.GetBlobRef(); ref != "" {
				entry["path"] = ref
			}
			// 群文件消息里的 BlobRef 是群盘对象键、Key 是附件 AES 密钥：
			// 一并回传给本机客户端，供 file.downloadGroup 取回并解密群文件。
			// 单聊发送端没有 BlobRef，不会输出这些字段。
			if ref := a.GetBlobRef(); ref != "" && a.GetKey() != nil {
				entry["blob_ref"] = ref
				entry["key_b64"] = base64.StdEncoding.EncodeToString(a.GetKey())
			}
			list = append(list, entry)
		}
		item["attachments"] = list
	}
	return item
}

func stateName(state int) string {
	switch state {
	case store.MessageStatePending:
		return "pending"
	case store.MessageStateSent:
		return "sent"
	case store.MessageStateAcked:
		return "acked"
	case store.MessageStateFailed:
		return "failed"
	case store.MessageStateReceived:
		return "received"
	case store.MessageStateRead:
		return "read"
	default:
		return "unknown"
	}
}

func searchHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Query          string `json:"q"`
			ConversationID string `json:"conversation_id"`
			Limit          int    `json:"limit"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.search 参数不是合法 JSON: %v", err)
		}
		query := strings.TrimSpace(req.Query)
		if query == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.search 关键词不能为空")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		hits, err := dao.SearchMessages(ctx, store.MessageSearchQuery{
			Query:          query,
			ConversationID: strings.TrimSpace(req.ConversationID),
			Limit:          req.Limit,
		})
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "检索消息失败: %v", err)
		}
		items := make([]map[string]any, 0, len(hits))
		for _, h := range hits {
			items = append(items, map[string]any{
				"msg_uuid":        h.MsgUUID,
				"conversation_id": h.ConversationID,
				"sent_at":         h.SentAt,
				"direction":       directionName(h.Direction),
				"snippet":         h.Snippet,
			})
		}
		return map[string]any{"items": items}, nil
	}
}

func markReadHandler(svc *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ConversationID string `json:"conversation_id"`
			UpToID         string `json:"up_to_id"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.markRead 参数不是合法 JSON: %v", err)
		}
		conversationID := strings.TrimSpace(req.ConversationID)
		if conversationID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "msg.markRead 缺少 conversation_id")
		}
		dao, gerr := svc.dao()
		if gerr != nil {
			return nil, gerr
		}
		if err := dao.SetConversationUnread(ctx, conversationID, 0); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "会话 %s 不存在", conversationID)
			}
			return nil, gateway.NewError(gateway.CodeDBError, "更新会话未读失败: %v", err)
		}
		if svc.ReadNotifier != nil {
			if upTo := readUpTo(ctx, dao, conversationID, req.UpToID); upTo > 0 {
				svc.ReadNotifier(conversationID, upTo)
			}
		}
		return map[string]any{}, nil
	}
}

// readUpTo 解析本次已读推进的水位：优先用客户端指定的消息时间戳，
// 否则取会话内最新的入站消息时间戳。出站消息不参与水位计算，
// 避免把对端尚未阅读的本机消息误标为已读（P6-07）。
func readUpTo(ctx context.Context, dao *store.DAO, conversationID, upToID string) int64 {
	var ceiling int64
	if id := strings.TrimSpace(upToID); id != "" {
		if m, err := dao.GetMessage(ctx, id); err == nil && m.ConversationID == conversationID {
			ceiling = m.SentAt
		}
	}
	upTo, err := dao.LatestInboundAt(ctx, conversationID, ceiling)
	if err != nil {
		return 0
	}
	return upTo
}

func directionName(direction int) string {
	if direction == store.DirectionOut {
		return "out"
	}
	return "in"
}
