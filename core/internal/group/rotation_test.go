package group

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"

	"github.com/libp2p/go-libp2p/core/host"
	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
)

// rotNode 是 P4-04 测试节点：成员来源直接读取本地 DAO，验证轮换后成员表收敛。
type rotNode struct {
	account *identity.Account
	host    host.Host
	dao     *store.DAO
	db      *sql.DB
	svc     *Service
}

func newRotNode(t *testing.T, mn mocknet.Mocknet) *rotNode {
	t.Helper()
	return newRotNodeWith(t, mn, nil)
}

// newRotNodeWith 允许测试按需覆盖服务参数（群盘工厂、回调等）。
func newRotNodeWith(t *testing.T, mn mocknet.Mocknet, tune func(*Options)) *rotNode {
	t.Helper()
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "nexmem.db"))
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
	opt := Options{
		Host:    h,
		Account: acc,
		DAO:     dao,
		Members: StoreMembers{DAO: dao},
	}
	if tune != nil {
		tune(&opt)
	}
	svc, err := New(opt)
	if err != nil {
		h.Close()
		db.Close()
		t.Fatalf("创建群聊服务: %v", err)
	}
	n := &rotNode{account: acc, host: h, dao: dao, db: db, svc: svc}
	t.Cleanup(func() {
		svc.Close()
		h.Close()
		db.Close()
	})
	return n
}

func targetOf(n *rotNode) KeyTarget {
	return KeyTarget{
		PeerID:     n.host.ID(),
		Addrs:      n.host.Addrs(),
		AccountPub: n.account.Pub(),
		XPub:       n.account.XPub(),
	}
}

func accountsOf(nodes ...*rotNode) [][]byte {
	out := make([][]byte, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, n.account.Pub())
	}
	return out
}

// seedGroup 让管理员签发 v1 群密钥并分发给其余成员。
func seedGroup(t *testing.T, admin *rotNode, members []*rotNode, groupID []byte, title string) GroupKey {
	t.Helper()
	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:        groupID,
		Title:          title,
		Members:        accountsOf(append([]*rotNode{admin}, members...)...),
		KeyVersion:     key.Version,
		OfflineEnabled: true,
	}
	targets := make([]KeyTarget, 0, len(members))
	for _, m := range members {
		targets = append(targets, targetOf(m))
	}
	reports, err := admin.svc.DistributeKeys(context.Background(), key, meta, targets)
	if err != nil {
		t.Fatalf("分发初始群密钥: %v", err)
	}
	for _, r := range reports {
		if r.Err != nil {
			t.Fatalf("成员 %x 接收初始密钥失败: %v", r.AccountPub, r.Err)
		}
	}
	return key
}

