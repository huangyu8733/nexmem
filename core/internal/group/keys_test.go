package group

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
)

// keyCluster 是测试共享的成员表与账号 X25519 公钥。
type keyCluster struct {
	members [][]byte
	xpubs   map[string][]byte
}

// keyTestNode 是 P4-03 测试节点：mocknet host + 真实本地库。
type keyTestNode struct {
	account *identity.Account
	host    host.Host
	dao     *store.DAO
	db      *sql.DB
	svc     *Service
}

// newKeyTestNode 创建节点并注册群聊服务。
func newKeyTestNode(t *testing.T, mn mocknet.Mocknet, cluster *keyCluster) *keyTestNode {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()

	db, err := store.Open(filepath.Join(dir, "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库: %v", err)
	}
	if err := store.Migrate(ctx, db); err != nil {
		db.Close()
		t.Fatalf("迁移: %v", err)
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		db.Close()
		t.Fatalf("生成账号: %v", err)
	}
	h, err := mn.GenPeer()
	if err != nil {
		db.Close()
		t.Fatalf("创建 host: %v", err)
	}
	dao := store.NewDAO(db)
	svc, err := New(Options{
		Host:    h,
		Account: acc,
		DAO:     dao,
		Members: MemberFunc(func(context.Context, []byte) ([][]byte, error) {
			return cluster.members, nil
		}),
		XPub: XPubFunc(func(_ context.Context, accountPub []byte) ([]byte, error) {
			xpub, ok := cluster.xpubs[string(accountPub)]
			if !ok {
				return nil, errors.New("测试成员表中没有该账号的 X25519 公钥")
			}
			return xpub, nil
		}),
	})
	if err != nil {
		h.Close()
		db.Close()
		t.Fatalf("创建群聊服务: %v", err)
	}

	n := &keyTestNode{account: acc, host: h, dao: dao, db: db, svc: svc}
	cluster.members = append(cluster.members, acc.Pub())
	cluster.xpubs[string(acc.Pub())] = acc.XPub()
	t.Cleanup(func() {
		svc.Close()
		h.Close()
		db.Close()
	})
	return n
}

// TestGroupKeyDistribution 验收 P4-03：管理员生成群密钥并经单播信封分发给全部成员，
// 每个成员都能解出同一把密钥并解密群消息；非成员无法解密。
func TestGroupKeyDistribution(t *testing.T) {
	groupID := []byte("p4-key-group")
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	admin := newKeyTestNode(t, mn, cluster)
	m1 := newKeyTestNode(t, mn, cluster)
	m2 := newKeyTestNode(t, mn, cluster)
	outsider := newKeyTestNode(t, mn, cluster)
	// 非成员不属于群成员表。
	cluster.members = cluster.members[:3]

	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:        groupID,
		Title:          "P4 研发群",
		Members:        append([][]byte(nil), cluster.members...),
		KeyVersion:     key.Version,
		OfflineEnabled: true,
	}
	// m1 显式提供 X25519 公钥，m2 走解析器分支。
	targets := []KeyTarget{
		{PeerID: m1.host.ID(), Addrs: m1.host.Addrs(), AccountPub: m1.account.Pub(), XPub: m1.account.XPub()},
		{PeerID: m2.host.ID(), Addrs: m2.host.Addrs(), AccountPub: m2.account.Pub()},
	}
	reports, err := admin.svc.DistributeKeys(context.Background(), key, meta, targets)
	if err != nil {
		t.Fatalf("分发群密钥: %v", err)
	}
	if len(reports) != 2 {
		t.Fatalf("投递报告 %d 条，期望 2", len(reports))
	}
	for _, r := range reports {
		if r.Err != nil {
			t.Fatalf("成员 %x 投递失败: %v", r.AccountPub, r.Err)
		}
	}

	// 管理员与两名成员最终持有同一把密钥。
	for _, n := range []*keyTestNode{admin, m1, m2} {
		version, raw, ok := n.svc.keys.Latest(groupID)
		if !ok {
			t.Fatalf("节点 %x 缺少群密钥", n.account.Pub())
		}
		if version != key.Version || !bytes.Equal(raw, key.Key) {
			t.Fatalf("节点 %x 群密钥不一致", n.account.Pub())
		}
	}

	// 入群元数据已落库：标题、版本与成员表。
	for _, n := range []*keyTestNode{m1, m2} {
		g, err := n.dao.GetGroup(context.Background(), groupID)
		if err != nil {
			t.Fatalf("读取群记录: %v", err)
		}
		if g.Title != meta.Title || g.KeyVersion != int(key.Version) || !g.OfflineEnabled {
			t.Fatalf("群记录不符: %+v", g)
		}
		if g.MyRole != KeyRoleMember {
			t.Fatalf("成员角色 %d，期望普通成员", g.MyRole)
		}
		list, err := n.dao.ListMembers(context.Background(), groupID)
		if err != nil || len(list) != 3 {
			t.Fatalf("群成员表 %d 条（err=%v），期望 3", len(list), err)
		}
	}

	// 每个成员都能解密同一份正文。
	body, err := SealGroupBody(key, []byte("hello-group"))
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []*keyTestNode{admin, m1, m2} {
		raw, ok := n.svc.keys.Get(groupID, key.Version)
		if !ok {
			t.Fatalf("节点 %x 缺少 v%d 密钥", n.account.Pub(), key.Version)
		}
		plain, err := OpenGroupBody(GroupKey{GroupID: groupID, Version: key.Version, Key: raw}, body)
		if err != nil || string(plain) != "hello-group" {
			t.Fatalf("节点 %x 解密失败: %v", n.account.Pub(), err)
		}
	}

	// 非成员没有密钥，且即使截获信封也无法解封。
	if _, _, ok := outsider.svc.keys.Latest(groupID); ok {
		t.Fatal("非成员不应持有群密钥")
	}
	env, err := BuildKeyEnvelope(m1.account, key, m1.account.Pub(), m1.account.XPub(), meta)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := OpenKeyEnvelope(env, outsider.account); !errors.Is(err, ErrNotKeyRecipient) {
		t.Fatalf("非成员解封信封应返回 ErrNotKeyRecipient，实际 %v", err)
	}

	// 在线加密广播：成员收到并解出明文。
	received := make([]chan string, 3)
	services := []*Service{admin.svc, m1.svc, m2.svc}
	nodes := []*keyTestNode{admin, m1, m2}
	for i := range services {
		ch := make(chan string, 4)
		received[i] = ch
		idx := i
		services[i].onMsg = func(r Received) {
			if bytes.Equal(r.GroupID, groupID) && len(r.Plaintext) > 0 {
				select {
				case received[idx] <- string(r.Plaintext):
				default:
				}
			}
		}
		if err := services[i].Subscribe(context.Background(), groupID); err != nil {
			t.Fatalf("订阅 %d: %v", i, err)
		}
	}
	waitMesh(t, services, groupID, len(services))

	if _, err := admin.svc.PublishEncrypted(context.Background(), groupID, "encrypted-broadcast"); err != nil {
		t.Fatalf("加密广播: %v", err)
	}
	for i := 1; i < len(services); i++ {
		select {
		case got := <-received[i]:
			if got != "encrypted-broadcast" {
				t.Fatalf("节点 %x 收到 %q", nodes[i].account.Pub(), got)
			}
		case <-time.After(30 * time.Second):
			t.Fatalf("节点 %x 未在 30s 内收到加密群消息", nodes[i].account.Pub())
		}
	}
}

