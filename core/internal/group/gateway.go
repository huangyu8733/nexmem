package group

// 群聊网关方法（P1-20 群聊装配）。
//
// 把 P4 的群创建、成员查询、群盘配置与群文本发送接入统一网关契约：
//   - group.create    创建群并向成员分发群密钥信封
//   - group.list      列出本机已加入的群（成员数与本人角色，P4-13）
//   - group.members   读取本机群资料、成员表与群盘配置状态（P4-07 数据源）
//   - group.invite    管理员邀请新成员入群并同步成员表（P4-10）
//   - group.remove    管理员把成员移出群并轮换密钥（P4-10）
//   - group.leave     成员退出群聊，清理本地群记录与密钥（P4-12）
//   - group.dissolve  管理员解散群聊，通知成员并清理本地群（P4-12）
//   - group.setStorage 由管理员配置群盘
//   - group.setAnnouncement 由管理员设置群公告（P6-26）
//   - group.setAllowFriendAdd 由管理员开关「允许成员互加好友」（默认关闭）
//   - group.setAlias  任意成员设置本机群备注（P6-27）
//   - dm.sendGroupText 加密广播群文本并尽力写群盘（P4-05/P4-06）

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/contacts"
	filecrypto "github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/expiry"
)

// TargetResolver 把成员账号解析为密钥信封投递地址（含 account_x_pub）。
// 由 coreapp 基于索引服务档案 + DHT 实现；对端离线时 PeerID 可为空，
// 由 MetaSender 改走单聊离线通道。
type TargetResolver interface {
	ResolveTarget(ctx context.Context, accountPub []byte) (KeyTarget, error)
}

// TargetResolverFunc 让普通函数实现 TargetResolver。
type TargetResolverFunc func(ctx context.Context, accountPub []byte) (KeyTarget, error)

// ResolveTarget 实现 TargetResolver。
func (f TargetResolverFunc) ResolveTarget(ctx context.Context, accountPub []byte) (KeyTarget, error) {
	return f(ctx, accountPub)
}

// Gateway 把群聊能力接入网关；Service 以提供者形式注入，
// 未启动时统一返回 NOT_STARTED。
type Gateway struct {
	Service func() *Service
	Resolve func(ctx context.Context, accountPub []byte) (KeyTarget, error)
}

// Bind 注册 group.create / group.list / group.members / group.invite /
// group.remove / group.leave / group.dissolve / group.setStorage /
// group.setAnnouncement / group.setAllowFriendAdd / group.setAlias /
// dm.sendGroupText。
func Bind(g *gateway.Gateway, gw *Gateway) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	if gw == nil || gw.Service == nil {
		return errors.New("缺少群聊服务")
	}
	handlers := map[string]gateway.HandlerFunc{
		"group.setLevelConfig":    gw.setLevelConfigHandler(),
		"group.setMemberProfile":  gw.setMemberProfileHandler(),
		"group.create":            gw.createHandler(),
		"group.list":              gw.listHandler(),
		"group.members":           gw.membersHandler(),
		"group.invite":            gw.inviteHandler(),
		"group.remove":            gw.removeHandler(),
		"group.leave":             gw.leaveHandler(),
		"group.dissolve":          gw.dissolveHandler(),
		"group.setStorage":        gw.setStorageHandler(),
		"group.removeStorage":     gw.removeStorageHandler(),
		"group.setAnnouncement":   gw.setAnnouncementHandler(),
		"group.setAllowFriendAdd": gw.setAllowFriendAddHandler(),
		"group.setAlias":          gw.setAliasHandler(),
		"dm.sendGroupText":        gw.sendTextHandler(),
		"dm.sendGroupFile":        gw.sendFileHandler(),
		"file.downloadGroup":      gw.downloadFileHandler(),
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
		return nil, gateway.NewError(gateway.CodeNotStarted, "群聊服务尚未接入内核")
	}
	return svc, nil
}