// TestRemoveMemberRotation 验收 P4-04：踢人后生成新版本密钥，只向剩余成员分发；
// 被移除成员保留旧密钥但无法解密新消息，也无法收到或解封新版本信封。
func TestRemoveMemberRotation(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-rotation")
	mn := mocknet.New()
	defer mn.Close()

	admin := newRotNode(t, mn)
	m1 := newRotNode(t, mn)
	m2 := newRotNode(t, mn)
	removed := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}

	v1 := seedGroup(t, admin, []*rotNode{m1, m2, removed}, groupID, "P4 轮换群")
	for _, n := range []*rotNode{admin, m1, m2, removed} {
		version, raw, ok := n.svc.keys.Latest(groupID)
		if !ok || version != v1.Version || !bytes.Equal(raw, v1.Key) {
			t.Fatalf("节点 %x 初始密钥不符: ok=%v version=%d", n.account.Pub(), ok, version)
		}
	}

	// 非管理员不能踢人。
	if _, _, err := m1.svc.RemoveMember(ctx, groupID, removed.account.Pub(), []KeyTarget{targetOf(removed)}); !errors.Is(err, ErrNotGroupAdmin) {
		t.Fatalf("非管理员踢人应返回 ErrNotGroupAdmin，实际 %v", err)
	}
	// 管理员不能移除自己。
	if _, _, err := admin.svc.RemoveMember(ctx, groupID, admin.account.Pub(), nil); !errors.Is(err, ErrCannotRemoveSelf) {
		t.Fatalf("移除管理员本人应返回 ErrCannotRemoveSelf，实际 %v", err)
	}
	// 不存在的成员。
	if _, _, err := admin.svc.RemoveMember(ctx, groupID, bytes.Repeat([]byte{0xab}, memberIDSize), nil); !errors.Is(err, ErrMemberNotFound) {
		t.Fatalf("移除不存在成员应返回 ErrMemberNotFound，实际 %v", err)
	}

	// targets 故意包含被移除成员，应被过滤掉。
	v2, reports, err := admin.svc.RemoveMember(ctx, groupID, removed.account.Pub(), []KeyTarget{
		targetOf(m1), targetOf(m2), targetOf(removed),
	})
	if err != nil {
		t.Fatalf("踢人与轮换: %v", err)
	}
	if v2.Version != v1.Version+1 {
		t.Fatalf("轮换后版本应为 %d，实际 %d", v1.Version+1, v2.Version)
	}
	if bytes.Equal(v2.Key, v1.Key) {
		t.Fatal("轮换后的密钥不应与旧版本相同")
	}
	if len(reports) != 2 {
		t.Fatalf("投递报告 %d 条，期望 2（被移除成员不投递）", len(reports))
	}
	for _, r := range reports {
		if r.Err != nil {
			t.Fatalf("剩余成员 %x 接收新密钥失败: %v", r.AccountPub, r.Err)
		}
	}

	for _, n := range []*rotNode{admin, m1, m2} {
		version, raw, ok := n.svc.keys.Latest(groupID)
		if !ok || version != v2.Version || !bytes.Equal(raw, v2.Key) {
			t.Fatalf("节点 %x 未切到新版本: ok=%v version=%d", n.account.Pub(), ok, version)
		}
		g, err := n.dao.GetGroup(ctx, groupID)
		if err != nil {
			t.Fatalf("读取群记录: %v", err)
		}
		if g.KeyVersion != int(v2.Version) {
			t.Fatalf("节点 %x 群记录版本 %d，期望 %d", n.account.Pub(), g.KeyVersion, v2.Version)
		}
		list, err := n.dao.ListMembers(ctx, groupID)
		if err != nil {
			t.Fatalf("读取成员表: %v", err)
		}
		if len(list) != 3 || containsAccount(list, removed.account.Pub()) {
			t.Fatalf("节点 %x 成员表未移除目标: %+v", n.account.Pub(), list)
		}
	}

	// 被移除成员仍持有旧版本，但拿不到新版本。
	if version, _, ok := removed.svc.keys.Latest(groupID); !ok || version != v1.Version {
		t.Fatalf("被移除成员应保留 v%d，实际 ok=%v version=%d", v1.Version, ok, version)
	}
	if _, ok := removed.svc.keys.Get(groupID, v2.Version); ok {
		t.Fatal("被移除成员不应持有新版本密钥")
	}

	// 旧密钥解密新消息必须失败。
	body, err := SealGroupBody(v2, []byte("after-remove"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenGroupBody(v1, body); !errors.Is(err, ErrBadEnvelope) {
		t.Fatalf("旧密钥解密新消息应失败，实际 %v", err)
	}

	// 新信封无法为已离群成员构建，截获他入信封也解不开。
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      "P4 轮换群",
		Members:    accountsOf(admin, m1, m2),
		KeyVersion: v2.Version,
	}
	if _, err := BuildKeyEnvelope(admin.account, v2, removed.account.Pub(), removed.account.XPub(), meta); !errors.Is(err, ErrNotMember) {
		t.Fatalf("为已移除成员构建信封应返回 ErrNotMember，实际 %v", err)
	}
	env, err := BuildKeyEnvelope(admin.account, v2, m1.account.Pub(), m1.account.XPub(), meta)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := OpenKeyEnvelope(env, removed.account); !errors.Is(err, ErrNotKeyRecipient) {
		t.Fatalf("被移除成员解封他人信封应返回 ErrNotKeyRecipient，实际 %v", err)
	}

	// 旧版本信封重放不得把成员表或版本回退。
	staleMeta := GroupMeta{
		GroupID:    groupID,
		Title:      "P4 轮换群",
		Members:    accountsOf(admin, m1, m2, removed),
		KeyVersion: v1.Version,
	}
	stale, err := BuildKeyEnvelope(admin.account, v1, m1.account.Pub(), m1.account.XPub(), staleMeta)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := m1.svc.AcceptKeyEnvelope(ctx, stale); err != nil {
		t.Fatalf("重放旧信封不应报错: %v", err)
	}
	g, err := m1.dao.GetGroup(ctx, groupID)
	if err != nil {
		t.Fatal(err)
	}
	if g.KeyVersion != int(v2.Version) {
		t.Fatalf("旧信封重放后版本回退到 %d", g.KeyVersion)
	}
	list, err := m1.dao.ListMembers(ctx, groupID)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 3 || containsAccount(list, removed.account.Pub()) {
		t.Fatalf("旧信封重放后成员表被回退: %+v", list)
	}
}

