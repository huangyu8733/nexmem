package social

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/nexmem/core/internal/store"
)

// Sender 把一条文本控制帧投递给指定账号；由 coreapp 注入（底层是 dm.SendText）。
// 返回投递的消息 UUID，便于失败重试；纯粹离线环境下允许返回错误。
type Sender func(ctx context.Context, accountPub []byte, text string) (string, error)

// Resolver 把账号公钥解析为可投递目标；用于判断在线状态。
type Resolver func(ctx context.Context, accountPub []byte) (online bool, err error)

// Emit 事件回调，由 coreapp 注入以广播给客户端。
type Emit func(name string, data any)

// Options 是社交服务的依赖。
type Options struct {
	DAO  *store.DAO
	Self func() []byte
	// XPub 返回本机账号 X25519 公钥；随好友申请/同意控制帧发给对端，
	// 让双方在局域网或无目录服务时也能为群密钥信封封装对方公钥。
	XPub   func() []byte
	Send   Sender
	Online Resolver
	Emit   Emit
	// OnFriendAccepted 在同意好友申请后由 coreapp 回调，把对方写入通讯录。
	OnFriendAccepted func(ctx context.Context, peer []byte) error
	// OnGroupInvite 在同意入群后由 coreapp 回调，实际投递群密钥。
	OnGroupInvite func(ctx context.Context, groupID string, applicant []byte) error
	// OnXPubReceived 在好友控制帧或公钥应答里学到对端账号 X25519 公钥后回调，
	// coreapp 用它唤醒正在等待该公钥的群拉人请求。
	OnXPubReceived func(ctx context.Context, accountPub, xpub []byte)
}

// Service 提供好友申请、入群审批、通知、动态、投票等业务。
type Service struct {
	dao    *store.DAO
	self   func() []byte
	send   Sender
	online Resolver
	emit   Emit
	opts   Options
}

// New 创建社交服务。
func New(o Options) (*Service, error) {
	if o.DAO == nil || o.Self == nil {
		return nil, errors.New("社交服务缺少 DAO 或账号")
	}
	return &Service{dao: o.DAO, self: o.Self, send: o.Send, online: o.Online, emit: o.Emit, opts: o}, nil
}

func newID() string { return uuid.NewString() }

// selfXPubHex 返回可随控制帧发出的本机账号 X25519 公钥。
func (s *Service) selfXPubHex() string {
	if s.opts.XPub == nil {
		return ""
	}
	xpub := s.opts.XPub()
	if len(xpub) != 32 {
		return ""
	}
	return hex.EncodeToString(xpub)
}

// rememberXPub 记录好友控制帧携带的对端 X25519 公钥。控制帧走已验签的
// 端到端单聊通道，因此比目录服务公开档案更适合局域网内的群密钥分发。
func (s *Service) rememberXPub(ctx context.Context, from []byte, hexText string) {
	if hexText == "" || len(from) != 32 {
		return
	}
	xpub, err := hex.DecodeString(hexText)
	if err != nil || len(xpub) != 32 {
		return
	}
	_ = s.dao.SetContactXPub(ctx, from, xpub, time.Now().Unix())
	if s.opts.OnXPubReceived != nil {
		s.opts.OnXPubReceived(ctx, from, xpub)
	}
}

// frameExtra 把可选 XPub 合并进控制帧 Extra，不改变已有 fields。
func (s *Service) frameExtra(extra map[string]string) map[string]string {
	xpub := s.selfXPubHex()
	if xpub == "" {
		return extra
	}
	if extra == nil {
		extra = make(map[string]string, 1)
	}
	extra["xpub"] = xpub
	return extra
}

// decodeAccountPub 同时接受契约里的 base64url 账号与内部 hex 账号。
// 群资料页分享出来的群主账号是 base64url，入群申请必须能直接使用，
// 否则申请会卡在「群主账号非法」而无法送达。
func decodeAccountPub(text string) ([]byte, error) {
	if text == "" {
		return nil, errors.New("账号为空")
	}
	if raw, err := hex.DecodeString(text); err == nil && len(raw) == 32 {
		return raw, nil
	}
	if raw, err := base64.RawURLEncoding.DecodeString(text); err == nil && len(raw) == 32 {
		return raw, nil
	}
	return nil, errors.New("账号必须为 32 字节的十六进制或 base64url 编码")
}

