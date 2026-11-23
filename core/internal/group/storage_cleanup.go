package group

// 群盘移除与解散清理（C-05）。
//
// 需求原文：群管理员拥有配置、修改、移除群云盘及解散清理密文的权限；
// 子密钥仅授权读写对应群前缀且严禁跨群访问。
//
// 本文件负责两类"清理"：
//   - RemoveStorage：管理员移除群盘——尽力删除云端 group_offline/{gid}/ 下全部密文，
//     清本机配置，并广播移除控制帧让成员同步清理；
//   - cleanupGroupCloud：解散群时清理云端密文（在 LeaveGroup 删除本地密钥之前调用）。
//
// 云端删除失败不阻断本地移除/解散（与 C-02 已读删除一致），错误经 StorageEvent
// 回调上报，由 UI 记录诊断；云厂商侧 IAM 权限边界属部署责任，按 R-17 不伪造验证。

import (
	"context"
	"errors"
	"fmt"

	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/store"
)

// ObjectDeleter 是可选的云端对象删除能力。*blob.Client 实现它；
// 测试替身可只实现 ObjectStore（Put/Get/List），缺少 Delete 时跳过云端清理。
type ObjectDeleter interface {
	Delete(ctx context.Context, key string) error
}

// storageCleanupError 汇总云端清理的部分失败，便于上层记录诊断但不阻断解散。
type storageCleanupError struct {
	Deleted int
	Failed  int
	Cause   error
}

func (e *storageCleanupError) Error() string {
	return fmt.Sprintf("群盘云端清理：删除 %d 个、失败 %d 个：%v", e.Deleted, e.Failed, e.Cause)
}

func (e *storageCleanupError) Unwrap() error { return e.Cause }

// cleanupGroupCloud 尽力删除群盘云端 group_offline/{gid}/ 下的全部密文对象。
// 未配置群盘、对象存储不支持 Delete、列举/删除失败均返回可诊断错误，调用方据此告警，
// 但不影响本地移除/解散。返回成功删除的对象数。
func (s *Service) cleanupGroupCloud(ctx context.Context, groupID []byte) (int, error) {
	cfg, err := s.StorageConfigFor(ctx, groupID)
	if err != nil {
		if errors.Is(err, ErrStorageNotConfigured) {
			return 0, nil // 没配群盘，无需清理
		}
		return 0, err
	}
	objects, err := s.objectStore(cfg)
	if err != nil {
		return 0, err
	}
	deleter, ok := objects.(ObjectDeleter)
	if !ok {
		return 0, errors.New("群盘对象存储不支持删除")
	}
	list, err := objects.List(ctx, StoragePrefix(groupID))
	if err != nil {
		return 0, fmt.Errorf("列举群盘对象: %w", err)
	}
	deleted, failed := 0, 0
	var firstErr error
	for _, obj := range list {
		if err := deleter.Delete(ctx, obj.Key); err != nil {
			if errors.Is(err, blob.ErrNotFound) {
				continue // 已不存在视为成功
			}
			failed++
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		deleted++
	}
	if failed > 0 {
		return deleted, &storageCleanupError{Deleted: deleted, Failed: failed, Cause: firstErr}
	}
	return deleted, nil
}

// RemoveStorage 由管理员移除群盘：先尽力清理云端密文，再清本机配置并广播控制帧。
// 云端清理失败不阻断本机移除；返回云端删除数与可能的清理错误供上层诊断。
func (s *Service) RemoveStorage(ctx context.Context, groupID []byte) (int, error) {
	if _, _, err := s.requireAdmin(ctx, groupID); err != nil {
		return 0, err
	}
	if s.dao == nil {
		return 0, errors.New("缺少本地 DAO，无法移除群盘")
	}
	deleted, cleanErr := s.cleanupGroupCloud(ctx, groupID)
	if err := s.dao.ClearGroupStorage(ctx, groupID); err != nil {
		return deleted, err
	}
	// 广播移除控制帧；失败只影响成员即时同步，本机移除已生效。
	if frame := StorageRemovedNotice(); frame != "" {
		_, _ = s.PublishEncrypted(ctx, groupID, frame)
	}
	s.emitStorage(StorageEvent{GroupID: append([]byte(nil), groupID...), Err: cleanErr})
	return deleted, cleanErr
}

// ApplyStorageRemoved 应用入站群盘移除控制帧：仅接受本地成员表登记的管理员。
// 返回 false 表示发送方非管理员、帧应丢弃；群不存在或本地写入失败返回错误。
func (s *Service) ApplyStorageRemoved(ctx context.Context, groupID, senderAccount []byte) (bool, error) {
	admin, err := s.IsGroupAdmin(ctx, groupID, senderAccount)
	if err != nil {
		return false, err
	}
	if !admin {
		return false, nil
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO")
	}
	if err := s.dao.ClearGroupStorage(ctx, groupID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrGroupKeyNotFound
		}
		return false, err
	}
	return true, nil
}
