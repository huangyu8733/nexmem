package social

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/store"
)

// BindProvider 把社交能力接入网关。provider 返回 nil 时统一 NOT_STARTED。
func BindProvider(g *gateway.Gateway, provider func() *Service) error {
	if g == nil || provider == nil {
		return errors.New("缺少网关或服务提供者")
	}
	wrap := func(inner func(*Service) gateway.HandlerFunc) gateway.HandlerFunc {
		return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
			svc := provider()
			if svc == nil {
				return nil, gateway.NewError(gateway.CodeNotStarted, "社交服务尚未接入内核")
			}
			return inner(svc)(ctx, params)
		}
	}
	handlers := map[string]gateway.HandlerFunc{
		"friend.request.send":    wrap(sendFriendReqHandler),
		"friend.request.list":    wrap(listFriendReqHandler),
		"friend.request.respond": wrap(respondFriendReqHandler),
		"friend.request.count":   wrap(countFriendReqHandler),
		"friend.request.delete":  wrap(deleteFriendReqHandler),
		"friend.request.clear":   wrap(clearFriendReqHandler),
		"group.join.request":     wrap(requestGroupJoinHandler),
		"group.join.list":        wrap(listGroupJoinHandler),
		"group.join.respond":     wrap(respondGroupJoinHandler),
		"group.join.delete":      wrap(deleteGroupJoinHandler),
		"group.join.clear":       wrap(clearGroupJoinHandler),
		"group.member.set":       wrap(setMemberHandler),
		"presence.list":          wrap(presenceHandler),
		"notification.list":      wrap(listNotifHandler),
		"notification.read":      wrap(readNotifHandler),
		"notification.delete":    wrap(deleteNotifHandler),
		"notification.clear":     wrap(clearNotifHandler),
		"moment.post":            wrap(postMomentHandler),
		"moment.list":            wrap(listMomentHandler),
		"moment.like":            wrap(likeMomentHandler),
		"moment.comment":         wrap(commentMomentHandler),
		"poll.create":            wrap(createPollHandler),
		"poll.list":              wrap(listPollHandler),
		"poll.vote":              wrap(votePollHandler),
	}
	for m, h := range handlers {
		if err := g.SetHandler(m, h); err != nil {
			return err
		}
	}
	return nil
}

func decodeAccount(s string) ([]byte, *gateway.Error) {
	if s == "" {
		return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少账号公钥")
	}
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 32 {
		return nil, gateway.NewError(gateway.CodeInvalidArg, "账号公钥非法")
	}
	return b, nil
}

func sendFriendReqHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Peer    string `json:"peer"`
			Message string `json:"message"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "参数错误: %v", err)
		}
		peer, ge := decodeAccount(req.Peer)
		if ge != nil {
			return nil, ge
		}
		id, err := s.SendFriendRequest(ctx, peer, req.Message)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "发送好友申请失败: %v", err)
		}
		return map[string]any{"id": id}, nil
	}
}

func friendReqJSON(r store.FriendRequest) map[string]any {
	return map[string]any{
		"id": r.ID, "from": hex.EncodeToString(r.FromPub), "to": hex.EncodeToString(r.ToPub),
		"message": r.Message, "status": r.Status, "direction": r.Direction,
		"created_at": r.CreatedAt, "responded_at": r.RespondedAt,
	}
}

func listFriendReqHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Status *int `json:"status"`
			Limit  int  `json:"limit"`
		}
		if len(params) > 0 {
			_ = json.Unmarshal(params, &req)
		}
		rows, err := s.dao.ListFriendRequests(ctx, s.self(), req.Status, req.Limit)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取好友申请失败: %v", err)
		}
		items := make([]map[string]any, 0, len(rows))
		for _, r := range rows {
			items = append(items, friendReqJSON(r))
		}
		return map[string]any{"items": items}, nil
	}
}

func respondFriendReqHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID     string `json:"id"`
			Accept *bool  `json:"accept"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" || req.Accept == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id 或 accept")
		}
		if err := s.RespondFriendRequest(ctx, req.ID, *req.Accept); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "处理好友申请失败: %v", err)
		}
		return map[string]any{"id": req.ID}, nil
	}
}

func countFriendReqHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		n, err := s.dao.CountPendingFriendRequests(ctx, s.self())
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "统计好友申请失败: %v", err)
		}
		return map[string]any{"count": n}, nil
	}
}

func deleteFriendReqHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id")
		}
		n, err := s.dao.DeleteFriendRequest(ctx, s.self(), req.ID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "删除好友申请失败: %v", err)
		}
		return map[string]any{"deleted": n}, nil
	}
}

func clearFriendReqHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, _ json.RawMessage) (any, *gateway.Error) {
		n, err := s.dao.ClearFriendRequests(ctx, s.self())
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "清空好友申请失败: %v", err)
		}
		return map[string]any{"deleted": n}, nil
	}
}

func requestGroupJoinHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID    string `json:"group_id"`
			GroupTitle string `json:"group_title"`
			Owner      string `json:"owner"`
			Message    string `json:"message"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.GroupID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 group_id")
		}
		id, err := s.RequestGroupJoin(ctx, req.GroupID, req.GroupTitle, req.Owner, req.Message)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "申请入群失败: %v", err)
		}
		return map[string]any{"id": id}, nil
	}
}

func groupJoinJSON(r store.GroupJoinRequest) map[string]any {
	return map[string]any{
		"id": r.ID, "group_id": r.GroupID, "group_title": r.GroupTitle,
		"applicant": hex.EncodeToString(r.Applicant), "message": r.Message,
		"status": r.Status, "direction": r.Direction,
		"created_at": r.CreatedAt, "responded_at": r.RespondedAt,
	}
}

func listGroupJoinHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
			Status  *int   `json:"status"`
			Limit   int    `json:"limit"`
		}
		if len(params) > 0 {
			_ = json.Unmarshal(params, &req)
		}
		rows, err := s.dao.ListGroupJoinRequests(ctx, s.self(), req.GroupID, req.Status, req.Limit)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取入群申请失败: %v", err)
		}
		items := make([]map[string]any, 0, len(rows))
		for _, r := range rows {
			items = append(items, groupJoinJSON(r))
		}
		return map[string]any{"items": items}, nil
	}
}

func respondGroupJoinHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID     string `json:"id"`
			Accept *bool  `json:"accept"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" || req.Accept == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id 或 accept")
		}
		if err := s.RespondGroupJoin(ctx, req.ID, *req.Accept); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "处理入群申请失败: %v", err)
		}
		return map[string]any{"id": req.ID}, nil
	}
}

func deleteGroupJoinHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id")
		}
		n, err := s.dao.DeleteGroupJoinRequest(ctx, s.self(), req.ID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "删除入群申请失败: %v", err)
		}
		return map[string]any{"deleted": n}, nil
	}
}

func clearGroupJoinHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, _ json.RawMessage) (any, *gateway.Error) {
		n, err := s.dao.ClearGroupJoinRequests(ctx, s.self())
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "清空入群申请失败: %v", err)
		}
		return map[string]any{"deleted": n}, nil
	}
}

func setMemberHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID  string `json:"group_id"`
			Account  string `json:"account"`
			Role     string `json:"role"`
			Title    string `json:"title"`
			MuteMins int    `json:"mute_minutes"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.GroupID == "" || req.Account == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 group_id 或 account")
		}
		if err := s.SetMemberRole(ctx, req.GroupID, req.Account, req.Role, req.Title, req.MuteMins); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "设置成员失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

func presenceHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Accounts []string `json:"accounts"`
		}
		if len(params) > 0 {
			_ = json.Unmarshal(params, &req)
		}
		items, err := s.ListPresence(ctx, req.Accounts)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取在线状态失败: %v", err)
		}
		return map[string]any{"items": items}, nil
	}
}

func notificationJSON(n store.Notification) map[string]any {
	return map[string]any{
		"id": n.ID, "kind": n.Kind, "title": n.Title, "body": n.Body,
		"payload": n.Payload, "read": n.Read, "created_at": n.CreatedAt,
	}
}

func listNotifHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Limit      int  `json:"limit"`
			UnreadOnly bool `json:"unread_only"`
		}
		if len(params) > 0 {
			_ = json.Unmarshal(params, &req)
		}
		rows, err := s.dao.ListNotifications(ctx, req.Limit, req.UnreadOnly)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取通知失败: %v", err)
		}
		items := make([]map[string]any, 0, len(rows))
		for _, n := range rows {
			items = append(items, notificationJSON(n))
		}
		unread, _ := s.dao.CountUnreadNotifications(ctx)
		return map[string]any{"items": items, "unread": unread}, nil
	}
}

func readNotifHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID string `json:"id"`
		}
		_ = json.Unmarshal(params, &req)
		var err error
		if req.ID != "" {
			err = s.dao.MarkNotificationRead(ctx, req.ID)
		} else {
			err = s.dao.MarkAllNotificationsRead(ctx)
		}
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "标记通知已读失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

func deleteNotifHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id")
		}
		n, err := s.dao.DeleteNotification(ctx, req.ID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "删除通知失败: %v", err)
		}
		return map[string]any{"deleted": n}, nil
	}
}

func clearNotifHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, _ json.RawMessage) (any, *gateway.Error) {
		n, err := s.dao.ClearNotifications(ctx)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "清空通知失败: %v", err)
		}
		return map[string]any{"deleted": n}, nil
	}
}

func postMomentHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Text        string   `json:"text"`
			Attachments string   `json:"attachments"`
			Peers       []string `json:"peers"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.Text == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 text")
		}
		peers := make([][]byte, 0, len(req.Peers))
		for _, p := range req.Peers {
			if b, err := hex.DecodeString(p); err == nil && len(b) == 32 {
				peers = append(peers, b)
			}
		}
		id, err := s.PostMoment(ctx, req.Text, req.Attachments, peers)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "发布动态失败: %v", err)
		}
		return map[string]any{"id": id}, nil
	}
}

