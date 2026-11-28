package group

// 入群授权与退群轮换（P4-04）。
//
// 群密钥版本单调递增：成员变更时由管理员生成下一版本密钥，
// 只向变更后的成员表分发新信封；被移除的成员仍保留旧版本密钥，
// 但无法解密新版本消息，也无法通过接收方的成员校验发布新消息。
//
// 入群时沿用当前版本密钥（P4 不做历史前向保密，P7 预密钥池再补），
// 但会把更新的成员表随信封分发给全部成员，保证主题校验器及时收敛。

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/nexmem/core/internal/store"
)

// 入群 / 退群语义错误。
var (
	// ErrNotGroupAdmin 表示只有群管理员可以修改成员或轮换密钥。
	ErrNotGroupAdmin = errors.New("仅群管理员可执行该操作")
	// ErrMemberNotFound 表示目标账号不在群成员表内。
	ErrMemberNotFound = errors.New("群成员不存在")
	// ErrAlreadyMember 表示目标账号已经在群成员表内。
	ErrAlreadyMember = errors.New("该账号已在群内")
	// ErrCannotRemoveSelf 表示管理员不能把自己移出群。
	ErrCannotRemoveSelf = errors.New("不能移除群管理员本人")
	// ErrGroupEmpty 表示成员变更后群内没有成员，操作被拒绝。
	ErrGroupEmpty = errors.New("群成员不能为空")
	// ErrKeyVersionExhausted 表示密钥版本已达到 uint32 上限。
	ErrKeyVersionExhausted = errors.New("群密钥版本已耗尽")
	// ErrMemberTargetMissing 表示 targets 中没有包含必要成员。
	ErrMemberTargetMissing = errors.New("缺少目标成员的传输地址")
)

// RotateKey 生成下一版本群密钥，并只向当前成员表内的 targets 分发。
// 返回新密钥与逐个成员的投递结果；单个投递失败不影响其他成员。
func (s *Service) RotateKey(ctx context.Context, groupID []byte, targets []KeyTarget) (GroupKey, []KeyDelivery, error) {
	g, members, err := s.requireAdmin(ctx, groupID)
	if err != nil {
		return GroupKey{}, nil, err
	}
	return s.rotate(ctx, g, members, targets, groupID)
}

// RemoveMember 把账号移出群并立即轮换密钥，只向剩余成员分发新信封。
// 被移除的账号不会收到新版本密钥；若 targets 中仍包含它会被过滤掉。
func (s *Service) RemoveMember(ctx context.Context, groupID, memberAccount []byte, targets []KeyTarget) (GroupKey, []KeyDelivery, error) {
	if len(memberAccount) != memberIDSize {
		return GroupKey{}, nil, fmt.Errorf("%w: 成员账号长度 %d", ErrKeyEnvelopeInvalid, len(memberAccount))
	}
	g, members, err := s.requireAdmin(ctx, groupID)
	if err != nil {
		return GroupKey{}, nil, err
	}
	if bytes.Equal(memberAccount, s.account.Pub()) {
		return GroupKey{}, nil, ErrCannotRemoveSelf
	}
	remaining := make([]store.GroupMember, 0, len(members))
	found := false
	for _, m := range members {
		if bytes.Equal(m.AccountPub, memberAccount) {
			found = true
			continue
		}
		remaining = append(remaining, m)
	}
	if !found {
		return GroupKey{}, nil, ErrMemberNotFound
	}
	if len(remaining) == 0 {
		return GroupKey{}, nil, ErrGroupEmpty
	}
	return s.rotate(ctx, g, remaining, targets, groupID)
}

// InviteMember 把新成员加入成员表，并把当前版本密钥信封分发给全部成员。
// targets 必须包含新成员；其余成员用于同步更新后的成员表。
func (s *Service) InviteMember(ctx context.Context, groupID, memberAccount []byte, targets []KeyTarget) (GroupKey, []KeyDelivery, error) {
	return s.inviteMember(ctx, groupID, memberAccount, targets, false)
}

// InviteMemberAllowPending 与 InviteMember 相同，但允许新成员暂时无法解析投递目标。
//
// 管理员主动拉人时，即使目录服务尚未公开该账号的 X25519 公钥，也应先把成员
// 写入本机成员表并向对方投递邀请通知；密钥信封记为待补发，避免管理员端直接
// 收到「拉人失败」而对方完全不知道发生了什么。
func (s *Service) InviteMemberAllowPending(ctx context.Context, groupID, memberAccount []byte, targets []KeyTarget) (GroupKey, []KeyDelivery, error) {
	return s.inviteMember(ctx, groupID, memberAccount, targets, true)
}