// ---- 好友申请 ----

// SendFriendRequest 发起好友申请：本机落一条 out 记录，并向对方投递控制帧。
func (s *Service) SendFriendRequest(ctx context.Context, peer []byte, message string) (string, error) {
	self := s.self()
	if len(peer) == 0 || hex.EncodeToString(peer) == hex.EncodeToString(self) {
		return "", errors.New("好友申请目标非法")
	}
	id := newID()
	now := time.Now().Unix()
	if err := s.dao.InsertFriendRequest(ctx, store.FriendRequest{
		ID: id, FromPub: self, ToPub: peer, Message: message,
		Status: 0, Direction: "out", CreatedAt: now,
	}); err != nil {
		return "", err
	}
	frame := Frame{Kind: KindFriendRequest, ID: id, From: hex.EncodeToString(self), To: hex.EncodeToString(peer), Text: message, Timestamp: now,
		Extra: s.frameExtra(nil)}
	if s.send != nil {
		if _, err := s.send(ctx, peer, Encode(frame)); err != nil {
			// 投递失败不回滚本机记录：对端上线后可通过离线补发收到。
			if s.emit != nil {
				s.emit("error", map[string]any{"code": "SEND_PENDING", "message": "好友申请已保存，等待对方上线后送达", "retryable": true})
			}
		}
	}
	return id, nil
}

// RespondFriendRequest 同意或拒绝好友申请。
func (s *Service) RespondFriendRequest(ctx context.Context, id string, accept bool) error {
	req, err := s.dao.GetFriendRequest(ctx, id)
	if err != nil {
		return err
	}
	if req.Status != 0 {
		return errors.New("该好友申请已处理")
	}
	status := 2
	kind := KindFriendReject
	if accept {
		status = 1
		kind = KindFriendAccept
	}
	if err := s.dao.SetFriendRequestStatus(ctx, id, status); err != nil {
		return err
	}
	self := s.self()
	peer := req.FromPub
	if req.Direction == "out" {
		peer = req.ToPub // 自己发出的申请，对端才是响应方
	}
	frame := Frame{Kind: kind, ID: id, From: hex.EncodeToString(self), To: hex.EncodeToString(peer), Timestamp: time.Now().Unix(),
		Extra: s.frameExtra(nil)}
	if s.send != nil && len(peer) > 0 {
		_, _ = s.send(ctx, peer, Encode(frame))
	}
	if accept {
		if s.opts.OnFriendAccepted != nil {
			if err := s.opts.OnFriendAccepted(ctx, peer); err != nil {
				return err
			}
		}
		// 通讯录已写入，通知客户端立即刷新好友列表。
		if len(peer) > 0 && s.emit != nil {
			s.emit("contact.new", map[string]any{"peer": hex.EncodeToString(peer)})
		}
		// 写一条系统通知。
		_ = s.dao.InsertNotification(ctx, store.Notification{
			ID: newID(), Kind: "friend.accepted", Title: "好友申请已通过",
			Body: "你和一位新好友已成为好友", Payload: `{"peer":"` + hex.EncodeToString(peer) + `"}`,
		})
	}
	if s.emit != nil {
		s.emit("friend.request.resolved", map[string]any{"id": id, "accepted": accept})
	}
	return nil
}