// TestInviteMemberSyncsMembers 验收入群：新成员拿到当前版本密钥，
// 原有成员同步到新成员表，重复邀请与非管理员邀请被拒绝。
func TestInviteMemberSyncsMembers(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-invite")
	mn := mocknet.New()
	defer mn.Close()

	admin := newRotNode(t, mn)
	m1 := newRotNode(t, mn)
	m2 := newRotNode(t, mn)
	if err := mn.LinkAll(); err != nil {
		t.Fatal(err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatal(err)
	}

	v1 := seedGroup(t, admin, []*rotNode{m1}, groupID, "P4 入群群")

	// 非管理员不能邀请。
	if _, _, err := m1.svc.InviteMember(ctx, groupID, m2.account.Pub(), []KeyTarget{targetOf(m2)}); !errors.Is(err, ErrNotGroupAdmin) {
		t.Fatalf("非管理员邀请应返回 ErrNotGroupAdmin，实际 %v", err)
	}
	// targets 缺少新成员地址。
	if _, _, err := admin.svc.InviteMember(ctx, groupID, m2.account.Pub(), []KeyTarget{targetOf(m1)}); !errors.Is(err, ErrMemberTargetMissing) {
		t.Fatalf("缺少新成员地址应返回 ErrMemberTargetMissing，实际 %v", err)
	}

	got, reports, err := admin.svc.InviteMember(ctx, groupID, m2.account.Pub(), []KeyTarget{targetOf(m1), targetOf(m2)})
	if err != nil {
		t.Fatalf("邀请成员: %v", err)
	}
	if got.Version != v1.Version || !bytes.Equal(got.Key, v1.Key) {
		t.Fatalf("入群应沿用当前版本 v%d，实际 v%d", v1.Version, got.Version)
	}
	if len(reports) != 2 {
		t.Fatalf("投递报告 %d 条，期望 2", len(reports))
	}
	for _, r := range reports {
		if r.Err != nil {
			t.Fatalf("成员 %x 投递失败: %v", r.AccountPub, r.Err)
		}
	}

	for _, n := range []*rotNode{admin, m1, m2} {
		version, raw, ok := n.svc.keys.Latest(groupID)
		if !ok || version != v1.Version || !bytes.Equal(raw, v1.Key) {
			t.Fatalf("节点 %x 入群后密钥不符", n.account.Pub())
		}
		list, err := n.dao.ListMembers(ctx, groupID)
		if err != nil {
			t.Fatal(err)
		}
		if len(list) != 3 || !containsAccount(list, m2.account.Pub()) {
			t.Fatalf("节点 %x 成员表未同步新成员: %+v", n.account.Pub(), list)
		}
	}

	// 新成员可以解密当前版本消息。
	body, err := SealGroupBody(v1, []byte("welcome"))
	if err != nil {
		t.Fatal(err)
	}
	raw, ok := m2.svc.keys.Get(groupID, v1.Version)
	if !ok {
		t.Fatal("新成员缺少当前版本密钥")
	}
	if plain, err := OpenGroupBody(GroupKey{GroupID: groupID, Version: v1.Version, Key: raw}, body); err != nil || string(plain) != "welcome" {
		t.Fatalf("新成员解密失败: %v", err)
	}

	// 重复邀请被拒绝。
	if _, _, err := admin.svc.InviteMember(ctx, groupID, m2.account.Pub(), []KeyTarget{targetOf(m2)}); !errors.Is(err, ErrAlreadyMember) {
		t.Fatalf("重复邀请应返回 ErrAlreadyMember，实际 %v", err)
	}
}

// TestKeyHistoryAndReplayGuards 校验多版本密钥持久化、重启重载，
// 以及同版本不同密钥被拒绝且不污染密钥环。
func TestKeyHistoryAndReplayGuards(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("p4-history")
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

	v1 := seedGroup(t, admin, []*rotNode{m1}, groupID, "P4 历史群")
	v2, _, err := admin.svc.RotateKey(ctx, groupID, []KeyTarget{targetOf(m1)})
	if err != nil {
		t.Fatalf("主动轮换: %v", err)
	}
	if v2.Version != v1.Version+1 {
		t.Fatalf("轮换版本应为 %d，实际 %d", v1.Version+1, v2.Version)
	}

	// 模拟重启：清空密钥环后从本地库重载，历史版本必须全部恢复。
	m1.svc.keys = NewKeyring()
	if err := m1.svc.LoadKeys(ctx); err != nil {
		t.Fatalf("重载群密钥: %v", err)
	}
	for _, want := range []GroupKey{v1, v2} {
		raw, ok := m1.svc.keys.Get(groupID, want.Version)
		if !ok || !bytes.Equal(raw, want.Key) {
			t.Fatalf("重载后缺少 v%d 密钥", want.Version)
		}
	}

	// 同版本不同密钥必须拒绝，且不能覆盖已持有的正确密钥。
	other, err := NewGroupKey(groupID, v2.Version)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      "P4 历史群",
		Members:    accountsOf(admin, m1),
		KeyVersion: other.Version,
	}
	bad, err := BuildKeyEnvelope(admin.account, other, m1.account.Pub(), m1.account.XPub(), meta)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := m1.svc.AcceptKeyEnvelope(ctx, bad); !errors.Is(err, ErrKeyEnvelopeInvalid) {
		t.Fatalf("同版本不同密钥应被拒绝，实际 %v", err)
	}
	raw, ok := m1.svc.keys.Get(groupID, v2.Version)
	if !ok || !bytes.Equal(raw, v2.Key) {
		t.Fatal("异常信封污染了本机 v2 密钥")
	}
	if version, _, _ := m1.svc.keys.Latest(groupID); version != v2.Version {
		t.Fatalf("异常信封改变了最新版本: %d", version)
	}
}

func containsAccount(list []store.GroupMember, account []byte) bool {
	for _, m := range list {
		if bytes.Equal(m.AccountPub, account) {
			return true
		}
	}
	return false
}