// createHandler 处理 group.create：解析成员账号并投递 v1 群密钥。
func (gw *Gateway) createHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			Title   string   `json:"title"`
			Members []string `json:"members"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.create 参数不是合法 JSON: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		targets := make([]KeyTarget, 0, len(req.Members))
		for _, raw := range req.Members {
			pub, err := contacts.ParseAccountID(raw)
			if err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "成员账号非法: %v", err)
			}
			target, err := gw.resolve(ctx, pub)
			if err != nil {
				return nil, gateway.NewError(gateway.CodePeerUnreachable, "解析成员 %s 失败: %v", raw, err)
			}
			targets = append(targets, target)
		}
		key, reports, err := svc.CreateGroup(ctx, req.Title, targets)
		if err != nil {
			return nil, mapGroupError("创建群失败", err)
		}
		failed := 0
		for _, r := range reports {
			if r.Err != nil {
				failed++
			}
		}
		return map[string]any{
			"group_id": encodeGroupID(key.GroupID),
			"failed":   failed,
		}, nil
	}
}

// membersHandler 处理 group.members：返回群资料、成员表与群盘状态。
func (gw *Gateway) membersHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.members 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		info, err := svc.GroupInfo(ctx, groupID)
		if err != nil {
			return nil, mapGroupError("读取群成员失败", err)
		}
		members := make([]map[string]any, 0, len(info.Members))
		for _, m := range info.Members {
			role := "member"
			if m.Role == KeyRoleAdmin {
				role = "admin"
			}
			members = append(members, map[string]any{
				"account":   encodeAccountID(m.AccountPub),
				"role":      role,
				"joined_at": m.JoinedAt,
				"nickname":  m.Nickname,
				"level_id":  m.LevelID,
			})
		}
		levels := info.Levels
		if levels == nil {
			levels = []GroupLevel{}
		}
		return map[string]any{
			"group_id":           encodeGroupID(info.GroupID),
			"title":              info.Title,
			"alias":              info.Alias,
			"key_version":        info.KeyVersion,
			"storage_configured": info.StorageConfigured,
			"announcement":       info.Announcement,
			"allow_friend_add":   info.AllowFriendAdd,
			"level_enabled":      info.LevelsEnabled,
			"levels":             levels,
			"members":            members,
		}, nil
	}
}

// listHandler 处理 group.list：返回本机已加入的群与本人角色。
func (gw *Gateway) listHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct{}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.list 参数不是合法 JSON: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		infos, err := svc.ListGroups(ctx)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取群列表失败: %v", err)
		}
		self := svc.AccountPub()
		items := make([]map[string]any, 0, len(infos))
		for _, info := range infos {
			role := "member"
			for _, m := range info.Members {
				if !bytes.Equal(m.AccountPub, self) {
					continue
				}
				if m.Role == KeyRoleAdmin {
					role = "admin"
				}
				break
			}
			items = append(items, map[string]any{
				"group_id":           encodeGroupID(info.GroupID),
				"title":              info.Title,
				"alias":              info.Alias,
				"member_count":       len(info.Members),
				"role":               role,
				"key_version":        int(info.KeyVersion),
				"storage_configured": info.StorageConfigured,
				"announcement":       info.Announcement,
				"allow_friend_add":   info.AllowFriendAdd,
				"level_enabled":      info.LevelsEnabled,
			})
		}
		return map[string]any{"items": items}, nil
	}
}

// inviteHandler 处理 group.invite：管理员邀请账号入群，
// 把当前版本密钥信封分发给全体成员（含新成员）并同步成员表。
func (gw *Gateway) inviteHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
			Account string `json:"account"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.invite 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		accountPub, err := contacts.ParseAccountID(req.Account)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "成员账号非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		info, err := svc.GroupInfo(ctx, groupID)
		if err != nil {
			return nil, mapGroupError("读取群成员失败", err)
		}
		// 新成员必须有可用投递地址，否则密钥信封无法送达；
		// 其他成员解析失败只影响各自的成员表同步，不阻断邀请。
		target, err := gw.resolve(ctx, accountPub)
		if err != nil {
			return nil, gateway.NewError(gateway.CodePeerUnreachable, "解析成员地址失败: %v", err)
		}
		targets := make([]KeyTarget, 0, len(info.Members)+1)
		targets = append(targets, target)
		for _, m := range info.Members {
			if bytes.Equal(m.AccountPub, accountPub) {
				continue
			}
			if mt, rerr := gw.resolve(ctx, m.AccountPub); rerr == nil {
				targets = append(targets, mt)
			}
		}
		key, reports, err := svc.InviteMember(ctx, groupID, accountPub, targets)
		if err != nil {
			return nil, mapGroupError("邀请成员失败", err)
		}
		return map[string]any{
			"group_id":    encodeGroupID(groupID),
			"key_version": int(key.Version),
			"failed":      countFailedDeliveries(reports),
		}, nil
	}
}