// HandleFrame 处理从单聊通道收到的社交控制帧（由 coreapp.onInbound 调用）。
func (s *Service) HandleFrame(ctx context.Context, f Frame) error {
	selfHex := hex.EncodeToString(s.self())
	if f.To != "" && f.To != selfHex {
		return nil // 不是发给本机的
	}
	from, err := hex.DecodeString(f.From)
	if err != nil || len(from) == 0 {
		return errors.New("控制帧发送方非法")
	}
	switch f.Kind {
	case KindXPubReq:
		// 老好友没有本地公钥缓存时由拉群方按需发起；收到即回自己的公钥。
		s.rememberXPub(ctx, from, f.Extra["xpub"])
		if s.send != nil {
			resp := Frame{Kind: KindXPubResp, ID: f.ID, From: hex.EncodeToString(s.self()),
				To: f.From, Timestamp: time.Now().Unix(), Extra: s.frameExtra(nil)}
			_, _ = s.send(ctx, from, Encode(resp))
		}
	case KindXPubResp:
		s.rememberXPub(ctx, from, f.Extra["xpub"])
	case KindFriendRequest:
		// 对端发来的好友申请：落一条 in 记录 + 通知 + 事件。
		s.rememberXPub(ctx, from, f.Extra["xpub"])
		if f.ID == "" {
			f.ID = newID()
		}
		if err := s.dao.InsertFriendRequest(ctx, store.FriendRequest{
			ID: f.ID, FromPub: from, ToPub: s.self(), Message: f.Text,
			Status: 0, Direction: "in", CreatedAt: f.Timestamp,
		}); err != nil {
			return err
		}
		_ = s.dao.InsertNotification(ctx, store.Notification{
			ID: newID(), Kind: "friend.request", Title: "好友申请",
			Body: f.Text, Payload: `{"id":"` + f.ID + `","peer":"` + f.From + `"}`,
		})
		if s.emit != nil {
			s.emit("friend.request.new", map[string]any{"id": f.ID, "peer": f.From, "message": f.Text})
		}
	case KindFriendAccept:
		s.rememberXPub(ctx, from, f.Extra["xpub"])
		if s.opts.OnFriendAccepted != nil {
			if err := s.opts.OnFriendAccepted(ctx, from); err != nil {
				return err
			}
		}
		// 发起方收到同意帧后同样已写入通讯录，通知本机刷新好友列表。
		if s.emit != nil {
			s.emit("contact.new", map[string]any{"peer": f.From})
		}
		if f.ID != "" {
			_ = s.dao.SetFriendRequestStatus(ctx, f.ID, 1)
		}
		_ = s.dao.InsertNotification(ctx, store.Notification{
			ID: newID(), Kind: "friend.accepted", Title: "好友申请已通过",
			Body: "对方同意了你的好友申请", Payload: `{"peer":"` + f.From + `"}`,
		})
		if s.emit != nil {
			s.emit("friend.request.resolved", map[string]any{"id": f.ID, "accepted": true})
		}
	case KindFriendReject:
		if f.ID != "" {
			_ = s.dao.SetFriendRequestStatus(ctx, f.ID, 2)
		}
		if s.emit != nil {
			s.emit("friend.request.resolved", map[string]any{"id": f.ID, "accepted": false})
		}
	case KindGroupInvited:
		// 管理员主动拉人：落一条系统通知并让社交中心立即刷新。
		title := f.Extra["group_title"]
		if title == "" {
			title = "群聊"
		}
		if f.ID == "" {
			f.ID = newID()
		}
		payload, _ := json.Marshal(map[string]string{
			"id": f.ID, "group_id": f.GroupID, "peer": f.From,
		})
		_ = s.dao.InsertNotification(ctx, store.Notification{
			ID: newID(), Kind: "group.invited", Title: "群邀请",
			Body:    fmt.Sprintf("你被邀请加入群聊「%s」", title),
			Payload: string(payload),
		})
		if s.emit != nil {
			s.emit("group.invited", map[string]any{
				"id": f.ID, "group_id": f.GroupID, "peer": f.From,
			})
		}
	case KindGroupJoinReq:
		// 有人申请加入我管理的群（由群管理员端处理，这里记录 + 事件）。
		// 申请帧携带申请人 XPub，管理员同意时无需依赖好友关系或目录服务
		// 即可封装群密钥信封。
		s.rememberXPub(ctx, from, f.Extra["xpub"])
		if f.ID == "" {
			f.ID = newID()
		}
		if err := s.dao.InsertGroupJoinRequest(ctx, store.GroupJoinRequest{
			ID: f.ID, GroupID: f.GroupID, GroupTitle: f.Extra["group_title"],
			Applicant: from, Message: f.Text, Status: 0, Direction: "in", CreatedAt: f.Timestamp,
		}); err != nil {
			return err
		}
		_ = s.dao.InsertNotification(ctx, store.Notification{
			ID: newID(), Kind: "group.joinRequest", Title: "入群申请",
			Body: f.Text, Payload: `{"id":"` + f.ID + `","group_id":"` + f.GroupID + `","peer":"` + f.From + `"}`,
		})
		if s.emit != nil {
			s.emit("group.joinRequested", map[string]any{"id": f.ID, "group_id": f.GroupID, "peer": f.From})
		}
	case KindGroupJoinAccept:
		if f.ID != "" {
			_ = s.dao.SetGroupJoinRequestStatus(ctx, f.ID, 1)
		}
		// 群密钥随同意帧下发，已在 coreapp 层处理信封，这里只更新状态。
		_ = s.dao.InsertNotification(ctx, store.Notification{
			ID: newID(), Kind: "group.joined", Title: "入群成功",
			Body: "你已加入群聊", Payload: `{"group_id":"` + f.GroupID + `"}`,
		})
		if s.emit != nil {
			s.emit("group.joinResolved", map[string]any{"id": f.ID, "group_id": f.GroupID, "accepted": true})
		}
	case KindGroupJoinReject:
		if f.ID != "" {
			_ = s.dao.SetGroupJoinRequestStatus(ctx, f.ID, 2)
		}
		if s.emit != nil {
			s.emit("group.joinResolved", map[string]any{"id": f.ID, "group_id": f.GroupID, "accepted": false})
		}
	case KindMomentNew:
		// 好友新动态广播：以对方账号落本机动态表（简化版 feed）。
		if f.ID == "" {
			f.ID = newID()
		}
		if err := s.dao.InsertMoment(ctx, store.Moment{
			ID: f.ID, AccountPub: from, Text: f.Text,
			Attachments: f.Extra["attachments"], CreatedAt: f.Timestamp,
		}); err != nil {
			return err
		}
		if s.emit != nil {
			s.emit("moment.new", map[string]any{"id": f.ID, "peer": f.From})
		}
	}
	return nil
}

