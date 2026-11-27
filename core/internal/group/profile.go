package group

// 本群称呼与等级（群内可见的成员资料）。
//
// 成员可以改自己的昵称；管理员可以改任意成员的昵称与等级。所有改动落本机
// group_members，并通过加密群控制帧同步；成员侧校验发送方是管理员，
// 只有「发送方 == 目标账号」的帧例外（该例外只允许改昵称，不允许自提等级）。

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"unicode/utf8"

	"github.com/nexmem/core/internal/contacts"
	"github.com/nexmem/core/internal/store"
)

// MaxNicknameRunes 是本群称呼允许的最大 UTF-8 字符数。
const MaxNicknameRunes = 24

// ErrNicknameTooLong 表示本群称呼超过 24 字。
var ErrNicknameTooLong = errors.New("本群称呼最多 24 字")

// MemberProfile 是控制帧与网关回包中的成员本群资料；Account 为 base64url 账号公钥。
type MemberProfile struct {
	Account  string `json:"account"`
	Nickname string `json:"nickname"`
	LevelID  string `json:"level_id"`
}

// ValidateNickname 校验本群称呼字符数；空串表示清除，合法。
func ValidateNickname(nickname string) error {
	if utf8.RuneCountInString(nickname) > MaxNicknameRunes {
		return ErrNicknameTooLong
	}
	return nil
}

// SetMemberProfile 设置指定成员的本群称呼与等级。
//
// nickname / level_id 为 nil 表示保持不变，空串表示清除。
// target == 本机账号时允许改自己的昵称，但设置非空等级仍需管理员；
// 改他人资料必须是管理员。等级关闭时等级 ID 强制清空。
func (s *Service) SetMemberProfile(ctx context.Context, groupID, account []byte, nickname, levelID *string) (MemberProfile, error) {
	if len(groupID) == 0 {
		return MemberProfile{}, ErrGroupIDRequired
	}
	if len(account) != memberIDSize {
		return MemberProfile{}, ErrMemberNotFound
	}
	if s.dao == nil {
		return MemberProfile{}, errors.New("缺少本地 DAO，无法保存成员本群资料")
	}
	g, err := s.dao.GetGroup(ctx, groupID)
	if errors.Is(err, store.ErrNotFound) {
		return MemberProfile{}, ErrGroupKeyNotFound
	}
	if err != nil {
		return MemberProfile{}, err
	}
	self := bytes.Equal(account, s.account.Pub())
	// 管理员给自己设置等级与给他人设置等级走同一条权限判断：
	// UI 对管理员开放了自设等级，内核不能因为目标是自己就按普通成员拒绝。
	admin := g.MyRole == KeyRoleAdmin
	if !admin && !self {
		return MemberProfile{}, ErrNotGroupAdmin
	}
	currentNickname, currentLevelID, err := s.dao.GetGroupMemberProfile(ctx, groupID, account)
	if errors.Is(err, store.ErrNotFound) {
		return MemberProfile{}, ErrMemberNotFound
	}
	if err != nil {
		return MemberProfile{}, err
	}
	nick, level := currentNickname, currentLevelID
	if nickname != nil {
		if err := ValidateNickname(*nickname); err != nil {
			return MemberProfile{}, err
		}
		nick = *nickname
	}
	if levelID != nil {
		if *levelID == "" {
			level = ""
		} else {
			if !admin {
				return MemberProfile{}, ErrNotGroupAdmin
			}
			if g.LevelsEnabled {
				levels, err := parseLevelConfig(g.LevelsJSON)
				if err != nil {
					return MemberProfile{}, err
				}
				found := false
				for _, lv := range levels {
					if lv.ID == *levelID {
						found = true
						break
					}
				}
				if !found {
					return MemberProfile{}, ErrLevelNotFound
				}
				level = *levelID
			} else {
				level = ""
			}
		}
	}
	if !g.LevelsEnabled {
		level = ""
	}
	if err := s.dao.SetMemberProfile(ctx, groupID, account, nick, level); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return MemberProfile{}, ErrMemberNotFound
		}
		return MemberProfile{}, err
	}
	profile := MemberProfile{Account: encodeAccountID(account), Nickname: nick, LevelID: level}
	if frame, err := EncodeMemberProfileNotice(profile); err == nil {
		_, _ = s.PublishEncryptedStored(ctx, groupID, frame)
	}
	return profile, nil
}

// ApplyMemberProfile 应用入站成员资料控制帧。
//
// 发送方是管理员，或发送方就是帧中的目标账号（只允许改昵称，等级必须保持原值）
// 时才更新本机记录；其余情况返回 false，由调用方丢弃该帧。
func (s *Service) ApplyMemberProfile(ctx context.Context, groupID, senderAccount []byte, profile MemberProfile) (bool, error) {
	account, err := contacts.ParseAccountID(profile.Account)
	if err != nil {
		return false, nil
	}
	if len(account) != memberIDSize {
		return false, nil
	}
	admin, err := s.IsGroupAdmin(ctx, groupID, senderAccount)
	if err != nil {
		return false, err
	}
	self := bytes.Equal(senderAccount, account)
	if !admin && !self {
		return false, nil
	}
	if err := ValidateNickname(profile.Nickname); err != nil {
		return false, err
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO，无法保存成员本群资料")
	}
	g, err := s.dao.GetGroup(ctx, groupID)
	if errors.Is(err, store.ErrNotFound) {
		return false, ErrGroupKeyNotFound
	}
	if err != nil {
		return false, err
	}
	level := profile.LevelID
	if !admin {
		// 非管理员只能改自己的昵称：等级字段必须与本机现值一致，防止自提等级。
		_, currentLevel, err := s.dao.GetGroupMemberProfile(ctx, groupID, account)
		if err != nil {
			return false, err
		}
		if level != currentLevel {
			return false, nil
		}
	}
	if !g.LevelsEnabled {
		level = ""
	} else if level != "" {
		levels, err := parseLevelConfig(g.LevelsJSON)
		if err != nil {
			return false, err
		}
		found := false
		for _, lv := range levels {
			if lv.ID == level {
				found = true
				break
			}
		}
		if !found {
			return false, fmt.Errorf("%w: %s", ErrLevelNotFound, level)
		}
	}
	if err := s.dao.SetMemberProfile(ctx, groupID, account, profile.Nickname, level); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrMemberNotFound
		}
		return false, err
	}
	return true, nil
}
