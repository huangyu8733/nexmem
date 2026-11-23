package dm

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
)

// syncMemStore 是内存对象存储替身，实现 ReadSyncStore（Put/Get/List）。
type syncMemStore struct {
	objects map[string][]byte
}

func newSyncMemStore() *syncMemStore {
	return &syncMemStore{objects: make(map[string][]byte)}
}

func (m *syncMemStore) Put(_ context.Context, key string, data []byte, _ string) (blob.ObjectInfo, error) {
	m.objects[key] = append([]byte(nil), data...)
	return blob.ObjectInfo{Key: key, Size: int64(len(data))}, nil
}

func (m *syncMemStore) Get(_ context.Context, key string) ([]byte, blob.ObjectInfo, error) {
	data, ok := m.objects[key]
	if !ok {
		return nil, blob.ObjectInfo{}, blob.ErrNotFound
	}
	return append([]byte(nil), data...), blob.ObjectInfo{Key: key, Size: int64(len(data))}, nil
}

func (m *syncMemStore) List(_ context.Context, prefix string) ([]blob.ObjectInfo, error) {
	out := make([]blob.ObjectInfo, 0, len(m.objects))
	for k, v := range m.objects {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			out = append(out, blob.ObjectInfo{Key: k, Size: int64(len(v))})
		}
	}
	return out, nil
}

// newSameAccountNode 创建共享同一账号、但独立 SQLite 与设备密钥的节点，模拟同一身份的两台设备。
func newSameAccountNode(t *testing.T, tag string, acc *identity.Account, shared *syncMemStore, notify *[]string) *testNode {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "nexmem.db"))
	if err != nil {
		t.Fatalf("%s 打开数据库: %v", tag, err)
	}
	if err := store.Migrate(ctx, db); err != nil {
		db.Close()
		t.Fatalf("%s 迁移: %v", tag, err)
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(dir, "device.key"))
	if err != nil {
		db.Close()
		t.Fatalf("%s 设备密钥: %v", tag, err)
	}
	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey: priv, Listen: []string{"/ip4/127.0.0.1/tcp/0"},
		UserAgent: "nexmem-readsync-test/0.1.0",
	})
	if err != nil {
		db.Close()
		t.Fatalf("%s host: %v", tag, err)
	}
	dao := store.NewDAO(db)
	svc, err := New(Options{
		Host: h, DeviceKey: priv, DAO: dao, Account: acc,
		InboxDir: filepath.Join(dir, "inbox"),
		ReadSyncStore: shared,
		DisableAutoFetch: true,
		OnReadSync: func(ids []string) {
			if notify != nil {
				*notify = append(*notify, ids...)
			}
		},
	})
	if err != nil {
		h.Close()
		db.Close()
		t.Fatalf("%s 服务: %v", tag, err)
	}
	t.Cleanup(func() { svc.Close(); h.Close(); db.Close() })
	return &testNode{dao: dao, account: acc, host: h, svc: svc}
}

// TestCrossDeviceReadSync 验收 C-04 本地闭环：设备 A 发布已读水位到共用桶，
// 设备 B 从同一桶拉取并应用，把本机出站消息推进到 read，并触发 OnReadSync 回调。
func TestCrossDeviceReadSync(t *testing.T) {
	ctx := context.Background()
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	shared := newSyncMemStore()
	var notified []string
	devA := newSameAccountNode(t, "deviceA", acc, shared, nil)
	devB := newSameAccountNode(t, "deviceB", acc, shared, &notified)

	convID := "dm:alice|bob"
	// 设备 B 有两条出站消息处于 sent/acked，等待被对端已读。
	if err := devB.dao.EnsureConversation(ctx, store.Conversation{ID: convID, Kind: store.ConversationKindDM}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UnixMilli()
	for i, msg := range []store.Message{
		{MsgUUID: "m1", ConversationID: convID, SenderAccount: acc.Pub(), SentAt: now - 1000,
			Direction: store.DirectionOut, ContentType: int(nexmemv1.ContentType_CONTENT_TYPE_TEXT),
			BodyEnc: []byte("c"), State: store.MessageStateSent},
		{MsgUUID: "m2", ConversationID: convID, SenderAccount: acc.Pub(), SentAt: now + 1000,
			Direction: store.DirectionOut, ContentType: int(nexmemv1.ContentType_CONTENT_TYPE_TEXT),
			BodyEnc: []byte("c"), State: store.MessageStateAcked},
	} {
		_ = i
		if err := devB.dao.PutMessage(ctx, msg); err != nil {
			t.Fatalf("写入消息: %v", err)
		}
	}

	// 设备 A 在 alice|bob 会话 markRead 到 now，发布水位。
	if err := devA.svc.PublishReadWatermark(ctx, convID, now); err != nil {
		t.Fatalf("设备 A 发布水位: %v", err)
	}
	// 设备 B 同步：应把 m1 推进到 read，m2（水位之后）保持原状。
	changed, err := devB.svc.SyncReadStates(ctx)
	if err != nil {
		t.Fatalf("设备 B 同步水位: %v", err)
	}
	if len(changed) != 1 || changed[0] != convID {
		t.Fatalf("应返回被推进的会话，实际 %+v", changed)
	}
	msgs := listAscending(t, devB.dao, convID)
	if len(msgs) != 2 {
		t.Fatalf("应有 2 条消息，实际 %d", len(msgs))
	}
	if msgs[0].State != store.MessageStateRead {
		t.Fatalf("m1 应被推进到 read，实际 %d", msgs[0].State)
	}
	if msgs[1].State == store.MessageStateRead {
		t.Fatalf("m2 在水位之后不应被标记 read，实际 %d", msgs[1].State)
	}

	// 幂等：再次同步不应报错，消息状态不变。
	if _, err := devB.svc.SyncReadStates(ctx); err != nil {
		t.Fatalf("幂等同步: %v", err)
	}
	// runOfflineFetch 会应用水位并经回调通知上层。
	devB.svc.runOfflineFetch()
	if len(notified) == 0 {
		t.Fatal("runOfflineFetch 应触发 OnReadSync 回调")
	}
}

// TestReadSyncDisabledWithoutStore 未注入可写桶时发布/拉取应返回 ErrReadSyncDisabled。
func TestReadSyncDisabledWithoutStore(t *testing.T) {
	node := newTestNode(t, "no-store")
	if err := node.svc.PublishReadWatermark(context.Background(), "dm:a|b", 123); err != ErrReadSyncDisabled {
		t.Fatalf("期望 ErrReadSyncDisabled，实际 %v", err)
	}
	if _, err := node.svc.SyncReadStates(context.Background()); err != ErrReadSyncDisabled {
		t.Fatalf("期望 ErrReadSyncDisabled，实际 %v", err)
	}
}