func (s *Service) inviteMember(ctx context.Context, groupID, memberAccount []byte, targets []KeyTarget, allowPending bool) (GroupKey, []KeyDelivery, error) {
	if len(memberAccount) != memberIDSize {
		return GroupKey{}, nil, fmt.Errorf("%w: 成员账号长度 %d", ErrKeyEnvelopeInvalid, len(memberAccount))
	}
	g, members, err := s.requireAdmin(ctx, groupID)
	if err != nil {
		return GroupKey{}, nil, err
	}
	for _, m := range members {
		if bytes.Equal(m.AccountPub, memberAccount) {
			return GroupKey{}, nil, ErrAlreadyMember
		}
	}
	current, err := s.latestKey(ctx, groupID)
	if err != nil {
		return GroupKey{}, nil, err
	}
	members = append(members, store.GroupMember{
		GroupID:    groupID,
		AccountPub: memberAccount,
		Role:       KeyRoleMember,
		JoinedAt:   time.Now().Unix(),
	})
	meta := GroupMeta{
		GroupID:        groupID,
		Title:          g.Title,
		Members:        memberAccounts(members),
		KeyVersion:     current.Version,
		OfflineEnabled: g.OfflineEnabled,
		StorageCfg:     append([]byte(nil), g.StorageCfgEnc...),
	}
	filtered := filterTargets(targets, meta.Members)
	if !hasTarget(filtered, memberAccount) {
		if !allowPending {
			return GroupKey{}, nil, ErrMemberTargetMissing
		}
		// 仍把更新后的成员表写到本机，并把新成员标为待补发。
		reports, err := s.DistributeKeys(ctx, current, meta, filtered)
		if err != nil {
			return GroupKey{}, reports, err
		}
		reports = append(reports, KeyDelivery{AccountPub: memberAccount, Err: ErrMemberTargetMissing})
		return current, reports, nil
	}
	reports, err := s.DistributeKeys(ctx, current, meta, filtered)
	if err != nil {
		return GroupKey{}, reports, err
	}
	return current, reports, nil
}

// latestKey 返回本机该群的最新密钥；密钥环为空时先从本地库重载。
func (s *Service) latestKey(ctx context.Context, groupID []byte) (GroupKey, error) {
	version, raw, ok := s.keys.Latest(groupID)
	if !ok {
		if err := s.LoadKeys(ctx); err != nil {
			return GroupKey{}, err
		}
		version, raw, ok = s.keys.Latest(groupID)
	}
	if !ok {
		return GroupKey{}, ErrGroupKeyNotFound
	}
	return GroupKey{GroupID: groupID, Version: version, Key: raw}, nil
}

// requireAdmin 校验本机是该群管理员，并返回群记录与当前成员表。
func (s *Service) requireAdmin(ctx context.Context, groupID []byte) (*store.Group, []store.GroupMember, error) {
	if len(groupID) == 0 {
		return nil, nil, ErrGroupIDRequired
	}
	if s.dao == nil {
		return nil, nil, errors.New("缺少本地 DAO，无法校验群管理员")
	}
	g, err := s.dao.GetGroup(ctx, groupID)
	if errors.Is(err, store.ErrNotFound) {
		return nil, nil, ErrGroupKeyNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	if g.MyRole != KeyRoleAdmin {
		return nil, nil, ErrNotGroupAdmin
	}
	members, err := s.dao.ListMembers(ctx, groupID)
	if err != nil {
		return nil, nil, err
	}
	if len(members) == 0 {
		return nil, nil, ErrGroupEmpty
	}
	return g, members, nil
}

// rotate 以给定成员表生成下一版本密钥并分发。
func (s *Service) rotate(ctx context.Context, g *store.Group, members []store.GroupMember, targets []KeyTarget, groupID []byte) (GroupKey, []KeyDelivery, error) {
	current, err := s.latestKey(ctx, groupID)
	if err != nil {
		return GroupKey{}, nil, err
	}
	if current.Version == math.MaxUint32 {
		return GroupKey{}, nil, ErrKeyVersionExhausted
	}
	next, err := NewGroupKey(groupID, current.Version+1)
	if err != nil {
		return GroupKey{}, nil, err
	}
	// 群盘配置随密钥版本密封，轮换后需用新密钥重新封装才能继续被成员解开。
	storageCfg, err := resealStorageCfg(g.StorageCfgEnc, current, next)
	if err != nil {
		return GroupKey{}, nil, err
	}
	meta := GroupMeta{
		GroupID:        groupID,
		Title:          g.Title,
		Members:        memberAccounts(members),
		KeyVersion:     next.Version,
		OfflineEnabled: g.OfflineEnabled,
		StorageCfg:     storageCfg,
	}
	reports, err := s.DistributeKeys(ctx, next, meta, filterTargets(targets, meta.Members))
	if err != nil {
		return GroupKey{}, reports, err
	}
	return next, reports, nil
}

// filterTargets 只保留成员表内的目标，并按账号去重，避免向已离群成员或重复地址投递。
func filterTargets(targets []KeyTarget, members [][]byte) []KeyTarget {
	allowed := make(map[string]struct{}, len(members))
	for _, m := range members {
		allowed[string(m)] = struct{}{}
	}
	seen := make(map[string]struct{}, len(targets))
	out := make([]KeyTarget, 0, len(targets))
	for _, t := range targets {
		if _, ok := allowed[string(t.AccountPub)]; !ok {
			continue
		}
		if _, dup := seen[string(t.AccountPub)]; dup {
			continue
		}
		seen[string(t.AccountPub)] = struct{}{}
		out = append(out, t)
	}
	return out
}

// hasTarget 判断目标列表是否包含指定账号。
func hasTarget(targets []KeyTarget, account []byte) bool {
	for _, t := range targets {
		if bytes.Equal(t.AccountPub, account) {
			return true
		}
	}
	return false
}