// removeHandler 处理 group.remove：管理员移除成员，
// 立即轮换密钥并只向剩余成员分发新信封。
func (gw *Gateway) removeHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
			Account string `json:"account"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.remove 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		accountPub, err := contacts.ParseAccountID(req.Account)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "成员账号非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		info, err := svc.GroupInfo(ctx, groupID)
		if err != nil {
			return nil, mapGroupError("读取群成员失败", err)
		}
		targets := make([]KeyTarget, 0, len(info.Members))
		for _, m := range info.Members {
			if bytes.Equal(m.AccountPub, accountPub) {
				continue
			}
			if mt, rerr := gw.resolve(ctx, m.AccountPub); rerr == nil {
				targets = append(targets, mt)
			}
		}
		key, reports, err := svc.RemoveMember(ctx, groupID, accountPub, targets)
		if err != nil {
			return nil, mapGroupError("移除成员失败", err)
		}
		return map[string]any{
			"group_id":    encodeGroupID(groupID),
			"key_version": int(key.Version),
			"failed":      countFailedDeliveries(reports),
		}, nil
	}
}

// leaveHandler 处理 group.leave：成员退出群聊并清理本地群记录与密钥。
func (gw *Gateway) leaveHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		groupID, gerr := gw.groupIDParam("group.leave", params)
		if gerr != nil {
			return nil, gerr
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		if err := svc.LeaveGroup(ctx, groupID); err != nil {
			return nil, mapGroupError("退出群聊失败", err)
		}
		return map[string]any{}, nil
	}
}

// dissolveHandler 处理 group.dissolve：管理员解散群聊，广播控制帧后清理本地群。
func (gw *Gateway) dissolveHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		groupID, gerr := gw.groupIDParam("group.dissolve", params)
		if gerr != nil {
			return nil, gerr
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		if err := svc.DissolveGroup(ctx, groupID); err != nil {
			return nil, mapGroupError("解散群聊失败", err)
		}
		return map[string]any{}, nil
	}
}

// groupIDParam 解析只带 group_id 的请求参数。
func (gw *Gateway) groupIDParam(method string, params json.RawMessage) ([]byte, *gateway.Error) {
	var req struct {
		GroupID string `json:"group_id"`
	}
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, gateway.NewError(gateway.CodeInvalidArg, "%s 参数不是合法 JSON: %v", method, err)
	}
	groupID, err := parseGroupID(req.GroupID)
	if err != nil {
		return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
	}
	return groupID, nil
}

// countFailedDeliveries 统计密钥信封投递失败的成员数。
func countFailedDeliveries(reports []KeyDelivery) int {
	failed := 0
	for _, r := range reports {
		if r.Err != nil {
			failed++
		}
	}
	return failed
}

// setStorageHandler 处理 group.setStorage：管理员配置群盘并分发给成员。
func (gw *Gateway) setStorageHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID   string `json:"group_id"`
			Endpoint  string `json:"endpoint"`
			Bucket    string `json:"bucket"`
			Prefix    string `json:"prefix"`
			Region    string `json:"region"`
			AccessKey string `json:"ak"`
			SecretKey string `json:"sk"`
			PathStyle bool   `json:"path_style"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.setStorage 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		info, err := svc.GroupInfo(ctx, groupID)
		if err != nil {
			return nil, mapGroupError("读取群成员失败", err)
		}
		targets := make([]KeyTarget, 0, len(info.Members))
		for _, m := range info.Members {
			if self := svc.AccountPub(); len(self) > 0 && string(self) == string(m.AccountPub) {
				continue
			}
			target, rerr := gw.resolve(ctx, m.AccountPub)
			if rerr != nil {
				// 单个成员地址解析失败只影响它自己的配置下发，
				// 本机配置仍然生效，避免群盘配置完全不可用。
				continue
			}
			targets = append(targets, target)
		}
		cfg := StorageConfig{
			Endpoint:  req.Endpoint,
			Bucket:    req.Bucket,
			Prefix:    req.Prefix,
			Region:    req.Region,
			AccessKey: req.AccessKey,
			SecretKey: req.SecretKey,
			PathStyle: req.PathStyle,
		}
		if _, err := svc.ConfigureStorage(ctx, groupID, cfg, targets); err != nil {
			return nil, mapGroupError("配置群盘失败", err)
		}
		return map[string]any{}, nil
	}
}

