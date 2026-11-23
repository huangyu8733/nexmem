package group

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"testing"
	"time"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/identity"
)

// fetchObjectStore 是带 LastModified / ETag 的内存群盘，用于校验游标水位。
type fetchObjectStore struct {
	mu      sync.Mutex
	seq     int64
	objects map[string]fetchObject
}

type fetchObject struct {
	data []byte
	mod  time.Time
	etag string
}

func newFetchObjectStore() *fetchObjectStore {
	return &fetchObjectStore{objects: make(map[string]fetchObject)}
}

func (f *fetchObjectStore) Put(_ context.Context, key string, data []byte, _ string) (blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.seq++
	obj := fetchObject{
		data: append([]byte(nil), data...),
		mod:  time.Now().Add(time.Duration(f.seq) * time.Millisecond),
		etag: "etag-" + hex.EncodeToString([]byte{byte(f.seq)}),
	}
	f.objects[key] = obj
	return objectInfo(key, obj), nil
}

func (f *fetchObjectStore) Get(_ context.Context, key string) ([]byte, blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	obj, ok := f.objects[key]
	if !ok {
		return nil, blob.ObjectInfo{}, blob.ErrNotFound
	}
	return append([]byte(nil), obj.data...), objectInfo(key, obj), nil
}

func (f *fetchObjectStore) List(_ context.Context, prefix string) ([]blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]blob.ObjectInfo, 0, len(f.objects))
	for key, obj := range f.objects {
		if bytes.HasPrefix([]byte(key), []byte(prefix)) {
			out = append(out, objectInfo(key, obj))
		}
	}
	return out, nil
}

func objectInfo(key string, obj fetchObject) blob.ObjectInfo {
	return blob.ObjectInfo{
		Key:          key,
		Size:         int64(len(obj.data)),
		ETag:         obj.etag,
		LastModified: obj.mod,
	}
}

// fetchCluster 是 P4-06 测试的双节点群盘环境。
type fetchCluster struct {
	shared        *fetchObjectStore
	admin, member *rotNode
	recv          chan Received
}

// newFetchCluster 创建管理员与离线成员，共享同一个群盘。
func newFetchCluster(t *testing.T, mn mocknet.Mocknet, memberTune func(*Options)) *fetchCluster {
	t.Helper()
	c := &fetchCluster{shared: newFetchObjectStore(), recv: make(chan Received, 16)}
	storeFactory := func(StorageConfig) (ObjectStore, error) { return c.shared, nil }

	c.admin = newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = storeFactory
		o.DisableAutoSubscribe = true
	})
	c.member = newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = storeFactory
		o.DisableAutoSubscribe = true
		o.OnMessage = func(r Received) {
			select {
			case c.recv <- r:
			default:
			}
		}
		if memberTune != nil {
			memberTune(o)
		}
	})
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}
	return c
}

// start 建立初始密钥与群盘配置（成员未订阅主题，模拟离线）。
func (c *fetchCluster) start(t *testing.T, groupID []byte) {
	t.Helper()
	ctx := context.Background()
	seedGroup(t, c.admin, []*rotNode{c.member}, groupID, "P4 群盘拉取群")
	reports, err := c.admin.svc.ConfigureStorage(ctx, groupID, testStorageConfig(t), []KeyTarget{targetOf(c.member)})
	if err != nil {
		t.Fatalf("配置群盘: %v", err)
	}
	for _, r := range reports {
		if r.Err != nil {
			t.Fatalf("成员接收群盘配置失败: %v", r.Err)
		}
	}
}

// drain 收集通道内的明文，按出现顺序返回。
func (c *fetchCluster) drain() []string {
	var out []string
	for {
		select {
		case r := <-c.recv:
			out = append(out, string(r.Plaintext))
		default:
			return out
		}
	}
}

// waitPlaintext 等待一条指定明文，超时失败。
func (c *fetchCluster) waitPlaintext(t *testing.T, want string) {
	t.Helper()
	deadline := time.After(15 * time.Second)
	for {
		select {
		case r := <-c.recv:
			if string(r.Plaintext) == want {
				return
			}
		case <-deadline:
			t.Fatalf("未在 15s 内补齐群消息 %q", want)
		}
	}
}