// ---- 账号公钥按需交换 ----

// RequestXPub 向老好友请求其账号 X25519 公钥，用于本地缓存缺失时的群密钥封装。
func (s *Service) RequestXPub(ctx context.Context, peer []byte) error {
	if len(peer) != 32 || hex.EncodeToString(peer) == hex.EncodeToString(s.self()) {
		return errors.New("公钥请求目标非法")
	}
	if s.send == nil {
		return errors.New("单聊投递通道未接入")
	}
	frame := Frame{Kind: KindXPubReq, ID: newID(), From: hex.EncodeToString(s.self()),
		To: hex.EncodeToString(peer), Timestamp: time.Now().Unix(), Extra: s.frameExtra(nil)}
	_, err := s.send(ctx, peer, Encode(frame))
	return err
}

// ---- 管理员主动拉人 ----

// SendGroupInvite 给被拉入群落的账号投递一条显式邀请通知。
//
// 群密钥信封仍由 group.invite 单独投递；这条通知只负责让对方明确知道
// 「谁邀请我进了哪个群」，因此即使 XPub/档案暂时不可用、密钥待补发，
// 邀请信息本身也应尽量送达。
func (s *Service) SendGroupInvite(ctx context.Context, groupID, groupTitle string, peer []byte) (string, error) {
	self := s.self()
	if len(peer) == 0 || hex.EncodeToString(peer) == hex.EncodeToString(self) {
		return "", errors.New("邀请目标非法")
	}
	if groupID == "" {
		return "", errors.New("群 ID 非法")
	}
	id := newID()
	now := time.Now().Unix()
	frame := Frame{
		Kind: KindGroupInvited, ID: id, From: hex.EncodeToString(self),
		To: hex.EncodeToString(peer), GroupID: groupID, Text: groupTitle,
		Timestamp: now, Extra: map[string]string{"group_title": groupTitle},
	}
	if s.send == nil {
		return id, errors.New("单聊投递通道未接入")
	}
	msgID, err := s.send(ctx, peer, Encode(frame))
	if err != nil {
		return msgID, err
	}
	return id, nil
}

