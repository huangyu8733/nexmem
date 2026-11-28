package group

// 群设置「允许成员互加好友」（默认关闭）。
//
// 开关只由管理员修改，设置值保存在本机 groups.allow_friend_add，并通过
// 群控制帧同步给成员；成员侧校验发送方为管理员后才更新本机值。
// 控制帧与聊天正文共用加密群主题，不落消息库、不生成聊天气泡。

import (
	"context"
	"errors"

	"github.com/nexmem/core/internal/store"
)

// SetAllowFriendAdd 由管理员开启或关闭「允许成员互加好友」。
//
// 先落本机记录再尽力广播；广播失败不回滚本地结果，与群公告语义一致。
func (s *Service) SetAllowFriendAdd(ctx context.Context, groupID []byte, enabled bool) (bool, error) {
	if _, _, err := s.requireAdmin(ctx, groupID); err != nil {
		return false, err
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO，无法保存群加好友设置")
	}
	if err := s.dao.SetGroupAllowFriendAdd(ctx, groupID, enabled); err != nil {
		return false, err
	}
	s.publishControlFrame(ctx, groupID, EncodeAllowFriendAddNotice(enabled))
	return enabled, nil
}

// ApplyAllowFriendAdd 应用入站加好友开关控制帧：仅接受本地成员表登记的管理员发来的设置。
//
// 返回 false 表示发送方不是管理员，帧应被丢弃；群不存在或本地写入失败返回错误。
func (s *Service) ApplyAllowFriendAdd(ctx context.Context, groupID, senderAccount []byte, enabled bool) (bool, error) {
	admin, err := s.IsGroupAdmin(ctx, groupID, senderAccount)
	if err != nil {
		return false, err
	}
	if !admin {
		return false, nil
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO，无法保存群加好友设置")
	}
	if err := s.dao.SetGroupAllowFriendAdd(ctx, groupID, enabled); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrGroupKeyNotFound
		}
		return false, err
	}
	return true, nil
}