// TestGroupOfflineFetchCatchUp 验收 P4-06：离线成员上线后按群游标补齐消息，
// 并按信封的 key_version 选择对应版本密钥解密；重复拉取不重复交付。
func TestGroupOfflineFetchCatchUp(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-group-fetch-catchup")
	mn := mocknet.New()
	defer mn.Close()

	c := newFetchCluster(t, mn, nil)
	c.start(t, groupID)

	// 成员离线期间的两条消息只落到群盘，没有在线广播。
	for _, text := range []string{"离线消息-1", "离线消息-2"} {
		result, err := c.admin.svc.PublishEncryptedStored(ctx, groupID, text)
		if err != nil {
			t.Fatalf("发布群消息: %v", err)
		}
		if !result.Stored {
			t.Fatalf("群盘写入失败: %v", result.StorageErr)
		}
	}
	if len(c.drain()) != 0 {
		t.Fatal("离线成员不应收到在线广播")
	}

	// 上线补齐：一次导入两条，明文与 key_version 均正确。
	rep, err := c.member.svc.FetchGroup(ctx, groupID)
	if err != nil {
		t.Fatalf("拉取群盘: %v", err)
	}
	if rep.Scanned != 2 || rep.Imported != 2 || rep.Duplicate != 0 || rep.Skipped != 0 || rep.Failed != 0 {
		t.Fatalf("拉取报告不符: %+v", rep)
	}
	got := c.drain()
	if len(got) != 2 || got[0] != "离线消息-1" || got[1] != "离线消息-2" {
		t.Fatalf("补齐明文不符: %v", got)
	}
	cur, err := c.member.dao.GetCursor(ctx, GroupCursorScope(groupID))
	if err != nil {
		t.Fatalf("读取群游标: %v", err)
	}
	if cur.SeenAt == 0 {
		t.Fatal("群游标未推进")
	}

	// 重复拉取只记 Duplicate，不重复交付。
	rep, err = c.member.svc.FetchGroup(ctx, groupID)
	if err != nil {
		t.Fatalf("重复拉取: %v", err)
	}
	if rep.Imported != 0 || rep.Duplicate != 2 {
		t.Fatalf("重复拉取报告不符: %+v", rep)
	}
	if len(c.drain()) != 0 {
		t.Fatal("重复拉取不应重复交付")
	}

	// 轮换到 v2 后发布新消息，重置游标与指纹窗口后应能按版本解密 v1 + v2。
	if _, _, err := c.admin.svc.RotateKey(ctx, groupID, []KeyTarget{targetOf(c.member)}); err != nil {
		t.Fatalf("轮换群密钥: %v", err)
	}
	result, err := c.admin.svc.PublishEncryptedStored(ctx, groupID, "轮换后消息")
	if err != nil || !result.Stored {
		t.Fatalf("轮换后发布: stored=%v err=%v storageErr=%v", result.Stored, err, result.StorageErr)
	}
	c.member.svc.dedupe = newFingerprintCache(0, 0)
	if err := c.member.dao.DeleteCursor(ctx, GroupCursorScope(groupID)); err != nil {
		t.Fatalf("重置群游标: %v", err)
	}

	rep, err = c.member.svc.FetchGroup(ctx, groupID)
	if err != nil {
		t.Fatalf("全量重拉: %v", err)
	}
	if rep.Imported != 3 || rep.Skipped != 0 {
		t.Fatalf("全量重拉报告不符: %+v", rep)
	}
	versions := make(map[uint32]bool)
	for _, text := range c.drain() {
		switch text {
		case "离线消息-1", "离线消息-2":
			versions[1] = true
		case "轮换后消息":
			versions[2] = true
		default:
			t.Fatalf("未知明文 %q", text)
		}
	}
	if !versions[1] || !versions[2] {
		t.Fatalf("未按 key_version 解密: %v", versions)
	}
}

