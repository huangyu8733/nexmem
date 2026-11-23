package group

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"sync"
	"testing"
	"time"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
)

// fakeObjectStore 是内存版群盘，支持注入写入错误以模拟上传失败。
type fakeObjectStore struct {
	mu      sync.Mutex
	objects map[string][]byte
	putErr  error
	puts    int
}

func newFakeObjectStore() *fakeObjectStore {
	return &fakeObjectStore{objects: make(map[string][]byte)}
}

func (f *fakeObjectStore) Put(_ context.Context, key string, data []byte, _ string) (blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.putErr != nil {
		return blob.ObjectInfo{}, f.putErr
	}
	f.puts++
	f.objects[key] = append([]byte(nil), data...)
	return blob.ObjectInfo{Key: key, Size: int64(len(data))}, nil
}

func (f *fakeObjectStore) Get(_ context.Context, key string) ([]byte, blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	data, ok := f.objects[key]
	if !ok {
		return nil, blob.ObjectInfo{}, blob.ErrNotFound
	}
	return append([]byte(nil), data...), blob.ObjectInfo{Key: key, Size: int64(len(data))}, nil
}

func (f *fakeObjectStore) List(_ context.Context, prefix string) ([]blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]blob.ObjectInfo, 0, len(f.objects))
	for key, data := range f.objects {
		if len(prefix) == 0 || len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			out = append(out, blob.ObjectInfo{Key: key, Size: int64(len(data))})
		}
	}
	return out, nil
}

// snapshot 返回对象键与内容的副本。
func (f *fakeObjectStore) snapshot() map[string][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make(map[string][]byte, len(f.objects))
	for k, v := range f.objects {
		out[k] = append([]byte(nil), v...)
	}
	return out
}

func (f *fakeObjectStore) putCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.puts
}

func testStorageConfig(t *testing.T) StorageConfig {
	t.Helper()
	return StorageConfig{
		Endpoint:  "https://s3.example.com",
		Bucket:    "nexmem-group-disk",
		Region:    "auto",
		AccessKey: "AKIA-TEST-KEY",
		SecretKey: "test-secret-value",
		PathStyle: false,
	}
}

// TestSealStorageConfig 校验群盘配置密封、解封与凭证不落明文。
func TestSealStorageConfig(t *testing.T) {
	groupID := []byte("p4-storage-seal")
	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	cfg := testStorageConfig(t)

	sealed, err := SealStorageConfig(key, cfg)
	if err != nil {
		t.Fatalf("密封群盘配置: %v", err)
	}
	if bytes.Contains(sealed, []byte(cfg.AccessKey)) || bytes.Contains(sealed, []byte(cfg.SecretKey)) {
		t.Fatal("群盘凭证不应以明文出现在配置密文中")
	}

	got, err := OpenStorageConfig(key, sealed)
	if err != nil {
		t.Fatalf("解封群盘配置: %v", err)
	}
	want := cfg
	want.Prefix = StoragePrefix(groupID)
	want.Region = "auto"
	if got != want {
		t.Fatalf("解封结果不一致:\n got=%+v\nwant=%+v", got, want)
	}
	if got.Prefix != "group_offline/"+keyB64(groupID)+"/" {
		t.Fatalf("群盘前缀错误: %s", got.Prefix)
	}

	// 末尾斜杠与空 Region 会被规范化。
	withSlash := cfg
	withSlash.Endpoint += "/"
	withSlash.Region = ""
	normalized, err := SealStorageConfig(key, withSlash)
	if err != nil {
		t.Fatal(err)
	}
	gotNormalized, err := OpenStorageConfig(key, normalized)
	if err != nil {
		t.Fatal(err)
	}
	if gotNormalized.Endpoint != cfg.Endpoint || gotNormalized.Region != "auto" {
		t.Fatalf("配置未规范化: %+v", gotNormalized)
	}

	// 错误版本密钥无法解封。
	other, err := NewGroupKey(groupID, key.Version+1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenStorageConfig(other, sealed); !errors.Is(err, ErrBadStorageConfig) {
		t.Fatalf("错误版本密钥应返回 ErrBadStorageConfig，实际 %v", err)
	}
	// 其他群的密钥无法解封。
	otherGroup, err := NewGroupKey([]byte("another-group"), key.Version)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenStorageConfig(otherGroup, sealed); !errors.Is(err, ErrBadStorageConfig) {
		t.Fatalf("跨群密钥应返回 ErrBadStorageConfig，实际 %v", err)
	}
	// 篡改密文。
	tampered := append([]byte(nil), sealed...)
	tampered[len(tampered)-1] ^= 0xff
	if _, err := OpenStorageConfig(key, tampered); err == nil {
		t.Fatal("篡改后的群盘配置不应解封成功")
	}
}

// TestStorageConfigRejectsInvalid 校验非法配置在落库前被拒绝。
func TestStorageConfigRejectsInvalid(t *testing.T) {
	groupID := []byte("p4-storage-invalid")
	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]StorageConfig{
		"缺少协议":  {Endpoint: "s3.example.com", Bucket: "b", AccessKey: "a", SecretKey: "s"},
		"缺少桶":   {Endpoint: "https://s3.example.com", AccessKey: "a", SecretKey: "s"},
		"缺少凭证":  {Endpoint: "https://s3.example.com", Bucket: "b"},
		"前缀被改写": {Endpoint: "https://s3.example.com", Bucket: "b", AccessKey: "a", SecretKey: "s", Prefix: "custom/"},
	}
	for name, cfg := range cases {
		if _, err := SealStorageConfig(key, cfg); !errors.Is(err, ErrBadStorageConfig) {
			t.Fatalf("%s: 期望 ErrBadStorageConfig，实际 %v", name, err)
		}
	}
}

