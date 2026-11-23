package group

import (
	"context"
	"errors"
	"testing"

	"github.com/libp2p/go-libp2p/core/peer"
	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"
	"github.com/multiformats/go-multiaddr"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/identity"
)

// fakeMetaSender 记录 MetaSender 的调用参数。
type fakeMetaSender struct {
	calls   int
	account []byte
	peerID  peer.ID
	env     *nexmemv1.GroupKeyEnvelope
	err     error
}

func (f *fakeMetaSender) SendGroupMeta(_ context.Context, accountPub []byte, peerID peer.ID, _ []multiaddr.Multiaddr, env *nexmemv1.GroupKeyEnvelope) error {
	f.calls++
	f.account = append([]byte(nil), accountPub...)
	f.peerID = peerID
	f.env = env
	return f.err
}

// newFallbackNode 创建只用于投递路径测试的群聊服务。
func newFallbackNode(t *testing.T, sender GroupMetaSender, members []*identity.Account) (*Service, *identity.Account) {
	t.Helper()
	mn := mocknet.New()
	t.Cleanup(func() { _ = mn.Close() })

	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成账号: %v", err)
	}
	h, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("创建 host: %v", err)
	}
	list := make([][]byte, 0, len(members)+1)
	list = append(list, acc.Pub())
	for _, m := range members {
		list = append(list, m.Pub())
	}
	svc, err := New(Options{
		Host:       h,
		Account:    acc,
		MetaSender: sender,
		Members: MemberFunc(func(context.Context, []byte) ([][]byte, error) {
			return list, nil
		}),
	})
	if err != nil {
		t.Fatalf("创建群聊服务: %v", err)
	}
	t.Cleanup(svc.Close)
	return svc, acc
}

// TestSendKeyEnvelopeFallsBackToDM 校验直连流不可用（无 PeerID）时改走单聊通道。
func TestSendKeyEnvelopeFallsBackToDM(t *testing.T) {
	member, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成成员账号: %v", err)
	}
	sender := &fakeMetaSender{}
	svc, admin := newFallbackNode(t, sender, []*identity.Account{member})

	groupID := []byte("p4-08-fallback")
	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      "兜底投递",
		Members:    [][]byte{admin.Pub(), member.Pub()},
		KeyVersion: key.Version,
	}
	env, err := BuildKeyEnvelope(admin, key, member.Pub(), member.XPub(), meta)
	if err != nil {
		t.Fatalf("构建密钥信封: %v", err)
	}

	if err := svc.SendKeyEnvelope(context.Background(), KeyTarget{AccountPub: member.Pub()}, env); err != nil {
		t.Fatalf("直连不可用时应回退单聊通道，实际 %v", err)
	}
	if sender.calls != 1 {
		t.Fatalf("单聊通道应被调用 1 次，实际 %d", sender.calls)
	}
	if string(sender.account) != string(member.Pub()) || sender.env != env {
		t.Fatalf("单聊通道参数不符: account=%x", sender.account)
	}
}

// TestSendKeyEnvelopeReportsFallbackError 校验兜底通道失败时保留直连错误。
func TestSendKeyEnvelopeReportsFallbackError(t *testing.T) {
	member, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成成员账号: %v", err)
	}
	boom := errors.New("单聊不可用")
	sender := &fakeMetaSender{err: boom}
	svc, admin := newFallbackNode(t, sender, []*identity.Account{member})

	groupID := []byte("p4-08-fallback-error")
	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      "兜底失败",
		Members:    [][]byte{admin.Pub(), member.Pub()},
		KeyVersion: key.Version,
	}
	env, err := BuildKeyEnvelope(admin, key, member.Pub(), member.XPub(), meta)
	if err != nil {
		t.Fatalf("构建密钥信封: %v", err)
	}

	err = svc.SendKeyEnvelope(context.Background(), KeyTarget{AccountPub: member.Pub()}, env)
	if !errors.Is(err, ErrPeerUnreached) {
		t.Fatalf("兜底失败应保留 ErrPeerUnreached，实际 %v", err)
	}
	if !errors.Is(err, boom) {
		t.Fatalf("应包含兜底错误，实际 %v", err)
	}
}

// TestSendKeyEnvelopeWithoutFallback 校验未配置单聊通道时保持原有错误。
func TestSendKeyEnvelopeWithoutFallback(t *testing.T) {
	member, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成成员账号: %v", err)
	}
	svc, admin := newFallbackNode(t, nil, []*identity.Account{member})

	groupID := []byte("p4-08-no-fallback")
	key, err := NewGroupKey(groupID, KeyVersionInitial)
	if err != nil {
		t.Fatal(err)
	}
	meta := GroupMeta{
		GroupID:    groupID,
		Title:      "无兜底",
		Members:    [][]byte{admin.Pub(), member.Pub()},
		KeyVersion: key.Version,
	}
	env, err := BuildKeyEnvelope(admin, key, member.Pub(), member.XPub(), meta)
	if err != nil {
		t.Fatalf("构建密钥信封: %v", err)
	}
	if err := svc.SendKeyEnvelope(context.Background(), KeyTarget{AccountPub: member.Pub()}, env); !errors.Is(err, ErrPeerUnreached) {
		t.Fatalf("应返回 ErrPeerUnreached，实际 %v", err)
	}
}
