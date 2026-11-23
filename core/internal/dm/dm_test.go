package dm

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
)

type testNode struct {
	dao     *store.DAO
	account *identity.Account
	host    host.Host
	svc     *Service
}

func newTestNode(t *testing.T, tag string, configure ...func(*Options)) *testNode {
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

	acc, err := identity.GenerateAccount()
	if err != nil {
		db.Close()
		t.Fatalf("%s 生成账号: %v", tag, err)
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(dir, "device.key"))
	if err != nil {
		db.Close()
		t.Fatalf("%s 生成设备密钥: %v", tag, err)
	}
	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey: priv,
		Listen:     []string{"/ip4/127.0.0.1/tcp/0"},
		UserAgent:  "nexmem-dm-test/0.1.0",
	})
	if err != nil {
		db.Close()
		t.Fatalf("%s 启动 host: %v", tag, err)
	}

	dao := store.NewDAO(db)
	opt := Options{
		Host:      h,
		DeviceKey: priv,
		DAO:       dao,
		Account:   acc,
		InboxDir:  filepath.Join(dir, "inbox"),
	}
	for _, fn := range configure {
		fn(&opt)
	}
	svc, err := New(opt)
	if err != nil {
		h.Close()
		db.Close()
		t.Fatalf("%s 创建单聊服务: %v", tag, err)
	}

	t.Cleanup(func() {
		svc.Close()
		h.Close()
		db.Close()
	})
	return &testNode{dao: dao, account: acc, host: h, svc: svc}
}

// listAscending 按时间升序返回会话内全部消息。
func listAscending(t *testing.T, dao *store.DAO, convID string) []store.Message {
	t.Helper()
	var desc []store.Message
	var cursor *store.MessageCursor
	for {
		page, err := dao.ListMessages(context.Background(), convID, cursor, 200)
		if err != nil {
			t.Fatalf("分页读取消息: %v", err)
		}
		if len(page) == 0 {
			break
		}
		desc = append(desc, page...)
		last := page[len(page)-1]
		cursor = &store.MessageCursor{SentAt: last.SentAt, MsgUUID: last.MsgUUID}
	}
	asc := make([]store.Message, len(desc))
	for i, m := range desc {
		asc[len(desc)-1-i] = m
	}
	return asc
}

func TestConversationIDSymmetric(t *testing.T) {
	a := []byte("alice-public-key")
	b := []byte("bob-public-key")
	if ConversationID(a, b) != ConversationID(b, a) {
		t.Fatalf("会话 ID 应对称")
	}
	if ConversationID(a, b) == ConversationID(a, a) {
		t.Fatalf("不同会话不应得到相同 ID")
	}
}

func TestUUIDv7Ordering(t *testing.T) {
	prev := ""
	for i := 0; i < 200; i++ {
		id, err := newUUIDv7(int64(1_700_000_000_000 + i))
		if err != nil {
			t.Fatal(err)
		}
		if len(id) != 36 || id[14] != '7' {
			t.Fatalf("UUIDv7 格式错误: %s", id)
		}
		if id <= prev {
			t.Fatalf("时间戳递增时 UUID 字符串序应递增: %s <= %s", id, prev)
		}
		prev = id
	}
}

func TestSendTextValidation(t *testing.T) {
	n := newTestNode(t, "A")
	ctx := context.Background()
	if _, err := n.svc.SendText(ctx, Target{AccountPub: n.account.Pub()}, "hi", ""); err != ErrSelfSend {
		t.Fatalf("自发消息应返回 ErrSelfSend，实际 %v", err)
	}
	if _, err := n.svc.SendText(ctx, Target{AccountPub: []byte("bad")}, "hi", ""); err != ErrInvalidTarget {
		t.Fatalf("非法账号公钥应返回 ErrInvalidTarget，实际 %v", err)
	}
	peerPub := make([]byte, 32)
	peerPub[0] = 1
	if _, err := n.svc.SendText(ctx, Target{AccountPub: peerPub}, "", ""); err != ErrEmptyText {
		t.Fatalf("空文本应返回 ErrEmptyText，实际 %v", err)
	}
}

// TestSendText1000 是 P1-11 的验收用例：两台独立设备（独立身份、独立库、独立 host）
// 直连互发 1000 条文本，要求对端全部收到且顺序与发送顺序一致。
func TestSendText1000(t *testing.T) {
	a := newTestNode(t, "A")
	b := newTestNode(t, "B")

	const count = 1000
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	target := Target{
		PeerID:     b.svc.host.ID(),
		Addrs:      b.svc.host.Addrs(),
		AccountPub: b.account.Pub(),
	}
	convID := ConversationID(a.account.Pub(), b.account.Pub())

	for i := 0; i < count; i++ {
		text := fmt.Sprintf("msg-%04d", i)
		if _, err := a.svc.SendText(ctx, target, text, ""); err != nil {
			t.Fatalf("发送第 %d 条消息失败: %v", i, err)
		}
	}

	if n, err := b.dao.CountMessages(ctx, convID); err != nil || n != count {
		t.Fatalf("B 收到 %d 条，期望 %d 条 (err=%v)", n, count, err)
	}
	if n, err := a.dao.CountMessages(ctx, convID); err != nil || n != count {
		t.Fatalf("A 本地应有 %d 条，实际 %d 条 (err=%v)", count, n, err)
	}

	incoming := listAscending(t, b.dao, convID)
	if len(incoming) != count {
		t.Fatalf("B 按升序读到 %d 条，期望 %d 条", len(incoming), count)
	}
	for i, m := range incoming {
		if m.State != store.MessageStateReceived {
			t.Fatalf("第 %d 条状态应为 received，实际 %d", i, m.State)
		}
		var inner nexmemv1.InnerMessage
		if err := proto.Unmarshal(m.BodyEnc, &inner); err != nil {
			t.Fatalf("第 %d 条正文解析失败: %v", i, err)
		}
		if want := fmt.Sprintf("msg-%04d", i); inner.GetText() != want {
			t.Fatalf("第 %d 条顺序错误：收到 %q，期望 %q", i, inner.GetText(), want)
		}
	}

	outgoing := listAscending(t, a.dao, convID)
	for i, m := range outgoing {
		if m.Direction != store.DirectionOut || m.State != store.MessageStateSent {
			t.Fatalf("第 %d 条出站消息方向或状态错误: dir=%d state=%d", i, m.Direction, m.State)
		}
	}

	conv, err := b.dao.GetConversation(ctx, convID)
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if conv.Unread != count {
		t.Fatalf("未读数应为 %d，实际 %d", count, conv.Unread)
	}
}
