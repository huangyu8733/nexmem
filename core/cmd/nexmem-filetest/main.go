// nexmem-filetest 是 P2-04 的内核 CLI 验收程序：两台独立设备直连传输一个大文件，
// 校验分片加密传输完整、落盘摘要一致，并统计 transfer.progress 的节流效果。
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
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
	size    = flag.Int64("size", 1<<30, "测试文件大小（字节），默认 1 GiB")
	dir     = flag.String("dir", "", "数据目录（留空则使用临时目录，结束后删除）")
	listen  = flag.String("listen", "/ip4/127.0.0.1/tcp/0", "两台设备的监听地址，逗号分隔（按序分配）")
	timeout = flag.Duration("timeout", 10*time.Minute, "整体超时")
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
		tmp, err := os.MkdirTemp("", "nexmem-filetest-*")
		if err != nil {
			log.Fatalf("创建临时目录失败: %v", err)
		}
		root = tmp
		defer os.RemoveAll(tmp)
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		log.Fatalf("创建数据目录失败: %v", err)
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

type progressStat struct {
	mu     sync.Mutex
	events int
	last   time.Time
	maxGap time.Duration
	final  bool
}

func (p *progressStat) record(ev dm.TransferProgress) {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	if !p.last.IsZero() {
		if gap := now.Sub(p.last); gap > p.maxGap {
			p.maxGap = gap
		}
	}
	p.last = now
	p.events++
	if ev.Total > 0 && ev.Done >= ev.Total {
		p.final = true
	}
}

func run(ctx context.Context, root string, listens []string) error {
	var sendStat, recvStat progressStat
	a, err := newNode("A", filepath.Join(root, "a"), listenAt(listens, 0), sendStat.record)
	if err != nil {
		return err
	}
	defer a.close()

	b, err := newNode("B", filepath.Join(root, "b"), listenAt(listens, 1), recvStat.record)
	if err != nil {
		return err
	}
	defer b.close()

	src := filepath.Join(root, "payload.bin")
	if err := writeTestFile(src, *size); err != nil {
		return err
	}
	sum, err := fileSHA256(src)
	if err != nil {
		return err
	}
	fmt.Printf("FILE_SIZE %d\n", *size)
	fmt.Printf("DEVICE A account=%s peer=%s\n", shortID(a.account.ID()), a.host.ID())
	fmt.Printf("DEVICE B account=%s peer=%s\n", shortID(b.account.ID()), b.host.ID())

	target := dm.Target{
		PeerID:     b.host.ID(),
		Addrs:      b.host.Addrs(),
		AccountPub: b.account.Pub(),
	}

	start := time.Now()
	msgID, err := a.svc.SendFile(ctx, target, src, "application/octet-stream")
	elapsed := time.Since(start)
	if err != nil {
		return fmt.Errorf("发送文件失败: %w", err)
	}
	fmt.Printf("FILE_ELAPSED %s\n", elapsed.Round(time.Millisecond))

	recvMsg, err := b.dao.GetMessage(ctx, msgID)
	if err != nil {
		return fmt.Errorf("读取接收消息: %w", err)
	}
	if recvMsg.State != store.MessageStateReceived {
		return fmt.Errorf("接收消息状态 %d，期望 received", recvMsg.State)
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(recvMsg.BodyEnc, inner); err != nil {
		return fmt.Errorf("解析附件: %w", err)
	}
	if len(inner.Attachments) != 1 || inner.Attachments[0].GetBlobRef() == "" {
		return fmt.Errorf("附件元数据不完整")
	}
	att := inner.Attachments[0]
	gotSum, err := fileSHA256(att.GetBlobRef())
	if err != nil {
		return fmt.Errorf("计算落盘摘要: %w", err)
	}
	if string(gotSum) != string(sum) {
		return fmt.Errorf("落盘摘要不一致")
	}
	fmt.Printf("FILE_SHA256 %x\n", gotSum)
	fmt.Printf("FILE_CHUNKS %d\n", (att.GetSize()+dm.DefaultChunkSize-1)/dm.DefaultChunkSize)

	sendStat.mu.Lock()
	sendEvents, sendFinal, sendMaxGap := sendStat.events, sendStat.final, sendStat.maxGap
	sendStat.mu.Unlock()
	recvStat.mu.Lock()
	recvEvents, recvFinal, recvMaxGap := recvStat.events, recvStat.final, recvStat.maxGap
	recvStat.mu.Unlock()

	if !sendFinal || !recvFinal {
		return fmt.Errorf("未收到最终完成进度事件")
	}
	// 200ms 节流：事件数不得超过「耗时/200ms + 2」，且相邻事件间隔不超过 2s。
	maxEvents := int(elapsed/(200*time.Millisecond)) + 3
	if sendEvents > maxEvents || recvEvents > maxEvents {
		return fmt.Errorf("进度事件未节流: send=%d recv=%d 上限=%d", sendEvents, recvEvents, maxEvents)
	}
	if sendMaxGap > 2*time.Second || recvMaxGap > 2*time.Second {
		return fmt.Errorf("进度事件间隔异常: send=%s recv=%s", sendMaxGap, recvMaxGap)
	}
	fmt.Printf("FILE_PROGRESS send_events=%d recv_events=%d max_gap_send=%s max_gap_recv=%s\n",
		sendEvents, recvEvents, sendMaxGap.Round(time.Millisecond), recvMaxGap.Round(time.Millisecond))
	fmt.Println("FILE_PROGRESS_THROTTLED true")

	fmt.Println("RESULT PASS")
	return nil
}

func newNode(name, dir, listen string, onProgress func(dm.TransferProgress)) (*node, error) {
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
		UserAgent:        "nexmem-filetest/0.1.0",
		EnableNATService: true,
		EnableHolePunch:  true,
	})
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("%s 启动 host: %w", name, err)
	}
	dao := store.NewDAO(db)
	svc, err := dm.New(dm.Options{
		Host:       h,
		DeviceKey:  priv,
		DAO:        dao,
		Account:    acc,
		InboxDir:   filepath.Join(dir, "inbox"),
		OnProgress: onProgress,
	})
	if err != nil {
		h.Close()
		db.Close()
		return nil, fmt.Errorf("%s 创建单聊服务: %w", name, err)
	}
	return &node{name: name, db: db, dao: dao, account: acc, host: h, svc: svc}, nil
}

// writeTestFile 用固定随机块快速生成指定大小的测试文件。
func writeTestFile(path string, size int64) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("创建测试文件: %w", err)
	}
	defer f.Close()
	block := make([]byte, 4<<20)
	if _, err := rand.Read(block); err != nil {
		return fmt.Errorf("生成随机块: %w", err)
	}
	var written int64
	for written < size {
		n := int64(len(block))
		if size-written < n {
			n = size - written
		}
		if _, err := f.Write(block[:n]); err != nil {
			return fmt.Errorf("写入测试文件: %w", err)
		}
		written += n
	}
	return nil
}

func fileSHA256(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
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
