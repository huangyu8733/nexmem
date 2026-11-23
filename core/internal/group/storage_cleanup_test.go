package group

import (
	"context"
	"errors"
	"testing"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/internal/store"
)

// TestStorageRemovedNoticeFrame 覆盖群盘移除控制帧的编码与识别（C-05）。
func TestStorageRemovedNoticeFrame(t *testing.T) {
	frame := StorageRemovedNotice()
	if !IsStorageRemovedNotice([]byte(frame)) {
		t.Fatal("群盘移除控制帧应被识别")
	}
	if IsStorageRemovedNotice([]byte("普通群消息")) {
		t.Fatal("普通文本不应识别为群盘移除帧")
	}
	if !IsControlFrame([]byte(frame)) {
		t.Fatal("群盘移除帧应属于控制帧")
	}
	if IsDissolveNotice([]byte(frame)) {
		t.Fatal("群盘移除帧不应与解散帧混淆")
	}
}

// TestRemoveStorageClearsCloudAndLocal 验收 C-05 移除群盘：
// 管理员移除后云端 group_offline/{gid}/ 对象被删、本机配置被清空、离线开关关闭；
// 非管理员被拒绝。
func TestRemoveStorageClearsCloudAndLocal(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("c05-remove-storage")
	mn := mocknet.New()
	defer mn.Close()

	adminStore := newFakeObjectStore()
	admin := newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = func(StorageConfig) (ObjectStore, error) { return adminStore, nil }
	})
	member := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}
	seedGroup(t, admin, []*rotNode{member}, groupID, "C05 移除群盘群")

	// 配置群盘并写两条密文对象。
	cfg := testStorageConfig(t)
	if _, err := admin.svc.ConfigureStorage(ctx, groupID, cfg, nil); err != nil {
		t.Fatalf("配置群盘: %v", err)
	}
	for _, uuid := range []string{"m1", "m2"} {
		if _, err := adminStore.Put(ctx, StorageObjectKey(groupID, uuid), []byte("cipher"), "application/x-protobuf"); err != nil {
			t.Fatal(err)
		}
	}
	if len(adminStore.snapshot()) != 2 {
		t.Fatalf("应有 2 个云端对象，实际 %d", len(adminStore.snapshot()))
	}

	// 非管理员不能移除。
	if _, err := member.svc.RemoveStorage(ctx, groupID); !errors.Is(err, ErrNotGroupAdmin) {
		t.Fatalf("非管理员移除群盘应返回 ErrNotGroupAdmin，实际 %v", err)
	}
	if len(adminStore.snapshot()) != 2 {
		t.Fatal("非管理员被拒绝后云端对象不应被删")
	}

	// 管理员移除：删云端 + 清本机配置。
	deleted, err := admin.svc.RemoveStorage(ctx, groupID)
	if err != nil {
		t.Fatalf("移除群盘: %v", err)
	}
	if deleted != 2 {
		t.Fatalf("应删除 2 个云端对象，实际 %d", deleted)
	}
	if len(adminStore.snapshot()) != 0 {
		t.Fatalf("移除后云端对象应清空，实际 %d", len(adminStore.snapshot()))
	}
	if _, err := admin.svc.StorageConfigFor(ctx, groupID); !errors.Is(err, ErrStorageNotConfigured) {
		t.Fatalf("移除后本机应无群盘配置，实际 %v", err)
	}
	row, err := admin.dao.GetGroup(ctx, groupID)
	if err != nil {
		t.Fatal(err)
	}
	if row.OfflineEnabled {
		t.Fatal("移除群盘后离线开关应关闭")
	}
}

// TestDissolveGroupCleansCloud 验收 C-05 解散清理云端密文：
// 管理员解散后群盘云端对象被删除，本地群同时清理。
func TestDissolveGroupCleansCloud(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("c05-dissolve-clean")
	mn := mocknet.New()
	defer mn.Close()

	adminStore := newFakeObjectStore()
	admin := newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = func(StorageConfig) (ObjectStore, error) { return adminStore, nil }
	})
	member := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}
	seedGroup(t, admin, []*rotNode{member}, groupID, "C05 解散清理群")

	cfg := testStorageConfig(t)
	if _, err := admin.svc.ConfigureStorage(ctx, groupID, cfg, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := adminStore.Put(ctx, StorageObjectKey(groupID, "secret-msg"), []byte("cipher"), "application/x-protobuf"); err != nil {
		t.Fatal(err)
	}

	if err := admin.svc.DissolveGroup(ctx, groupID); err != nil {
		t.Fatalf("解散群: %v", err)
	}
	if len(adminStore.snapshot()) != 0 {
		t.Fatalf("解散后云端密文应清空，实际 %d", len(adminStore.snapshot()))
	}
	if _, err := admin.dao.GetGroup(ctx, groupID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("解散后本地群记录应删除，实际 %v", err)
	}
}

// TestApplyStorageRemovedGuardsAdmin 覆盖入站移除控制帧的管理员校验与本机清理。
func TestApplyStorageRemovedGuardsAdmin(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("c05-apply-removed")
	mn := mocknet.New()
	defer mn.Close()

	adminStore := newFakeObjectStore()
	admin := newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = func(StorageConfig) (ObjectStore, error) { return adminStore, nil }
	})
	member := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	seedGroup(t, admin, []*rotNode{member}, groupID, "C05 控制帧群")

	cfg := testStorageConfig(t)
	if _, err := admin.svc.ConfigureStorage(ctx, groupID, cfg, nil); err != nil {
		t.Fatal(err)
	}

	// 普通成员的帧应被拒绝。
	if applied, err := admin.svc.ApplyStorageRemoved(ctx, groupID, member.account.Pub()); err != nil || applied {
		t.Fatalf("非管理员移除帧应被拒绝: applied=%v err=%v", applied, err)
	}
	// 管理员的帧应生效。
	if applied, err := admin.svc.ApplyStorageRemoved(ctx, groupID, admin.account.Pub()); err != nil || !applied {
		t.Fatalf("管理员移除帧应生效: applied=%v err=%v", applied, err)
	}
	if _, err := admin.svc.StorageConfigFor(ctx, groupID); !errors.Is(err, ErrStorageNotConfigured) {
		t.Fatalf("应用移除帧后应无群盘配置，实际 %v", err)
	}
}

// TestCleanupGroupCloudNoConfig 覆盖未配置群盘时清理静默成功（解散普通群的常见路径）。
func TestCleanupGroupCloudNoConfig(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("c05-cleanup-noconfig")
	mn := mocknet.New()
	defer mn.Close()

	admin := newRotNode(t, mn)
	member := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	seedGroup(t, admin, []*rotNode{member}, groupID, "C05 无盘群")

	if n, err := admin.svc.cleanupGroupCloud(ctx, groupID); err != nil || n != 0 {
		t.Fatalf("未配置群盘清理应静默成功: n=%d err=%v", n, err)
	}
	if err := admin.svc.DissolveGroup(ctx, groupID); err != nil {
		t.Fatalf("解散未配置群盘的群也应成功: %v", err)
	}
}
