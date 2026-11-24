package group

// 群创建与本地群信息查询（P1-20 群聊装配）。
//
// 创建群时由本机生成 group_id 与 v1 群密钥，把本机登记为管理员，
// 随后按成员表向各成员投递密钥信封（直连失败时由 MetaSender 走单聊兜底），
// 最后订阅群主题。群记录与成员表落本地库，进程重启后可经 LoadKeys +
// SubscribeAll 恢复密钥与在线接收。

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"strings"

	"github.com/nexmem/core/internal/store"
)

// 群创建语义错误。
var (
	// ErrTitleRequired 表示群名称不能为空。
	ErrTitleRequired = errors.New("群名称不能为空")
)

// GroupIDSize 是新建群的 group_id 字节长度。
const GroupIDSize = 16

// MemberInfo 是群成员的一行只读信息。
type MemberInfo struct {
	AccountPub []byte
	Role       int
	JoinedAt   int64
}

// GroupInfo 是本机视角的群资料与成员表。
type GroupInfo struct {
	GroupID           []byte
	Title             string
	KeyVersion        uint32
	StorageConfigured bool
	// Announcement 是本机记录的群公告；空串表示未设置。
	Announcement string
	// Alias 是本机群备注；空串表示未设置，仅本机可见、不上行。
	Alias string
	// AllowFriendAdd 是群设置：是否允许成员互相添加好友（默认关闭）。
	AllowFriendAdd bool
	Members        []MemberInfo
}

// CreateGroup 创建群聊并分发 v1 群密钥。
//
// targets 是除本机外的成员传输地址；本机会自动加入成员表并登记为管理员。
// 返回新建群的密钥、逐个成员的投递结果；单个成员投递失败不影响群创建。
func (s *Service) CreateGroup(ctx context.Context, title string, targets []KeyTarget) (GroupKey, []KeyDelivery, error) {
	title = strings.TrimSpace(title)
	if title == "" {
		return GroupKey{}, nil, ErrTitleRequired
	}
	if s.dao == nil {
		return GroupKey{}, nil, errors.New("缺少本地 DAO，无法创建群")
	}
	groupID, err := newGroupID()
	if err != nil {
		return GroupKey{}, nil, err
	}
	accounts := [][]byte{s.account.Pub()}
	seen := map[string]struct{}{string(s.account.Pub()): {}}
	for _, t := range targets {
		if len(t.AccountPub) != memberIDSize {
			return GroupKey{}, nil, fmt.Errorf("%w: 成员账号长度 %d", ErrKeyEnvelopeInvalid, len(t.AccountPub))
		}
		if _, dup := seen[string(t.AccountPub)]; dup {
			continue
		}
		seen[string(t.AccountPub)] = struct{}{}
		accounts = append(accounts, append([]byte(nil), t.AccountPub...))
	}

	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		return GroupKey{}, nil, err
	}
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      title,
		Members:    accounts,
		KeyVersion: key.Version,
	}
	reports, err := s.DistributeKeys(ctx, key, meta, targets)
	if err != nil {
		return key, reports, err
	}
	// 创建者需要在线接收其他成员的消息，因此创建成功即订阅主题；
	// 订阅失败不回滚群创建，由调用方按错误提示重试。
	if err := s.Subscribe(ctx, groupID); err != nil {
		return key, reports, fmt.Errorf("订阅群主题: %w", err)
	}
	return key, reports, nil
}

// GroupInfo 读取本地群记录与成员表；群不存在返回 ErrGroupKeyNotFound。
func (s *Service) GroupInfo(ctx context.Context, groupID []byte) (GroupInfo, error) {
	if len(groupID) == 0 {
		return GroupInfo{}, ErrGroupIDRequired
	}
	if s.dao == nil {
		return GroupInfo{}, errors.New("缺少本地 DAO")
	}
	g, err := s.dao.GetGroup(ctx, groupID)
	if errors.Is(err, store.ErrNotFound) {
		return GroupInfo{}, ErrGroupKeyNotFound
	}
	if err != nil {
		return GroupInfo{}, err
	}
	members, err := s.dao.ListMembers(ctx, groupID)
	if err != nil {
		return GroupInfo{}, err
	}
	info := GroupInfo{
		GroupID:           append([]byte(nil), g.GroupID...),
		Title:             g.Title,
		KeyVersion:        uint32(g.KeyVersion),
		StorageConfigured: len(g.StorageCfgEnc) > 0,
		Announcement:      g.Announcement,
		Alias:             g.Alias,
		AllowFriendAdd:    g.AllowFriendAdd,
		Members:           make([]MemberInfo, 0, len(members)),
	}
	for _, m := range members {
		info.Members = append(info.Members, MemberInfo{
			AccountPub: append([]byte(nil), m.AccountPub...),
			Role:       m.Role,
			JoinedAt:   m.JoinedAt,
		})
	}
	return info, nil
}

// ListGroups 返回本机已加入的全部群资料（含成员表），供通讯录群聊分组展示。
//
// 群数量与成员规模都受本机参与度限制，逐群读取成员表不会成为瓶颈；
// 返回顺序沿用 DAO 的群名排序，便于 UI 直接渲染。
func (s *Service) ListGroups(ctx context.Context) ([]GroupInfo, error) {
	if s.dao == nil {
		return nil, errors.New("缺少本地 DAO，无法读取群列表")
	}
	groups, err := s.dao.ListGroups(ctx)
	if err != nil {
		return nil, err
	}
	infos := make([]GroupInfo, 0, len(groups))
	for _, g := range groups {
		info, err := s.GroupInfo(ctx, g.GroupID)
		if err != nil {
			return nil, err
		}
		infos = append(infos, info)
	}
	return infos, nil
}

// SubscribeAll 订阅本地库中的全部群主题，供进程重启后恢复在线接收。
// 返回成功订阅的群数量；单个群订阅失败不影响其他群。
func (s *Service) SubscribeAll(ctx context.Context) (int, error) {
	if s.dao == nil {
		return 0, errors.New("缺少本地 DAO")
	}
	groups, err := s.dao.ListGroups(ctx)
	if err != nil {
		return 0, err
	}
	var (
		subscribed int
		firstErr   error
	)
	for _, g := range groups {
		if err := s.Subscribe(ctx, g.GroupID); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		subscribed++
	}
	return subscribed, firstErr
}

// newGroupID 生成随机 group_id。
func newGroupID() ([]byte, error) {
	id := make([]byte, GroupIDSize)
	if _, err := rand.Read(id); err != nil {
		return nil, fmt.Errorf("生成 group_id: %w", err)
	}
	return id, nil
}
