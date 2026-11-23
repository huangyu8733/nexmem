// nexmem-dmtest 是 P1-11 的内核 CLI 验收程序：
// 在同一进程内启动两台彼此独立的设备（各自的身份、数据库与 libp2p host），
// 由 A 向 B 连续发送 N 条文本并校验对端全部收到且顺序与发送顺序一致。
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
)

var (
	count   = flag.Int("count", 1000, "发送消息条数")
	dir     = flag.String("dir", "", "数据目录（留空则使用临时目录，结束后删除）")
	listen  = flag.String("listen", "/ip4/127.0.0.1/tcp/0", "两台设备的监听地址，逗号分隔（按序分配）")
	timeout = flag.Duration("timeout", 3*time.Minute, "整体超时")
)

type node struct {
	name    string
	db      *sql.DB
	dao     *store.DAO
	account *identity.Account
	host    host.Host
	svc     *dm.Service
}

func (n *node) close() {
	if n.svc != nil {
		n.svc.Close()
	}
	if n.host != nil {
		_ = n.host.Close()
	}
	if n.db != nil {
		_ = n.db.Close()
	}
}

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	root := *dir
	if root == "" {
		tmp, err := os.MkdirTemp("", "nexmem-dmtest-*")
		if err != nil {
			log.Fatalf("创建临时目录失败: %v", err)
		}
		root = tmp
		defer os.RemoveAll(tmp)
	}

	listens := splitListen(*listen)
	if len(listens) == 0 {
		log.Fatal("监听地址为空")
	}

	runCtx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()

	if err := run(runCtx, root, listens); err != nil {
		fmt.Printf("RESULT FAIL: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, root string, listens []string) error {
	a, err := newNode("A", filepath.Join(root, "a"), listenAt(listens, 0))
	if err != nil {
		return err
	}
	defer a.close()

	b, err := newNode("B", filepath.Join(root, "b"), listenAt(listens, 1))
	if err != nil {
		return err
	}
	defer b.close()

	fmt.Printf("DEVICE A account=%s peer=%s\n", shortID(a.account.ID()), a.host.ID())
	fmt.Printf("DEVICE B account=%s peer=%s\n", shortID(b.account.ID()), b.host.ID())

	target := dm.Target{
		PeerID:     b.host.ID(),
		Addrs:      b.host.Addrs(),
		AccountPub: b.account.Pub(),
	}
	convID := dm.ConversationID(a.account.Pub(), b.account.Pub())

	start := time.Now()
	for i := 0; i < *count; i++ {
		text := fmt.Sprintf("msg-%04d", i)
		if _, err := a.svc.SendText(ctx, target, text, ""); err != nil {
			return fmt.Errorf("发送第 %d 条失败: %w", i, err)
		}
		if (i+1)%100 == 0 || i+1 == *count {
			fmt.Printf("PROGRESS sent=%d\n", i+1)
		}
	}
	fmt.Printf("DM_SENT %d in %s\n", *count, time.Since(start).Round(time.Millisecond))

	received, err := b.dao.CountMessages(ctx, convID)
	if err != nil {
		return fmt.Errorf("统计接收数: %w", err)
	}
	if received != *count {
		return fmt.Errorf("接收条数 %d，期望 %d", received, *count)
	}
	fmt.Printf("DM_RECEIVED %d\n", received)

	msgs, err := listAscending(ctx, b.dao, convID)
	if err != nil {
		return err
	}
	if len(msgs) != *count {
		return fmt.Errorf("升序读取 %d 条，期望 %d", len(msgs), *count)
	}
	for i, m := range msgs {
		if m.State != store.MessageStateReceived {
			return fmt.Errorf("第 %d 条状态为 %d，期望 received", i, m.State)
		}
		var inner nexmemv1.InnerMessage
		if err := proto.Unmarshal(m.BodyEnc, &inner); err != nil {
			return fmt.Errorf("第 %d 条正文解析失败: %w", i, err)
		}
		if want := fmt.Sprintf("msg-%04d", i); inner.GetText() != want {
			return fmt.Errorf("第 %d 条顺序错误：收到 %q，期望 %q", i, inner.GetText(), want)
		}
	}
	fmt.Println("DM_ORDERED true")

	conv, err := b.dao.GetConversation(ctx, convID)
	if err != nil {
		return fmt.Errorf("读取会话: %w", err)
	}
	if conv.Unread != *count {
		return fmt.Errorf("未读数 %d，期望 %d", conv.Unread, *count)
	}
	fmt.Printf("DM_UNREAD %d\n", conv.Unread)

	out, err := listAscending(ctx, a.dao, convID)
	if err != nil {
		return err
	}
	for i, m := range out {
		if m.Direction != store.DirectionOut || m.State != store.MessageStateSent {
			return fmt.Errorf("第 %d 条出站记录方向 %d 状态 %d，期望 out/sent", i, m.Direction, m.State)
		}
	}
	fmt.Printf("DM_OUTBOUND_ACKED %d\n", len(out))

	fmt.Println("RESULT PASS")
	return nil
}

func newNode(name, dir, listen string) (*node, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("%s 创建数据目录: %w", name, err)
	}
	db, err := store.Open(filepath.Join(dir, "nexmem.db"))
	if err != nil {
		return nil, fmt.Errorf("%s 打开数据库: %w", name, err)
	}
	if err := store.Migrate(context.Background(), db); err != nil {
		db.Close()
		return nil, fmt.Errorf("%s 迁移数据库: %w", name, err)
	}
	acc, err := identity.LoadOrCreateAccount(filepath.Join(dir, "account.json"))
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("%s 加载账号: %w", name, err)
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(dir, "device.key"))
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("%s 加载设备密钥: %w", name, err)
	}
	h, err := netnode.NewHost(context.Background(), netnode.Config{
		PrivateKey:       priv,
		Listen:           []string{listen},
		UserAgent:        "nexmem-dmtest/0.1.0",
		EnableNATService: true,
		EnableHolePunch:  true,
	})
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("%s 启动 host: %w", name, err)
	}
	dao := store.NewDAO(db)
	svc, err := dm.New(dm.Options{
		Host:      h,
		DeviceKey: priv,
		DAO:       dao,
		Account:   acc,
	})
	if err != nil {
		h.Close()
		db.Close()
		return nil, fmt.Errorf("%s 创建单聊服务: %w", name, err)
	}
	return &node{name: name, db: db, dao: dao, account: acc, host: h, svc: svc}, nil
}

// listAscending 按时间升序返回会话内全部消息。
func listAscending(ctx context.Context, dao *store.DAO, convID string) ([]store.Message, error) {
	var desc []store.Message
	var cursor *store.MessageCursor
	for {
		page, err := dao.ListMessages(ctx, convID, cursor, 200)
		if err != nil {
			return nil, fmt.Errorf("分页读取消息: %w", err)
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
	return asc, nil
}

func splitListen(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

func listenAt(listens []string, idx int) string {
	if idx < len(listens) {
		return listens[idx]
	}
	return listens[0]
}

func shortID(id string) string {
	if len(id) <= 12 {
		return id
	}
	return id[:12]
}