// ---- 入群申请（本机发起）----

// RequestGroupJoin 向群主发起入群申请。
func (s *Service) RequestGroupJoin(ctx context.Context, groupID, groupTitle, ownerPubHex, message string) (string, error) {
	owner, err := decodeAccountPub(ownerPubHex)
	if err != nil {
		return "", errors.New("群主账号非法")
	}
	ownerHex := hex.EncodeToString(owner)
	id := newID()
	now := time.Now().Unix()
	if err := s.dao.InsertGroupJoinRequest(ctx, store.GroupJoinRequest{
		ID: id, GroupID: groupID, GroupTitle: groupTitle, Applicant: s.self(),
		Message: message, Status: 0, Direction: "out", CreatedAt: now,
	}); err != nil {
		return "", err
	}
	frame := Frame{Kind: KindGroupJoinReq, ID: id, From: hex.EncodeToString(s.self()), To: ownerHex,
		GroupID: groupID, Text: message, Timestamp: now,
		Extra: s.frameExtra(map[string]string{"group_title": groupTitle})}
	if s.send != nil {
		_, _ = s.send(ctx, owner, Encode(frame))
	}
	return id, nil
}

// RespondGroupJoin 管理员同意/拒绝入群申请。
func (s *Service) RespondGroupJoin(ctx context.Context, id string, accept bool) error {
	req, err := s.dao.GetGroupJoinRequest(ctx, id)
	if err != nil {
		return err
	}
	if req.Status != 0 {
		return errors.New("该入群申请已处理")
	}
	status, kind := 2, KindGroupJoinReject
	if accept {
		status, kind = 1, KindGroupJoinAccept
	}
	if err := s.dao.SetGroupJoinRequestStatus(ctx, id, status); err != nil {
		return err
	}
	if accept && s.opts.OnGroupInvite != nil {
		if err := s.opts.OnGroupInvite(ctx, req.GroupID, req.Applicant); err != nil {
			return err
		}
	}
	frame := Frame{Kind: kind, ID: id, From: hex.EncodeToString(s.self()), To: hex.EncodeToString(req.Applicant),
		GroupID: req.GroupID, Timestamp: time.Now().Unix()}
	if s.send != nil {
		_, _ = s.send(ctx, req.Applicant, Encode(frame))
	}
	if s.emit != nil {
		s.emit("group.joinResolved", map[string]any{"id": id, "accepted": accept})
	}
	return nil
}

// ---- 成员管理 ----

// SetMemberRole 设置成员角色（owner/admin/member）与头衔、禁言。
func (s *Service) SetMemberRole(ctx context.Context, groupID, accountHex, role, title string, muteMinutes int) error {
	account, err := hex.DecodeString(accountHex)
	if err != nil || len(account) == 0 {
		return errors.New("成员账号非法")
	}
	gid, err := hex.DecodeString(groupID)
	if err != nil || len(gid) == 0 {
		gid = []byte(groupID) // 兼容非 hex 群号
	}
	if role == "" {
		role = "member"
	}
	if role != "owner" && role != "admin" && role != "member" {
		return errors.New("角色非法")
	}
	var muteUntil int64
	if muteMinutes > 0 {
		muteUntil = time.Now().Add(time.Duration(muteMinutes) * time.Minute).Unix()
	} else if muteMinutes < 0 {
		muteUntil = 0 // 解除禁言
	} else {
		// 保留原禁言：读取现有资料
		if p, e := s.dao.GetMemberProfile(ctx, gid, account); e == nil {
			muteUntil = p.MuteUntil
		}
	}
	return s.dao.UpsertMemberProfile(ctx, store.MemberProfile{
		GroupID: gid, AccountPub: account, Role: role, Title: title, MuteUntil: muteUntil,
	})
}

