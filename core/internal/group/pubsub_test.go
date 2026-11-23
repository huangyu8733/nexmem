package group

import (
	"context"
	"encoding/hex"
	"sync/atomic"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p-pubsub"
	pubsubpb "github.com/libp2p/go-libp2p-pubsub/pb"
	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/identity"
)

// TestTopicForStable 校验主题名格式与确定性。
func TestTopicForStable(t *testing.T) {
	groupID := []byte("group-alpha")
	a := TopicFor(groupID)
	b := TopicFor(append([]byte(nil), groupID...))
	if a != b {
		t.Fatalf("同一群 ID 主题不一致: %s != %s", a, b)
	}
	if len(a) <= len(TopicPrefix) {
		t.Fatalf("主题过短: %s", a)
	}
	if a[:len(TopicPrefix)] != TopicPrefix {
		t.Fatalf("主题前缀错误: %s", a)
	}
	if other := TopicFor([]byte("group-beta")); other == a {
		t.Fatalf("不同群 ID 不能映射到同一主题")
	}
}

// TestVerifyEnvelope 覆盖合法信封、篡改字段、过期时间与非成员签名。
func TestVerifyEnvelope(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	mk := func() *nexmemv1.GroupEnvelope {
		env := &nexmemv1.GroupEnvelope{
			GroupId:       []byte("g1"),
			SenderAccount: acc.Pub(),
			MsgUuid:       []byte("uuid-1"),
			SentAt:        now.UnixMilli(),
			KeyVersion:    1,
			Body:          []byte("hello"),
		}
		env.Signature = acc.Sign(canonicalEnvelope(env))
		return env
	}

	if err := VerifyEnvelope(mk(), now, DefaultMaxAge); err != nil {
		t.Fatalf("合法信封被拒绝: %v", err)
	}

	tampered := mk()
	tampered.Body = []byte("hacked")
	if err := VerifyEnvelope(tampered, now, DefaultMaxAge); err == nil {
		t.Fatal("篡改正文未被拒绝")
	}

	tampered = mk()
	tampered.GroupId = []byte("g2")
	if err := VerifyEnvelope(tampered, now, DefaultMaxAge); err == nil {
		t.Fatal("篡改群 ID 未被拒绝")
	}

	old := mk()
	old.SentAt = now.Add(-30 * 24 * time.Hour).UnixMilli()
	old.Signature = acc.Sign(canonicalEnvelope(old))
	if err := VerifyEnvelope(old, now, DefaultMaxAge); err == nil {
		t.Fatal("超出时间偏差未被拒绝")
	}

	other, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	forged := mk()
	forged.SenderAccount = other.Pub()
	forged.Signature = other.Sign(canonicalEnvelope(forged))
	// 签名与字段自洽，成员资格由 Service 校验，因此这里应通过。
	if err := VerifyEnvelope(forged, now, DefaultMaxAge); err != nil {
		t.Fatalf("自洽信封不应在签名层被拒绝: %v", err)
	}
	forged.Body = []byte("hacked")
	if err := VerifyEnvelope(forged, now, DefaultMaxAge); err == nil {
		t.Fatal("替换发送方后篡改正文未被拒绝")
	}
}

// TestFingerprintCache 覆盖去重、TTL 与容量淘汰。
func TestFingerprintCache(t *testing.T) {
	c := newFingerprintCache(50*time.Millisecond, 2)
	if !c.Add("a") {
		t.Fatal("首次写入应为新条目")
	}
	if c.Add("a") {
		t.Fatal("重复写入不应视为新条目")
	}
	if !c.Has("a") {
		t.Fatal("窗口内条目应可命中")
	}
	c.Add("b")
	c.Add("c") // 容量 2，应淘汰最旧的 a
	if c.Has("a") {
		t.Fatal("超出容量后最旧条目应被淘汰")
	}
	time.Sleep(80 * time.Millisecond)
	if c.Has("b") || c.Has("c") {
		t.Fatal("TTL 到期后条目应被清理")
	}
	if !c.Add("a") {
		t.Fatal("淘汰后同一指纹应可重新受理")
	}
}