// TestConfigureStoragePersistsAndGuardsAdmin 校验配置本机落库、管理员校验与非管理员拒绝。
func TestConfigureStoragePersistsAndGuardsAdmin(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-storage-configure")
	mn := mocknet.New()
	defer mn.Close()

	admin := newRotNode(t, mn)
	m1 := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}
	_ = seedGroup(t, admin, []*rotNode{m1}, groupID, "P4 群盘群")

	cfg := testStorageConfig(t)
	reports, err := admin.svc.ConfigureStorage(ctx, groupID, cfg, nil)
	if err != nil {
		t.Fatalf("配置群盘: %v", err)
	}
	if len(reports) != 0 {
		t.Fatalf("未提供 targets 时不应有投递报告，实际 %d 条", len(reports))
	}

	got, err := admin.svc.StorageConfigFor(ctx, groupID)
	if err != nil {
		t.Fatalf("读取群盘配置: %v", err)
	}
	cfg.Prefix = StoragePrefix(groupID)
	if got != cfg {
		t.Fatalf("落库后配置不一致:\n got=%+v\nwant=%+v", got, cfg)
	}

	row, err := admin.dao.GetGroup(ctx, groupID)
	if err != nil {
		t.Fatal(err)
	}
	if len(row.StorageCfgEnc) == 0 {
		t.Fatal("群记录应保存群盘配置密文")
	}
	if bytes.Contains(row.StorageCfgEnc, []byte(cfg.SecretKey)) {
		t.Fatal("群盘中不应落明文凭证")
	}
	if !row.OfflineEnabled {
		t.Fatal("配置群盘后应标记离线存储可用")
	}

	if _, err := m1.svc.ConfigureStorage(ctx, groupID, cfg, nil); !errors.Is(err, ErrNotGroupAdmin) {
		t.Fatalf("非管理员配置群盘应返回 ErrNotGroupAdmin，实际 %v", err)
	}
	if _, err := m1.svc.StorageConfigFor(ctx, groupID); !errors.Is(err, ErrStorageNotConfigured) {
		t.Fatalf("未收到配置的成员应返回 ErrStorageNotConfigured，实际 %v", err)
	}
}

// TestStorageConfigDistributedAndResealed 验收群盘配置随密钥信封分发，并在轮换后重新密封。
func TestStorageConfigDistributedAndResealed(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-storage-distribute")
	mn := mocknet.New()
	defer mn.Close()

	admin := newRotNode(t, mn)
	m1 := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}
	seedGroup(t, admin, []*rotNode{m1}, groupID, "P4 群盘分发群")

	cfg := testStorageConfig(t)
	reports, err := admin.svc.ConfigureStorage(ctx, groupID, cfg, []KeyTarget{targetOf(m1)})
	if err != nil {
		t.Fatalf("配置并分发群盘: %v", err)
	}
	if len(reports) != 1 || reports[0].Err != nil {
		t.Fatalf("成员接收群盘配置失败: %+v", reports)
	}

	cfg.Prefix = StoragePrefix(groupID)
	got, err := m1.svc.StorageConfigFor(ctx, groupID)
	if err != nil {
		t.Fatalf("成员读取群盘配置: %v", err)
	}
	if got != cfg {
		t.Fatalf("成员群盘配置不一致:\n got=%+v\nwant=%+v", got, cfg)
	}

	// 轮换后配置应用新版本密钥重新密封，成员仍可解封。
	v2, _, err := admin.svc.RotateKey(ctx, groupID, []KeyTarget{targetOf(m1)})
	if err != nil {
		t.Fatalf("轮换群密钥: %v", err)
	}
	if _, err := m1.svc.StorageConfigFor(ctx, groupID); err != nil {
		t.Fatalf("轮换后成员读取群盘配置失败: %v", err)
	}
	raw, err := m1.dao.GetGroup(ctx, groupID)
	if err != nil {
		t.Fatal(err)
	}
	key, err := m1.svc.groupKey(ctx, groupID, v2.Version)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenStorageConfig(key, raw.StorageCfgEnc); err != nil {
		t.Fatalf("轮换后配置未按新版本密封: %v", err)
	}
}

