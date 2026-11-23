package group

// 退群与解散（P4-12）。
//
// 退群是纯本地语义：清理群记录、成员表、密钥、暂存消息并取消订阅，之后
// 不再接收该群任何消息；历史消息仍在本地，由客户端决定是否保留会话条目。
// 解散仅限管理员：先广播解散控制帧让在线成员同步清理，再执行本机退群。
// 成员收到解散帧时必须校验发送方在本地成员表内且角色为管理员，避免普通
// 成员伪造解散。

import (
	"context"
	"errors"

	"github.com/nexmem/core/internal/store"
)

// LeaveGroup 退出群聊：删除本地群记录（级联成员表与密钥）、清空密钥环与
// 暂存消息，并取消群主题订阅。群不存在返回 ErrGroupKeyNotFound。
func (s *Service) LeaveGroup(ctx context.Context, groupID []byte) error {
	if len(groupID) == 0 {
		return ErrGroupIDRequired
	}
	if s.dao == nil {
		return errors.New("缺少本地 DAO，无法退群")
	}
	if _, err := s.dao.GetGroup(ctx, groupID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return ErrGroupKeyNotFound
		}
		return err
	}
	if err := s.dao.DeleteGroup(ctx, groupID); err != nil {
		return err
	}
	s.Unsubscribe(groupID)
	s.keys.Drop(groupID)
	s.pendingMsgs.Drop(groupID)
	return nil
}

// DissolveGroup 解散群聊（仅管理员）：广播解散控制帧后执行本机退群。
// 广播失败不阻断本机解散，成员下次上线也无法再获得新密钥。
// C-05：解散前尽力清理群盘云端密文——必须在 LeaveGroup 丢弃群密钥之前进行，
// 否则群盘配置无法解封；云端清理失败只记告警，不阻断本地解散。
func (s *Service) DissolveGroup(ctx context.Context, groupID []byte) error {
	if _, _, err := s.requireAdmin(ctx, groupID); err != nil {
		return err
	}
	if _, cleanErr := s.cleanupGroupCloud(ctx, groupID); cleanErr != nil {
		s.emitStorage(StorageEvent{GroupID: append([]byte(nil), groupID...), Err: cleanErr})
	}
	_, _ = s.PublishEncrypted(ctx, groupID, dissolveNotice)
	return s.LeaveGroup(ctx, groupID)
}

// IsGroupAdmin 判断账号是否为本地记录的群管理员；群不存在返回
// ErrGroupKeyNotFound。用于校验入站解散控制帧的发送方身份。
func (s *Service) IsGroupAdmin(ctx context.Context, groupID, accountPub []byte) (bool, error) {
	if len(groupID) == 0 {
		return false, ErrGroupIDRequired
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO")
	}
	if _, err := s.dao.GetGroup(ctx, groupID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrGroupKeyNotFound
		}
		return false, err
	}
	members, err := s.dao.ListMembers(ctx, groupID)
	if err != nil {
		return false, err
	}
	for _, m := range members {
		if string(m.AccountPub) == string(accountPub) {
			return m.Role == KeyRoleAdmin, nil
		}
	}
	return false, nil
}
