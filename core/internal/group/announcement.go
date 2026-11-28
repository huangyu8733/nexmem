package group

// 群公告（P6-26）。
//
// 公告只保存在本机 groups.announcement，管理员修改后广播控制帧，
// 成员收到帧并校验发送方为管理员后更新本机记录。控制帧与聊天正文共用
// 群主题，因此同样走端到端加密，且不落消息库、不生成聊天气泡。

import (
	"context"
	"errors"

	"github.com/nexmem/core/internal/store"
)

// SetAnnouncement 由管理员设置或清除群公告（空串表示清除）。
//
// 先落本机记录再尽力广播；广播失败不回滚本地结果，成员下次上线也无法补收，
// 与群撤回、群解散的通知语义一致。
func (s *Service) SetAnnouncement(ctx context.Context, groupID []byte, text string) (string, error) {
	if _, _, err := s.requireAdmin(ctx, groupID); err != nil {
		return "", err
	}
	if err := ValidateAnnouncement(text); err != nil {
		return "", err
	}
	if s.dao == nil {
		return "", errors.New("缺少本地 DAO，无法保存群公告")
	}
	if err := s.dao.SetGroupAnnouncement(ctx, groupID, text); err != nil {
		return "", err
	}
	if frame, err := EncodeAnnouncementNotice(text); err == nil {
		s.publishControlFrame(ctx, groupID, frame)
	}
	return text, nil
}

// ApplyAnnouncement 应用入站群公告控制帧：仅接受本地成员表登记的管理员发来的公告。
//
// 返回 false 表示发送方不是管理员，帧应被丢弃；群不存在或本地写入失败返回错误。
func (s *Service) ApplyAnnouncement(ctx context.Context, groupID, senderAccount []byte, text string) (bool, error) {
	admin, err := s.IsGroupAdmin(ctx, groupID, senderAccount)
	if err != nil {
		return false, err
	}
	if !admin {
		return false, nil
	}
	if err := ValidateAnnouncement(text); err != nil {
		return false, err
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO，无法保存群公告")
	}
	if err := s.dao.SetGroupAnnouncement(ctx, groupID, text); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrGroupKeyNotFound
		}
		return false, err
	}
	return true, nil
}