// TestBroadcastFiftyNodes 验收 P4-01：50 人群在线广播覆盖率 100%。
func TestBroadcastFiftyNodes(t *testing.T) {
	const nodeCount = 50
	groupID := []byte("p4-broadcast-group")

	mn := mocknet.New()
	defer mn.Close()

	members := make([][]byte, nodeCount)
	accounts := make([]*identity.Account, nodeCount)
	for i := 0; i < nodeCount; i++ {
		acc, err := identity.GenerateAccount()
		if err != nil {
			t.Fatalf("生成账号 %d: %v", i, err)
		}
		accounts[i] = acc
		members[i] = acc.Pub()
	}
	source := MemberFunc(func(context.Context, []byte) ([][]byte, error) {
		return members, nil
	})

	counts := make([]atomic.Int32, nodeCount)
	services := make([]*Service, nodeCount)

	for i := 0; i < nodeCount; i++ {
		h, err := mn.GenPeer()
		if err != nil {
			t.Fatalf("创建节点 %d: %v", i, err)
		}
		idx := i
		svc, err := New(Options{
			Host:    h,
			Account: accounts[i],
			Members: source,
			OnMessage: func(r Received) {
				if string(r.GroupID) != string(groupID) {
					t.Errorf("节点 %d 收到其他群消息", idx)
					return
				}
				counts[idx].Add(1)
			},
		})
		if err != nil {
			t.Fatalf("创建群服务 %d: %v", i, err)
		}
		t.Cleanup(svc.Close)
		if err := svc.Subscribe(context.Background(), groupID); err != nil {
			t.Fatalf("订阅 %d: %v", i, err)
		}
		services[i] = svc
	}

	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	waitMesh(t, services, groupID, nodeCount)

	uuid, err := services[0].Publish(context.Background(), groupID, []byte("hello-50"), 1)
	if err != nil {
		t.Fatalf("发布: %v", err)
	}
	if _, err := hex.DecodeString(uuid); err != nil {
		t.Fatalf("msg_uuid 非十六进制: %q", uuid)
	}

	// 覆盖率按接收方统计：发布方以外的 49 个成员都必须收到。
	deadline := time.Now().Add(60 * time.Second)
	for {
		missing := 0
		for i := 1; i < nodeCount; i++ {
			if counts[i].Load() == 0 {
				missing++
			}
		}
		if missing == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("覆盖率未达 100%%，仍有 %d 个成员未收到", missing)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// TestPublishRejectsNonMember 校验非成员无法通过服务发布。
func TestPublishRejectsNonMember(t *testing.T) {
	mn := mocknet.New()
	defer mn.Close()
	h, err := mn.GenPeer()
	if err != nil {
		t.Fatal(err)
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	member, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	svc, err := New(Options{
		Host:    h,
		Account: acc,
		Members: MemberFunc(func(context.Context, []byte) ([][]byte, error) {
			return [][]byte{member.Pub()}, nil
		}),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()

	if _, err := svc.Publish(context.Background(), []byte("g"), []byte("hi"), 1); err != ErrNotMember {
		t.Fatalf("非成员发布应返回 ErrNotMember，实际 %v", err)
	}
}

// TestTamperedEnvelopeRejected 校验主题校验器拒绝篡改消息。
func TestTamperedEnvelopeRejected(t *testing.T) {
	mn := mocknet.New()
	defer mn.Close()
	h, err := mn.GenPeer()
	if err != nil {
		t.Fatal(err)
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	svc, err := New(Options{
		Host:    h,
		Account: acc,
		Members: MemberFunc(func(context.Context, []byte) ([][]byte, error) {
			return [][]byte{acc.Pub()}, nil
		}),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()

	groupID := []byte("g")
	env := &nexmemv1.GroupEnvelope{
		GroupId:       groupID,
		SenderAccount: acc.Pub(),
		MsgUuid:       []byte("u1"),
		SentAt:        time.Now().UnixMilli(),
		KeyVersion:    1,
		Body:          []byte("ok"),
	}
	env.Signature = acc.Sign(canonicalEnvelope(env))
	raw, err := proto.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	msg := &pubsub.Message{Message: &pubsubpb.Message{Data: raw}}
	if !svc.validate(context.Background(), groupID, msg) {
		t.Fatal("合法消息应通过校验")
	}
	env.Body = []byte("bad")
	raw, err = proto.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	if svc.validate(context.Background(), groupID, &pubsub.Message{Message: &pubsubpb.Message{Data: raw}}) {
		t.Fatal("篡改正文应被拒绝")
	}
}

// waitMesh 等待每个节点至少看到一个 mesh 邻居，避免发布时 mesh 尚未成形。
func waitMesh(t *testing.T, services []*Service, groupID []byte, nodeCount int) {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		ready := 0
		for _, svc := range services {
			if svc.Peers(groupID) > 0 {
				ready++
			}
		}
		if ready == nodeCount {
			// 再多等两个 GossipSub 心跳，让 mesh 稳定。
			time.Sleep(1500 * time.Millisecond)
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("mesh 未在 60s 内覆盖全部 %d 个节点", nodeCount)
}