// storageCluster 创建管理员与两名成员，并建立全连通 mesh。
type storageCluster struct {
	mn            mocknet.Mocknet
	admin, m1, m2 *rotNode
	adminStore    *fakeObjectStore
	recv          []chan Received
	events        chan StorageEvent
	sent          chan SentEvent
}

func newStorageCluster(t *testing.T, mn mocknet.Mocknet, putErr error) *storageCluster {
	t.Helper()
	c := &storageCluster{
		mn:         mn,
		adminStore: newFakeObjectStore(),
		events:     make(chan StorageEvent, 8),
		sent:       make(chan SentEvent, 8),
	}
	c.adminStore.putErr = putErr

	adminStore := c.adminStore
	c.admin = newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = func(StorageConfig) (ObjectStore, error) { return adminStore, nil }
		o.OnStorage = func(ev StorageEvent) {
			select {
			case c.events <- ev:
			default:
			}
		}
		o.OnSent = func(ev SentEvent) {
			select {
			case c.sent <- ev:
			default:
			}
		}
	})
	m1ch := make(chan Received, 4)
	m2ch := make(chan Received, 4)
	c.recv = []chan Received{m1ch, m2ch}
	c.m1 = newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = func(StorageConfig) (ObjectStore, error) { return newFakeObjectStore(), nil }
		o.OnMessage = func(r Received) {
			select {
			case m1ch <- r:
			default:
			}
		}
	})
	c.m2 = newRotNodeWith(t, mn, func(o *Options) {
		o.StorageFactory = func(StorageConfig) (ObjectStore, error) { return newFakeObjectStore(), nil }
		o.OnMessage = func(r Received) {
			select {
			case m2ch <- r:
			default:
			}
		}
	})
	return c
}

// link 建立 mocknet 全连通链路与连接。
func (c *storageCluster) link(t *testing.T) {
	t.Helper()
	if err := c.mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := c.mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}
}

// start 建立链路、分发密钥、配置群盘并订阅主题。
func (c *storageCluster) start(t *testing.T, groupID []byte) {
	t.Helper()
	ctx := context.Background()
	c.link(t)
	seedGroup(t, c.admin, []*rotNode{c.m1, c.m2}, groupID, "P4 群盘验收群")
	reports, err := c.admin.svc.ConfigureStorage(ctx, groupID, testStorageConfig(t), []KeyTarget{targetOf(c.m1), targetOf(c.m2)})
	if err != nil {
		t.Fatalf("配置群盘: %v", err)
	}
	for _, r := range reports {
		if r.Err != nil {
			t.Fatalf("成员接收群盘配置失败: %v", r.Err)
		}
	}
	services := make([]*Service, 0, 3)
	for _, n := range []*rotNode{c.admin, c.m1, c.m2} {
		if err := n.svc.Subscribe(ctx, groupID); err != nil {
			t.Fatalf("订阅群: %v", err)
		}
		services = append(services, n.svc)
	}
	waitMesh(t, services, groupID, len(services))
}

