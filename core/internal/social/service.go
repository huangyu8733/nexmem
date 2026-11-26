package social

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
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
	DAO    *store.DAO
	Self   func() []byte
	Send   Sender
	Online Resolver
	Emit   Emit
	// OnFriendAccepted 在同意好友申请后由 coreapp 回调，把对方写入通讯录。
	OnFriendAccepted func(ctx context.Context, peer []byte) error
	// OnGroupInvite 在同意入群后由 coreapp 回调，实际投递群密钥。
	OnGroupInvite func(ctx context.Context, groupID string, applicant []byte) error
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
	frame := Frame{Kind: KindFriendRequest, ID: id, From: hex.EncodeToString(self), To: hex.EncodeToString(peer), Text: message, Timestamp: now}
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
	frame := Frame{Kind: kind, ID: id, From: hex.EncodeToString(self), To: hex.EncodeToString(peer), Timestamp: time.Now().Unix()}
	if s.send != nil && len(peer) > 0 {
		_, _ = s.send(ctx, peer, Encode(frame))
	}
	if accept {
		if s.opts.OnFriendAccepted != nil {
			if err := s.opts.OnFriendAccepted(ctx, peer); err != nil {
				return err
			}
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
	case KindFriendRequest:
		// 对端发来的好友申请：落一条 in 记录 + 通知 + 事件。
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
		if s.opts.OnFriendAccepted != nil {
			if err := s.opts.OnFriendAccepted(ctx, from); err != nil {
				return err
			}
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
	case KindGroupJoinReq:
		// 有人申请加入我管理的群（由群管理员端处理，这里记录 + 事件）。
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
		if f.Extra != nil && f.Extra["group_key_envelope"] != "" && s.opts.OnGroupInvite != nil {
			// 群密钥随同意帧下发（已在 coreapp 层处理信封，这里只更新状态）。
		}
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

// ---- 入群申请（本机发起）----

// RequestGroupJoin 向群主发起入群申请。
func (s *Service) RequestGroupJoin(ctx context.Context, groupID, groupTitle, ownerPubHex, message string) (string, error) {
	owner, err := hex.DecodeString(ownerPubHex)
	if err != nil || len(owner) == 0 {
		return "", errors.New("群主账号非法")
	}
	id := newID()
	now := time.Now().Unix()
	if err := s.dao.InsertGroupJoinRequest(ctx, store.GroupJoinRequest{
		ID: id, GroupID: groupID, GroupTitle: groupTitle, Applicant: s.self(),
		Message: message, Status: 0, Direction: "out", CreatedAt: now,
	}); err != nil {
		return "", err
	}
	frame := Frame{Kind: KindGroupJoinReq, ID: id, From: hex.EncodeToString(s.self()), To: ownerPubHex,
		GroupID: groupID, Text: message, Timestamp: now, Extra: map[string]string{"group_title": groupTitle}}
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