// removeStorageHandler 处理 group.removeStorage：管理员移除群盘，
// 尽力清理云端密文并广播移除控制帧（C-05）。
func (gw *Gateway) removeStorageHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		groupID, gerr := gw.groupIDParam("group.removeStorage", params)
		if gerr != nil {
			return nil, gerr
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		deleted, err := svc.RemoveStorage(ctx, groupID)
		if err != nil {
			return nil, mapGroupError("移除群盘失败", err)
		}
		return map[string]any{"cloud_objects_deleted": deleted}, nil
	}
}

// setAnnouncementHandler 处理 group.setAnnouncement：管理员设置或清除群公告，
// 本机落库后以控制帧广播到群主题，供离线成员补收（P6-26）。
func (gw *Gateway) setAnnouncementHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID      string  `json:"group_id"`
			Announcement *string `json:"announcement"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.setAnnouncement 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		if req.Announcement == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 announcement")
		}
		text := *req.Announcement
		if utf8.RuneCountInString(text) > MaxAnnouncementRunes {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", ErrAnnouncementTooLong.Error())
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		saved, err := svc.SetAnnouncement(ctx, groupID, text)
		if err != nil {
			return nil, mapGroupError("设置群公告失败", err)
		}
		return map[string]any{"announcement": saved}, nil
	}
}

// setAllowFriendAddHandler 处理 group.setAllowFriendAdd：管理员开关群内互加好友，
// 本机落库后广播控制帧给成员；默认关闭，成员侧收到帧后校验管理员身份再应用。
func (gw *Gateway) setAllowFriendAddHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
			Enabled *bool  `json:"enabled"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.setAllowFriendAdd 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		if req.Enabled == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 enabled")
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		enabled, err := svc.SetAllowFriendAdd(ctx, groupID, *req.Enabled)
		if err != nil {
			return nil, mapGroupError("设置群加好友权限失败", err)
		}
		return map[string]any{"enabled": enabled}, nil
	}
}

// setLevelConfigHandler 处理 group.setLevelConfig：管理员开关群等级并配置等级列表。
// 本机落库后广播控制帧；关闭等级时清空全部成员等级 ID。
func (gw *Gateway) setLevelConfigHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string       `json:"group_id"`
			Enabled *bool        `json:"enabled"`
			Levels  []GroupLevel `json:"levels"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.setLevelConfig 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		if req.Enabled == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 enabled")
		}
		if req.Levels == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 levels")
		}
		cfg := LevelConfig{Enabled: *req.Enabled, Levels: req.Levels}
		if err := ValidateLevelConfig(cfg); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", err.Error())
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		saved, err := svc.SetLevelConfig(ctx, groupID, cfg)
		if err != nil {
			return nil, mapGroupError("设置群等级失败", err)
		}
		return map[string]any{"enabled": saved.Enabled, "levels": saved.Levels}, nil
	}
}

// setMemberProfileHandler 处理 group.setMemberProfile：成员改自己称呼或管理员改任意成员资料。
// 省略字段表示不变，空串表示清除；改动通过控制帧同步给成员。
func (gw *Gateway) setMemberProfileHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID  string  `json:"group_id"`
			Account  string  `json:"account"`
			Nickname *string `json:"nickname"`
			LevelID  *string `json:"level_id"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.setMemberProfile 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		accountPub, err := contacts.ParseAccountID(req.Account)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "成员账号非法: %v", err)
		}
		if req.Nickname != nil {
			if err := ValidateNickname(*req.Nickname); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", err.Error())
			}
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		profile, err := svc.SetMemberProfile(ctx, groupID, accountPub, req.Nickname, req.LevelID)
		if err != nil {
			return nil, mapGroupError("设置成员本群资料失败", err)
		}
		return map[string]any{
			"account":  profile.Account,
			"nickname": profile.Nickname,
			"level_id": profile.LevelID,
		}, nil
	}
}