// TestGroupFetchSkipsInvalidObjects 校验群号不符、验签失败、缺密钥版本、本机消息等对象被跳过。
func TestGroupFetchSkipsInvalidObjects(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-group-fetch-invalid")
	mn := mocknet.New()
	defer mn.Close()

	c := newFetchCluster(t, mn, nil)
	c.start(t, groupID)

	valid, err := c.admin.svc.PublishEncryptedStored(ctx, groupID, "合法消息")
	if err != nil || !valid.Stored {
		t.Fatalf("发布合法消息: stored=%v err=%v storageErr=%v", valid.Stored, err, valid.StorageErr)
	}

	// 群号不符：签名合法但对象被写进别的群前缀。
	otherGroup := []byte("p4-group-other")
	otherKey, err := NewGroupKey(otherGroup, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	otherBody, err := SealGroupBody(otherKey, []byte("别的群"))
	if err != nil {
		t.Fatal(err)
	}
	otherEnv := signedEnvelope(t, c.admin.account, otherGroup, otherBody, otherKey.Version)
	if _, err := c.shared.Put(ctx, objectKeyFor(groupID, otherEnv), mustMarshal(t, otherEnv), "application/x-protobuf"); err != nil {
		t.Fatal(err)
	}

	// 验签失败：篡改已落库对象的最后一个字节。
	raw, _, err := c.shared.Get(ctx, StorageObjectKey(groupID, valid.MsgUUID))
	if err != nil {
		t.Fatal(err)
	}
	tampered := append([]byte(nil), raw...)
	tampered[len(tampered)-1] ^= 0xff
	if _, err := c.shared.Put(ctx, StorageObjectKey(groupID, valid.MsgUUID), tampered, "application/x-protobuf"); err != nil {
		t.Fatal(err)
	}

	// 本机消息：成员自己签发的信封在拉取时跳过。
	v1, v1key, ok := c.member.svc.keys.Latest(groupID)
	if !ok {
		t.Fatal("成员缺少 v1 群密钥")
	}
	ownBody, err := SealGroupBody(GroupKey{GroupID: groupID, Version: v1, Key: v1key}, []byte("我自己发的"))
	if err != nil {
		t.Fatal(err)
	}
	ownEnv := signedEnvelope(t, c.member.account, groupID, ownBody, v1)
	if _, err := c.shared.Put(ctx, objectKeyFor(groupID, ownEnv), mustMarshal(t, ownEnv), "application/x-protobuf"); err != nil {
		t.Fatal(err)
	}

	// 缺少密钥版本：信封声明 v99，本机没有对应版本密钥。
	futureKey, err := NewGroupKey(groupID, 99)
	if err != nil {
		t.Fatal(err)
	}
	futureBody, err := SealGroupBody(futureKey, []byte("未来版本"))
	if err != nil {
		t.Fatal(err)
	}
	futureEnv := signedEnvelope(t, c.admin.account, groupID, futureBody, 99)
	if _, err := c.shared.Put(ctx, objectKeyFor(groupID, futureEnv), mustMarshal(t, futureEnv), "application/x-protobuf"); err != nil {
		t.Fatal(err)
	}

	rep, err := c.member.svc.FetchGroup(ctx, groupID)
	if err != nil {
		t.Fatalf("拉取群盘: %v", err)
	}
	// 合法对象已被篡改，因此本次 Imported=0，其余 4 个非法对象全部跳过。
	if rep.Imported != 0 || rep.Skipped != 4 {
		t.Fatalf("非法对象过滤报告不符: %+v", rep)
	}
	if len(c.drain()) != 0 {
		t.Fatal("非法对象不应交付")
	}

	// 未配置群盘时返回 ErrGroupFetchDisabled。
	if _, err := c.member.svc.FetchGroup(ctx, []byte("p4-group-no-storage")); !errors.Is(err, ErrGroupFetchDisabled) {
		t.Fatalf("未配群盘应返回 ErrGroupFetchDisabled，实际 %v", err)
	}
}

// TestGroupFetchAllBackground 校验 FetchAll 后台轮询能在成员上线后自动补齐。
func TestGroupFetchAllBackground(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-group-fetch-loop")
	mn := mocknet.New()
	defer mn.Close()

	c := newFetchCluster(t, mn, func(o *Options) {
		o.FetchInterval = 200 * time.Millisecond
	})
	c.start(t, groupID)

	if _, err := c.admin.svc.PublishEncryptedStored(ctx, groupID, "后台补齐消息"); err != nil {
		t.Fatalf("发布群消息: %v", err)
	}
	c.waitPlaintext(t, "后台补齐消息")

	rep, err := c.member.svc.FetchGroup(ctx, groupID)
	if err != nil {
		t.Fatalf("手动拉取: %v", err)
	}
	if rep.Imported != 0 {
		t.Fatalf("后台已补齐的消息不应重复导入: %+v", rep)
	}
}

// signedEnvelope 构造并签名一个测试用的群信封。
func signedEnvelope(t *testing.T, signer *identity.Account, groupID, body []byte, version uint32) *nexmemv1.GroupEnvelope {
	t.Helper()
	uuid := make([]byte, 16)
	if _, err := rand.Read(uuid); err != nil {
		t.Fatal(err)
	}
	env := &nexmemv1.GroupEnvelope{
		GroupId:       append([]byte(nil), groupID...),
		SenderAccount: signer.Pub(),
		MsgUuid:       uuid,
		SentAt:        time.Now().UnixMilli(),
		KeyVersion:    version,
		Body:          append([]byte(nil), body...),
	}
	env.Signature = signer.Sign(canonicalEnvelope(env))
	return env
}

// objectKeyFor 按发送侧约定生成群盘对象键。
func objectKeyFor(groupID []byte, env *nexmemv1.GroupEnvelope) string {
	return StorageObjectKey(groupID, hex.EncodeToString(env.GetMsgUuid()))
}

func mustMarshal(t *testing.T, env *nexmemv1.GroupEnvelope) []byte {
	t.Helper()
	raw, err := proto.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