// TestKeyEnvelopeRejectsTamper 覆盖信封篡改、非成员构建与跨版本/错误密钥解密。
func TestKeyEnvelopeRejectsTamper(t *testing.T) {
	admin, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	member, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	groupID := []byte("g-tamper")
	key, err := NewGroupKey(groupID, 1)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      "tamper",
		Members:    [][]byte{admin.Pub(), member.Pub()},
		KeyVersion: 1,
	}
	env, err := BuildKeyEnvelope(admin, key, member.Pub(), member.XPub(), meta)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := OpenKeyEnvelope(env, member); err != nil {
		t.Fatalf("合法信封被拒绝: %v", err)
	}

	tampered := proto.Clone(env).(*nexmemv1.GroupKeyEnvelope)
	tampered.EncryptedGroupKey = append([]byte(nil), env.EncryptedGroupKey...)
	tampered.EncryptedGroupKey[len(tampered.EncryptedGroupKey)-1] ^= 0xff
	if _, _, err := OpenKeyEnvelope(tampered, member); !errors.Is(err, ErrKeyEnvelopeInvalid) {
		t.Fatalf("篡改封装应被拒绝，实际 %v", err)
	}

	wrongVersion := proto.Clone(env).(*nexmemv1.GroupKeyEnvelope)
	wrongVersion.KeyVersion = 2
	if _, _, err := OpenKeyEnvelope(wrongVersion, member); !errors.Is(err, ErrKeyEnvelopeInvalid) {
		t.Fatalf("篡改版本应被拒绝，实际 %v", err)
	}

	// 成员表不含目标成员时管理员不能构建信封。
	if _, err := BuildKeyEnvelope(admin, key, member.Pub(), member.XPub(), GroupMeta{
		GroupID: groupID,
		Members: [][]byte{admin.Pub()},
	}); !errors.Is(err, ErrNotMember) {
		t.Fatalf("非成员构建应返回 ErrNotMember，实际 %v", err)
	}

	// 错误密钥与跨版本都不能解密正文。
	body, err := SealGroupBody(key, []byte("secret"))
	if err != nil {
		t.Fatal(err)
	}
	other, err := NewGroupKey(groupID, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenGroupBody(other, body); !errors.Is(err, ErrBadEnvelope) {
		t.Fatalf("错误密钥应解密失败，实际 %v", err)
	}
	if _, err := OpenGroupBody(GroupKey{GroupID: groupID, Version: 2, Key: key.Key}, body); !errors.Is(err, ErrBadEnvelope) {
		t.Fatalf("跨版本应解密失败，实际 %v", err)
	}
}

// TestKeyPersistenceReload 校验群密钥落库后可在重启时重新装载。
func TestKeyPersistenceReload(t *testing.T) {
	groupID := []byte("p4-reload")
	mn := mocknet.New()
	defer mn.Close()
	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	node := newKeyTestNode(t, mn, cluster)

	key, err := NewGroupKey(groupID, 3)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      "reload",
		Members:    [][]byte{node.account.Pub()},
		KeyVersion: key.Version,
	}
	env, err := BuildKeyEnvelope(node.account, key, node.account.Pub(), node.account.XPub(), meta)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := node.svc.AcceptKeyEnvelope(context.Background(), env); err != nil {
		t.Fatalf("受理密钥信封: %v", err)
	}

	// 模拟进程重启：清空内存密钥环后从库重载。
	node.svc.keys = NewKeyring()
	if err := node.svc.LoadKeys(context.Background()); err != nil {
		t.Fatalf("重载群密钥: %v", err)
	}
	version, raw, ok := node.svc.keys.Latest(groupID)
	if !ok || version != key.Version || !bytes.Equal(raw, key.Key) {
		t.Fatalf("重载后密钥不一致: ok=%v version=%d", ok, version)
	}
}