// setAliasHandler 处理 group.setAlias：任意成员设置或清除本机群备注（P6-27）。
// 备注不上行、不广播，仅影响本机群名展示。
func (gw *Gateway) setAliasHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string  `json:"group_id"`
			Alias   *string `json:"alias"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "group.setAlias 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		if req.Alias == nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 alias")
		}
		if err := ValidateGroupAlias(strings.TrimSpace(*req.Alias)); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", err.Error())
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		saved, err := svc.SetAlias(ctx, groupID, *req.Alias)
		if err != nil {
			return nil, mapGroupError("设置群备注失败", err)
		}
		return map[string]any{"alias": saved}, nil
	}
}

// sendTextHandler 处理 dm.sendGroupText：加密广播并尽力写群盘。
func (gw *Gateway) sendTextHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID  string   `json:"group_id"`
			Text     string   `json:"text"`
			Mentions []string `json:"mentions"`
			TTLHours uint32   `json:"ttl_hours"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "dm.sendGroupText 参数不是合法 JSON: %v", err)
		}
		if err := expiry.Validate(req.TTLHours); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "dm.sendGroupText ttl_hours 非法: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		var res PublishResult
		if len(req.Mentions) > 0 || req.TTLHours > 0 {
			// 带 @ 成员或定时消息时走结构化正文，mentions / ttl_hours 随
			// InnerMessage 加密广播与落库（七-1 @成员、定时消息）。
			res, err = svc.PublishEncryptedMessage(ctx, groupID, &nexmemv1.InnerMessage{
				Text: req.Text, Mentions: req.Mentions, TtlHours: req.TTLHours,
			})
		} else {
			res, err = svc.PublishEncryptedStored(ctx, groupID, req.Text)
		}
		if err != nil {
			return nil, mapGroupError("发送群消息失败", err)
		}
		out := map[string]any{
			"msg_uuid": res.MsgUUID,
			"stored":   res.Stored,
		}
		if res.StorageErr != nil {
			out["storage_error"] = res.StorageErr.Error()
		}
		return out, nil
	}
}