func momentJSON(m store.Moment) map[string]any {
	return map[string]any{
		"id": m.ID, "author": hex.EncodeToString(m.AccountPub), "text": m.Text,
		"attachments": m.Attachments, "likes": m.Likes, "created_at": m.CreatedAt,
	}
}

func listMomentHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Limit int `json:"limit"`
		}
		if len(params) > 0 {
			_ = json.Unmarshal(params, &req)
		}
		rows, err := s.dao.ListMoments(ctx, req.Limit)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取动态失败: %v", err)
		}
		items := make([]map[string]any, 0, len(rows))
		for _, m := range rows {
			items = append(items, momentJSON(m))
		}
		return map[string]any{"items": items}, nil
	}
}

func likeMomentHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID     string `json:"id"`
			Unlike bool   `json:"unlike"`
			Voter  string `json:"voter"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id")
		}
		voter := req.Voter
		if voter == "" {
			voter = hex.EncodeToString(s.self())
		}
		var err error
		if req.Unlike {
			err = s.dao.RemoveMomentLike(ctx, req.ID, voter)
		} else {
			_, err = s.dao.AddMomentLike(ctx, req.ID, voter)
		}
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "点赞失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

func commentMomentHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID   string `json:"id"`
			Text string `json:"text"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" || req.Text == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id 或 text")
		}
		err := s.dao.InsertMomentComment(ctx, store.MomentComment{
			ID: newID(), MomentID: req.ID, AccountPub: s.self(), Text: req.Text,
		})
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "评论失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

func createPollHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID  string   `json:"group_id"`
			Question string   `json:"question"`
			Options  []string `json:"options"`
			ClosesAt int64    `json:"closes_at"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.GroupID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 group_id")
		}
		id, err := s.CreatePoll(ctx, req.GroupID, req.Question, req.Options, req.ClosesAt)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "创建投票失败: %v", err)
		}
		return map[string]any{"id": id}, nil
	}
}

func listPollHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
			Limit   int    `json:"limit"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.GroupID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 group_id")
		}
		rows, err := s.dao.ListGroupPolls(ctx, req.GroupID, req.Limit)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取投票失败: %v", err)
		}
		items := make([]map[string]any, 0, len(rows))
		for _, p := range rows {
			items = append(items, map[string]any{
				"id": p.ID, "group_id": p.GroupID, "creator": hex.EncodeToString(p.Creator),
				"question": p.Question, "options": p.Options, "votes": p.Votes,
				"created_at": p.CreatedAt, "closes_at": p.ClosesAt,
			})
		}
		return map[string]any{"items": items}, nil
	}
}

func votePollHandler(s *Service) gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			ID     string `json:"id"`
			Option int    `json:"option"`
		}
		if err := json.Unmarshal(params, &req); err != nil || req.ID == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 id")
		}
		votes, err := s.VotePoll(ctx, req.ID, req.Option)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "投票失败: %v", err)
		}
		return map[string]any{"votes": votes}, nil
	}
}