// TestPublishEncryptedStoredSingleReplica 验收 P4-05：广播成功且群盘写入单副本对象。
func TestPublishEncryptedStoredSingleReplica(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-storage-publish")
	mn := mocknet.New()
	defer mn.Close()

	c := newStorageCluster(t, mn, nil)
	c.start(t, groupID)

	result, err := c.admin.svc.PublishEncryptedStored(ctx, groupID, "群盘持久化正文")
	if err != nil {
		t.Fatalf("发布群消息: %v", err)
	}
	if !result.Stored || result.StorageErr != nil {
		t.Fatalf("群盘应写入成功: stored=%v err=%v", result.Stored, result.StorageErr)
	}
	if result.MsgUUID == "" {
		t.Fatal("缺少 msg_uuid")
	}

	// 广播成功后应通知上层把本方消息落本地库（P1-20 群消息本地持久化）。
	select {
	case ev := <-c.sent:
		if ev.MsgUUID != result.MsgUUID || string(ev.Plaintext) != "群盘持久化正文" {
			t.Fatalf("落库回调内容不符: %+v", ev)
		}
		if !bytes.Equal(ev.GroupID, groupID) || ev.SentAt == 0 {
			t.Fatalf("落库回调缺少群 ID 或时间: %+v", ev)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("广播成功后未触发落库回调")
	}

	// 在线成员收到明文。
	for i, ch := range c.recv {
		select {
		case r := <-ch:
			if string(r.Plaintext) != "群盘持久化正文" {
				t.Fatalf("成员 %d 明文不符: %q", i, r.Plaintext)
			}
		case <-time.After(20 * time.Second):
			t.Fatalf("成员 %d 未收到群消息", i)
		}
	}

	objects := c.adminStore.snapshot()
	if len(objects) != 1 {
		t.Fatalf("群盘应只有一条单副本对象，实际 %d", len(objects))
	}
	wantKey := StorageObjectKey(groupID, result.MsgUUID)
	raw, ok := objects[wantKey]
	if !ok {
		t.Fatalf("群盘对象键错误: %v", objects)
	}
	env := &nexmemv1.GroupEnvelope{}
	if err := proto.Unmarshal(raw, env); err != nil {
		t.Fatalf("群盘对象不是合法信封: %v", err)
	}
	if err := VerifyEnvelope(env, time.Now(), DefaultMaxAge); err != nil {
		t.Fatalf("群盘对象验签失败: %v", err)
	}
	version, key, ok := c.admin.svc.keys.Latest(groupID)
	if !ok {
		t.Fatal("缺少群密钥")
	}
	body, err := OpenGroupBody(GroupKey{GroupID: groupID, Version: version, Key: key}, env.GetBody())
	if err != nil {
		t.Fatalf("群盘对象解密失败: %v", err)
	}
	if string(body) != "群盘持久化正文" {
		t.Fatalf("群盘对象正文不符: %q", body)
	}
	if c.adminStore.putCount() != 1 {
		t.Fatalf("应只写入一次，实际 %d 次", c.adminStore.putCount())
	}
}

// TestStorageUploadFailureKeepsBroadcast 验收 P4-05：上传失败不影响在线广播。
func TestStorageUploadFailureKeepsBroadcast(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-storage-failure")
	mn := mocknet.New()
	defer mn.Close()

	c := newStorageCluster(t, mn, errors.New("模拟对象存储不可用"))
	c.start(t, groupID)

	result, err := c.admin.svc.PublishEncryptedStored(ctx, groupID, "上传失败仍可在线")
	if err != nil {
		t.Fatalf("群盘失败不应影响广播: %v", err)
	}
	if result.Stored {
		t.Fatal("群盘写入失败时 Stored 应为 false")
	}
	if !errors.Is(result.StorageErr, ErrStorageWrite) {
		t.Fatalf("期望 ErrStorageWrite，实际 %v", result.StorageErr)
	}

	for i, ch := range c.recv {
		select {
		case r := <-ch:
			if string(r.Plaintext) != "上传失败仍可在线" {
				t.Fatalf("成员 %d 明文不符: %q", i, r.Plaintext)
			}
		case <-time.After(20 * time.Second):
			t.Fatalf("成员 %d 未收到群消息", i)
		}
	}

	select {
	case ev := <-c.events:
		if ev.MsgUUID != result.MsgUUID || ev.Err == nil {
			t.Fatalf("群盘失败事件不符: %+v", ev)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("未收到群盘失败事件")
	}
	if len(c.adminStore.snapshot()) != 0 {
		t.Fatal("上传失败时不应留下对象")
	}
}

// TestPublishWithoutStorageHints 校验未配群盘时广播照常、结果提示未配置。
func TestPublishWithoutStorageHints(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-storage-missing")
	mn := mocknet.New()
	defer mn.Close()

	c := newStorageCluster(t, mn, nil)
	// 不调用 ConfigureStorage，直接建链、分发密钥、订阅。
	c.link(t)
	seedGroup(t, c.admin, []*rotNode{c.m1, c.m2}, groupID, "P4 无群盘群")
	var services []*Service
	for _, n := range []*rotNode{c.admin, c.m1, c.m2} {
		if err := n.svc.Subscribe(ctx, groupID); err != nil {
			t.Fatal(err)
		}
		services = append(services, n.svc)
	}
	waitMesh(t, services, groupID, len(services))

	result, err := c.admin.svc.PublishEncryptedStored(ctx, groupID, "仅在线广播")
	if err != nil {
		t.Fatalf("未配群盘时广播应成功: %v", err)
	}
	if result.Stored || !errors.Is(result.StorageErr, ErrStorageNotConfigured) {
		t.Fatalf("期望未配置提示，实际 stored=%v err=%v", result.Stored, result.StorageErr)
	}
	select {
	case r := <-c.recv[0]:
		if string(r.Plaintext) != "仅在线广播" {
			t.Fatalf("明文不符: %q", r.Plaintext)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("成员未收到群消息")
	}
}

// keyB64 返回群 ID 的 base64url 编码，用于断言对象前缀。
func keyB64(groupID []byte) string {
	return base64.RawURLEncoding.EncodeToString(groupID)
}