// sendFileHandler 处理 dm.sendGroupFile：文件加密写群盘并把附件元数据广播到群（A-02）。
func (gw *Gateway) sendFileHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
			Path    string `json:"path"`
			Mime    string `json:"mime"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "dm.sendGroupFile 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		res, err := svc.SendFile(ctx, groupID, req.Path, req.Mime)
		if err != nil {
			return nil, mapGroupError("发送群文件失败", err)
		}
		return map[string]any{"msg_uuid": res.MsgUUID, "stored": res.Stored}, nil
	}
}

// downloadFileHandler 处理 file.downloadGroup：从群盘下载并解密群文件，写入本地路径（A-02）。
func (gw *Gateway) downloadFileHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var req struct {
			GroupID string `json:"group_id"`
			BlobRef string `json:"blob_ref"`
			KeyB64  string `json:"key_b64"`
			Path    string `json:"path"`
		}
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "file.downloadGroup 参数不是合法 JSON: %v", err)
		}
		groupID, err := parseGroupID(req.GroupID)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群 ID 非法: %v", err)
		}
		key, err := base64.StdEncoding.DecodeString(req.KeyB64)
		if err != nil || len(key) != filecrypto.FileKeySize {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "群文件密钥非法")
		}
		if !filepath.IsAbs(req.Path) {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "下载目标需要绝对路径")
		}
		svc, gerr := gw.service()
		if gerr != nil {
			return nil, gerr
		}
		plain, err := svc.DownloadFile(ctx, groupID, req.BlobRef, key)
		if err != nil {
			return nil, mapGroupError("下载群文件失败", err)
		}
		sum := sha256.Sum256(plain)
		if err := os.WriteFile(req.Path, plain, 0o600); err != nil {
			return nil, gateway.NewError(gateway.CodeS3IO, "写入群文件失败: %v", err)
		}
		return map[string]any{
			"path":   req.Path,
			"size":   int64(len(plain)),
			"sha256": hex.EncodeToString(sum[:]),
		}, nil
	}
}

// resolve 用注入的解析器把成员账号解析为投递目标。
func (gw *Gateway) resolve(ctx context.Context, accountPub []byte) (KeyTarget, error) {
	if gw.Resolve == nil {
		return KeyTarget{}, errors.New("未配置成员地址解析器")
	}
	t, err := gw.Resolve(ctx, accountPub)
	if err != nil {
		return KeyTarget{}, err
	}
	t.AccountPub = accountPub
	return t, nil
}

// AccountPub 返回群聊服务绑定的本机账号公钥。
func (s *Service) AccountPub() []byte {
	if s.account == nil {
		return nil
	}
	return s.account.Pub()
}

// mapGroupError 把群聊错误翻译为契约错误码。
func mapGroupError(prefix string, err error) *gateway.Error {
	switch {
	case errors.Is(err, ErrGroupIDRequired),
		errors.Is(err, ErrTitleRequired),
		errors.Is(err, ErrEmptyBody),
		errors.Is(err, ErrBodyTooLarge),
		errors.Is(err, ErrNotMember),
		errors.Is(err, ErrNotGroupAdmin),
		errors.Is(err, ErrGroupKeyNotFound),
		errors.Is(err, ErrBadStorageConfig),
		errors.Is(err, ErrKeyEnvelopeInvalid),
		errors.Is(err, ErrMemberNotFound),
		errors.Is(err, ErrAlreadyMember),
		errors.Is(err, ErrCannotRemoveSelf),
		errors.Is(err, ErrGroupEmpty),
		errors.Is(err, ErrAnnouncementTooLong),
		errors.Is(err, ErrAliasTooLong),
		errors.Is(err, ErrLevelConfigInvalid),
		errors.Is(err, ErrLevelConfigTooMany),
		errors.Is(err, ErrLevelIDInvalid),
		errors.Is(err, ErrLevelIDDuplicate),
		errors.Is(err, ErrLevelNameTooLong),
		errors.Is(err, ErrLevelIconInvalid),
		errors.Is(err, ErrLevelIconTooLarge),
		errors.Is(err, ErrLevelNotFound),
		errors.Is(err, ErrNicknameTooLong),
		errors.Is(err, ErrMemberTargetMissing):
		return gateway.NewError(gateway.CodeInvalidArg, "%s: %v", prefix, err)
	case errors.Is(err, ErrStorageWrite):
		return gateway.NewError(gateway.CodeS3IO, "%s: %v", prefix, err)
	default:
		// 未归类的错误按存储瞬时错误上报，客户端可重试。
		return gateway.NewError(gateway.CodeS3IO, "%s: %v", prefix, err)
	}
}

// parseGroupID 解析十六进制或 base64url 编码的群 ID。
func parseGroupID(s string) ([]byte, error) {
	if s == "" {
		return nil, ErrGroupIDRequired
	}
	if raw, err := hex.DecodeString(s); err == nil && len(raw) == GroupIDSize {
		return raw, nil
	}
	if raw, err := base64.RawURLEncoding.DecodeString(s); err == nil && len(raw) == GroupIDSize {
		return raw, nil
	}
	return nil, errors.New("群 ID 必须为 16 字节的十六进制或 base64url 编码")
}

// encodeGroupID 把群 ID 编码为 base64url（契约中的字符串形式）。
func encodeGroupID(groupID []byte) string {
	return base64.RawURLEncoding.EncodeToString(groupID)
}

// encodeAccountID 把账号公钥编码为 base64url，与联系人方法保持一致。
func encodeAccountID(pub []byte) string {
	return base64.RawURLEncoding.EncodeToString(pub)
}
