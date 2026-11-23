package dm

import (
	"bytes"
	"context"
	"errors"
	"testing"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/group"
	"github.com/nexmem/core/internal/store"
)

// metaCluster 是密钥信封测试的共享成员表。
type metaCluster struct {
	members *[][]byte
}

// newMemberGroup 在已有单聊节点上创建群聊服务，并把收到的密钥信封交给它受理。
func newMemberGroup(t *testing.T, n *testNode, cluster *metaCluster, configure ...func(*group.Options)) *group.Service {
	t.Helper()
	opt := group.Options{
		Host:    n.host,
		Account: n.account,
		DAO:     n.dao,
		Members: group.MemberFunc(func(context.Context, []byte) ([][]byte, error) {
			return *cluster.members, nil
		}),
	}
	for _, fn := range configure {
		fn(&opt)
	}
	svc, err := group.New(opt)
	if err != nil {
		t.Fatalf("创建群聊服务: %v", err)
	}
	t.Cleanup(svc.Close)
	return svc
}

// buildMetaEnvelope 构造一份发给指定成员的群密钥信封。
func buildMetaEnvelope(t *testing.T, admin *testNode, members [][]byte, receiver *testNode) (*nexmemv1.GroupKeyEnvelope, group.GroupKey, []byte) {
	t.Helper()
	groupID := []byte("p4-08-group")
	key, err := group.NewGroupKey(groupID, group.KeyVersionInitial)
	if err != nil {
		t.Fatalf("生成群密钥: %v", err)
	}
	meta := group.GroupMeta{
		GroupID:        groupID,
		Title:          "离线入群",
		Members:        append([][]byte(nil), members...),
		KeyVersion:     key.Version,
		OfflineEnabled: true,
	}
	env, err := group.BuildKeyEnvelope(admin.account, key, receiver.account.Pub(), receiver.account.XPub(), meta)
	if err != nil {
		t.Fatalf("构建密钥信封: %v", err)
	}
	return env, key, groupID
}

// TestGroupMetaDirectDelivery 校验群密钥信封经单聊直连投递后，接收方完成入群：
// 持有密钥、自动订阅群主题，且不产生任何会话或消息。
func TestGroupMetaDirectDelivery(t *testing.T) {
	members := [][]byte{}
	cluster := &metaCluster{members: &members}

	member := newTestNode(t, "M")
	memberGroup := newMemberGroup(t, member, cluster)
	member.svc.onGroupMeta = func(env *nexmemv1.GroupKeyEnvelope) error {
		_, _, err := memberGroup.AcceptKeyEnvelope(context.Background(), env)
		return err
	}

	admin := newTestNode(t, "A")
	members = append(members, admin.account.Pub(), member.account.Pub())

	env, key, groupID := buildMetaEnvelope(t, admin, members, member)
	ctx := context.Background()
	if err := admin.svc.SendGroupMeta(ctx, member.account.Pub(), member.host.ID(), member.host.Addrs(), env); err != nil {
		t.Fatalf("单聊投递密钥信封: %v", err)
	}

	version, raw, ok := memberGroup.LatestKey(groupID)
	if !ok || version != key.Version || !bytes.Equal(raw, key.Key) {
		t.Fatalf("成员未持有群密钥: ok=%v version=%d", ok, version)
	}
	if !memberGroup.Subscribed(groupID) {
		t.Fatalf("受理密钥信封后应自动订阅群主题")
	}

	convID := ConversationID(member.account.Pub(), admin.account.Pub())
	if _, err := member.dao.GetConversation(ctx, convID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("群密钥信封不应创建会话: err=%v", err)
	}
	if n, err := member.dao.CountMessages(ctx, convID); err != nil || n != 0 {
		t.Fatalf("群密钥信封不应写入消息表: n=%d err=%v", n, err)
	}
}

