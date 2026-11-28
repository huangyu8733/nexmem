package group

// 群头像与群介绍。
//
// 两项都是群内可见资料：管理员修改后先落本机 groups 表，再广播加密群控制帧；
// 成员收到帧并校验发送方为管理员后更新本机记录。控制帧不落消息库、不生成聊天气泡。

import (
	"context"
	"errors"

	"github.com/nexmem/core/internal/store"
)

// SetAvatar 由管理员设置或清除群头像（空串表示清除）。
// 头像必须是 512x512 JPEG 的 base64，校验由 ValidateGroupAvatarB64 完成。
func (s *Service) SetAvatar(ctx context.Context, groupID []byte, avatarB64 string) (string, error) {
	if _, _, err := s.requireAdmin(ctx, groupID); err != nil {
		return "", err
	}
	if err := ValidateGroupAvatarB64(avatarB64); err != nil {
		return "", err
	}
	if s.dao == nil {
		return "", errors.New("缺少本地 DAO，无法保存群头像")
	}
	if err := s.dao.SetGroupAvatar(ctx, groupID, avatarB64); err != nil {
		return "", err
	}
	if frame, err := EncodeGroupAvatarNotice(avatarB64); err == nil {
		s.publishControlFrame(ctx, groupID, frame)
	}
	return avatarB64, nil
}

// ApplyAvatar 应用入站群头像控制帧：仅接受本地成员表登记的管理员发来的头像。
func (s *Service) ApplyAvatar(ctx context.Context, groupID, senderAccount []byte, avatarB64 string) (bool, error) {
	admin, err := s.IsGroupAdmin(ctx, groupID, senderAccount)
	if err != nil {
		return false, err
	}
	if !admin {
		return false, nil
	}
	if err := ValidateGroupAvatarB64(avatarB64); err != nil {
		return false, err
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO，无法保存群头像")
	}
	if err := s.dao.SetGroupAvatar(ctx, groupID, avatarB64); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrGroupKeyNotFound
		}
		return false, err
	}
	return true, nil
}

// SetDescription 由管理员设置或清除群介绍（空串表示清除）。
func (s *Service) SetDescription(ctx context.Context, groupID []byte, text string) (string, error) {
	if _, _, err := s.requireAdmin(ctx, groupID); err != nil {
		return "", err
	}
	if err := ValidateGroupDescription(text); err != nil {
		return "", err
	}
	if s.dao == nil {
		return "", errors.New("缺少本地 DAO，无法保存群介绍")
	}
	if err := s.dao.SetGroupDescription(ctx, groupID, text); err != nil {
		return "", err
	}
	if frame, err := EncodeGroupDescriptionNotice(text); err == nil {
		s.publishControlFrame(ctx, groupID, frame)
	}
	return text, nil
}

// ApplyDescription 应用入站群介绍控制帧：仅接受本地成员表登记的管理员发来的介绍。
func (s *Service) ApplyDescription(ctx context.Context, groupID, senderAccount []byte, text string) (bool, error) {
	admin, err := s.IsGroupAdmin(ctx, groupID, senderAccount)
	if err != nil {
		return false, err
	}
	if !admin {
		return false, nil
	}
	if err := ValidateGroupDescription(text); err != nil {
		return false, err
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO，无法保存群介绍")
	}
	if err := s.dao.SetGroupDescription(ctx, groupID, text); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrGroupKeyNotFound
		}
		return false, err
	}
	return true, nil
}