// IsMuted 判断成员是否被禁言。
func (s *Service) IsMuted(ctx context.Context, groupID, account []byte) (bool, error) {
	p, err := s.dao.GetMemberProfile(ctx, groupID, account)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return p.MuteUntil > time.Now().Unix(), nil
}

// ---- 在线状态 ----

// ListPresence 返回已知联系人的在线状态；并发探测避免多个离线好友把请求拖超时。
// 探测成功（含确定的离线）覆盖缓存；探测失败时保留上次缓存。
func (s *Service) ListPresence(ctx context.Context, accounts []string) ([]map[string]any, error) {
	cached, _ := s.dao.ListPresence(ctx)
	type probe struct {
		hexID  string
		pub    []byte
		online bool
		known  bool
		set    bool
	}
	probes := make([]probe, len(accounts))
	var wg sync.WaitGroup
	for i, hexID := range accounts {
		probes[i] = probe{hexID: hexID}
		pub, err := hex.DecodeString(hexID)
		if err != nil || s.online == nil {
			continue
		}
		probes[i].pub = pub
		wg.Add(1)
		go func(p *probe, pub []byte) {
			defer wg.Done()
			ok, err := s.online(ctx, pub)
			if err != nil {
				return
			}
			p.online, p.known, p.set = ok, true, true
		}(&probes[i], pub)
	}
	wg.Wait()
	out := make([]map[string]any, 0, len(accounts))
	for i := range probes {
		p := &probes[i]
		if !p.known {
			if v, ok := cached[p.hexID]; ok {
				p.online, p.known = v, true
			}
		}
		if p.set {
			_ = s.dao.UpsertPresence(ctx, p.pub, p.online, time.Now().Unix())
		}
		out = append(out, map[string]any{"account": p.hexID, "online": p.online, "known": p.known})
	}
	return out, nil
}

// ---- 动态 ----

// PostMoment 发布动态，并向好友广播。
func (s *Service) PostMoment(ctx context.Context, text, attachments string, peers [][]byte) (string, error) {
	id := newID()
	now := time.Now().Unix()
	if err := s.dao.InsertMoment(ctx, store.Moment{
		ID: id, AccountPub: s.self(), Text: text, Attachments: attachments, CreatedAt: now,
	}); err != nil {
		return "", err
	}
	frame := Frame{Kind: KindMomentNew, ID: id, From: hex.EncodeToString(s.self()), Text: text, Timestamp: now,
		Extra: map[string]string{"attachments": attachments}}
	if s.send != nil {
		for _, p := range peers {
			_, _ = s.send(ctx, p, Encode(frame))
		}
	}
	return id, nil
}

// ---- 投票 ----

// CreatePoll 创建群投票。
func (s *Service) CreatePoll(ctx context.Context, groupID, question string, options []string, closesAt int64) (string, error) {
	if question == "" || len(options) < 2 {
		return "", errors.New("投票问题或选项不合法")
	}
	raw, _ := json.Marshal(options)
	id := newID()
	err := s.dao.InsertGroupPoll(ctx, store.GroupPoll{
		ID: id, GroupID: groupID, Creator: s.self(), Question: question,
		Options: string(raw), Votes: "{}", CreatedAt: time.Now().Unix(), ClosesAt: closesAt,
	})
	return id, err
}

// VotePoll 投票。
func (s *Service) VotePoll(ctx context.Context, pollID string, option int) (string, error) {
	if option < 0 {
		return "", errors.New("选项非法")
	}
	voter := hex.EncodeToString(s.self())
	votes, err := s.dao.VoteGroupPoll(ctx, pollID, voter, option)
	if err != nil {
		return "", err
	}
	if s.emit != nil {
		s.emit("poll.updated", map[string]any{"poll_id": pollID})
	}
	return votes, nil
}