// TestGroupMetaOfflineJoin 校验被邀请成员离线时，密钥信封经离线票据上传，
// 成员上线拉取后完成入群；重复拉取不重复处理。
func TestGroupMetaOfflineJoin(t *testing.T) {
	inbox := newFakeInbox()
	members := [][]byte{}
	cluster := &metaCluster{members: &members}

	member := newTestNode(t, "M", func(o *Options) {
		o.Inbox = inbox
		o.DisableAutoFetch = true
	})
	memberGroup := newMemberGroup(t, member, cluster)
	member.svc.onGroupMeta = func(env *nexmemv1.GroupKeyEnvelope) error {
		_, _, err := memberGroup.AcceptKeyEnvelope(context.Background(), env)
		return err
	}

	dirSvc := &inboxDirectory{profile: offlineProfile(t, member.account, true)}
	admin := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = &inboxUploader{inbox: inbox}
		o.DisableAutoResume = true
	})
	adminGroup := newMemberGroup(t, admin, cluster, func(o *group.Options) {
		o.MetaSender = admin.svc
	})
	members = append(members, admin.account.Pub(), member.account.Pub())

	groupID := []byte("p4-08-group")
	key, err := group.NewGroupKey(groupID, group.KeyVersionInitial)
	if err != nil {
		t.Fatalf("生成群密钥: %v", err)
	}
	meta := group.GroupMeta{
		GroupID:        groupID,
		Title:          "离线入群",
		Members:        append([][]byte(nil), members...),
		KeyVersion:     key.Version,
		OfflineEnabled: true,
	}
	// 不提供 PeerID，强制走单聊离线投递。
	reports, err := adminGroup.DistributeKeys(context.Background(), key, meta, []group.KeyTarget{{
		AccountPub: member.account.Pub(),
		XPub:       member.account.XPub(),
	}})
	if err != nil {
		t.Fatalf("分发群密钥: %v", err)
	}
	if len(reports) != 1 || reports[0].Err != nil {
		t.Fatalf("离线分发应成功，实际 %+v", reports)
	}

	ctx := context.Background()
	rep, err := member.svc.FetchOffline(ctx)
	if err != nil {
		t.Fatalf("拉取离线收件箱: %v", err)
	}
	if rep.Imported != 1 {
		t.Fatalf("应导入 1 条密钥信封，实际 %+v", rep)
	}

	version, raw, ok := memberGroup.LatestKey(groupID)
	if !ok || version != key.Version || !bytes.Equal(raw, key.Key) {
		t.Fatalf("成员未持有群密钥: ok=%v version=%d", ok, version)
	}
	if !memberGroup.Subscribed(groupID) {
		t.Fatalf("离线入群后应自动订阅群主题")
	}

	convID := ConversationID(member.account.Pub(), admin.account.Pub())
	if _, err := member.dao.GetConversation(ctx, convID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("群密钥信封不应创建会话: err=%v", err)
	}

	rep2, err := member.svc.FetchOffline(ctx)
	if err != nil {
		t.Fatalf("二次拉取: %v", err)
	}
	if rep2.Imported != 0 {
		t.Fatalf("重复拉取不应重复处理，实际 %+v", rep2)
	}
}

// TestGroupMetaRejectWithoutHandler 校验接收端未注册群密钥回调时明确拒收，
// 发送方不会误判为送达。
func TestGroupMetaRejectWithoutHandler(t *testing.T) {
	member := newTestNode(t, "M")
	admin := newTestNode(t, "A")

	members := [][]byte{admin.account.Pub(), member.account.Pub()}
	env, _, _ := buildMetaEnvelope(t, admin, members, member)

	err := admin.svc.SendGroupMeta(context.Background(), member.account.Pub(), member.host.ID(), member.host.Addrs(), env)
	if !errors.Is(err, ErrPeerRejected) {
		t.Fatalf("未注册回调时应被拒收，实际 %v", err)
	}
}

// TestGroupMetaRejectsMismatchedReceiver 校验信封接收方与投递目标不一致时直接拒绝。
func TestGroupMetaRejectsMismatchedReceiver(t *testing.T) {
	admin := newTestNode(t, "A")
	member := newTestNode(t, "M")
	other := newTestNode(t, "O")

	members := [][]byte{admin.account.Pub(), member.account.Pub(), other.account.Pub()}
	env, _, _ := buildMetaEnvelope(t, admin, members, other)

	err := admin.svc.SendGroupMeta(context.Background(), member.account.Pub(), "", nil, env)
	if !errors.Is(err, ErrGroupMetaInvalid) {
		t.Fatalf("接收方不一致应返回 ErrGroupMetaInvalid，实际 %v", err)
	}
	if err := admin.svc.SendGroupMeta(context.Background(), member.account.Pub(), "", nil, nil); !errors.Is(err, ErrGroupMetaInvalid) {
		t.Fatalf("空信封应返回 ErrGroupMetaInvalid，实际 %v", err)
	}
}
