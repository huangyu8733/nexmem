// nexmem-offlinetest 是 P3-06 的内核 CLI 验收程序：
// 在进程内启动索引服务、模拟对象存储与一台发送方设备，接收方完全离线（不启动
// host），验证发送方自动领取票据、加密上传、置为 sent 并触发离线投递事件。
package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"sync"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/directory"
	"github.com/nexmem/core/internal/dirsig"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
	dirserver "github.com/nexmem/core/server/directory"
)

var (
	count   = flag.Int("count", 3, "离线发送的消息条数")
	dir     = flag.String("dir", "", "数据目录（留空则使用临时目录，结束后删除）")
	timeout = flag.Duration("timeout", 2*time.Minute, "整体超时")
)

// objectStore 是内存版的 presigned PUT 目标，只记录上传内容。
type objectStore struct {
	mu      sync.Mutex
	objects map[string][]byte
}

func (o *objectStore) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		o.mu.Lock()
		o.objects[r.URL.Path] = body
		o.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})
}

func (o *objectStore) all() [][]byte {
	o.mu.Lock()
	defer o.mu.Unlock()
	keys := make([]string, 0, len(o.objects))
	for k := range o.objects {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([][]byte, 0, len(keys))
	for _, k := range keys {
		out = append(out, o.objects[k])
	}
	return out
}

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	root := *dir
	if root == "" {
		tmp, err := os.MkdirTemp("", "nexmem-offlinetest-*")
		if err != nil {
			log.Fatalf("创建临时目录失败: %v", err)
		}
		root = tmp
		defer os.RemoveAll(tmp)
	}

	runCtx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
	if err := run(runCtx, root); err != nil {
		fmt.Printf("RESULT FAIL: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, root string) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return fmt.Errorf("创建数据目录: %w", err)
	}

	// 1. 索引服务 + 内存对象存储。
	srv, err := dirserver.New(filepath.Join(root, "directory.db"))
	if err != nil {
		return fmt.Errorf("启动索引服务: %w", err)
	}
	defer srv.Close()
	dirHTTP := httptest.NewServer(srv.Handler())
	defer dirHTTP.Close()

	objects := &objectStore{objects: make(map[string][]byte)}
	objHTTP := httptest.NewServer(objects.handler())
	defer objHTTP.Close()

	// 2. 接收方账号与公开档案（离线存储已开启）。
	recv, err := identity.GenerateAccount()
	if err != nil {
		return fmt.Errorf("生成接收方账号: %w", err)
	}
	profile := &nexmemv1.PublicProfile{OfflineEnabled: true, UpdatedAt: time.Now().Unix()}
	if err := recv.SignProfile(profile); err != nil {
		return fmt.Errorf("签发公开档案: %w", err)
	}
	rawProfile, err := proto.Marshal(profile)
	if err != nil {
		return err
	}
	if err := httpPut(recv, dirHTTP.URL+"/v1/profile", "application/x-protobuf", rawProfile); err != nil {
		return fmt.Errorf("上传公开档案: %w", err)
	}

	// 3. 接收方交存票据（presigned URL 指向内存对象存储）。
	presign := func(key string, _ time.Duration) (string, error) {
		return objHTTP.URL + "/" + key + "?X-Amz-Signature=fake", nil
	}
	issuer, err := blob.NewTicketIssuer(presignerFunc(presign), 24*time.Hour)
	if err != nil {
		return fmt.Errorf("创建票据生成器: %w", err)
	}
	batch, err := issuer.IssueBatch(recv.Pub(), "device-offline", blob.TicketBatchSize)
	if err != nil {
		return fmt.Errorf("生成票据: %w", err)
	}
	rawBatch, err := json.Marshal(batch)
	if err != nil {
		return err
	}
	ticketURL := dirHTTP.URL + "/v1/inbox/" + directory.URI(recv.Pub()) + "/tickets"
	if err := httpPost(recv, ticketURL, rawBatch); err != nil {
		return fmt.Errorf("交存票据: %w", err)
	}

	// 4. 发送方设备。
	var offlineEvents int
	sender, err := newSender(root, dirHTTP.URL, func(ev dm.DeliveryEvent) {
		if ev.Offline {
			offlineEvents++
		}
	})
	if err != nil {
		return err
	}
	defer sender.close()

	convID := dm.ConversationID(sender.account.Pub(), recv.Pub())
	for i := 0; i < *count; i++ {
		text := fmt.Sprintf("offline-%02d", i)
		if _, err := sender.svc.SendText(ctx, dm.Target{AccountPub: recv.Pub()}, text, ""); err != nil {
			return fmt.Errorf("发送第 %d 条离线消息: %w", i, err)
		}
	}

	// 5. 校验发送侧状态。
	if n, err := sender.dao.CountOutbox(ctx); err != nil || n != 0 {
		return fmt.Errorf("离线投递后离队队列应为空，实际 %d (err=%v)", n, err)
	}
	if n, err := sender.dao.CountMessages(ctx, convID); err != nil || n != *count {
		return fmt.Errorf("本地消息 %d 条，期望 %d (err=%v)", n, *count, err)
	}
	fmt.Printf("OFFLINE_SENT %d\n", *count)

	// 6. 校验上传对象可被接收方解密并验签。
	uploads := objects.all()
	if len(uploads) != *count {
		return fmt.Errorf("上传对象 %d 个，期望 %d", len(uploads), *count)
	}
	type received struct {
		ts   int64
		text string
	}
	items := make([]received, 0, len(uploads))
	for i, raw := range uploads {
		var msg nexmemv1.OfflineMessage
		if err := proto.Unmarshal(raw, &msg); err != nil {
			return fmt.Errorf("第 %d 个对象解析失败: %w", i, err)
		}
		if err := identity.VerifyOfflineMessage(&msg); err != nil {
			return fmt.Errorf("第 %d 个对象验签失败: %w", i, err)
		}
		if !bytes.Equal(msg.ReceiverAccount, recv.Pub()) {
			return fmt.Errorf("第 %d 个对象接收方不匹配", i)
		}
		plain, err := crypto.OpenMessage(recv.XPriv(), &crypto.SealedMessage{
			KeyAlg:       msg.KeyAlg,
			EncryptedKey: msg.EncryptedKey,
			Nonce:        msg.Nonce,
			Ciphertext:   msg.Ciphertext,
		}, dm.OfflineAAD(msg.MsgUuid, msg.SenderAccount, msg.ReceiverAccount))
		if err != nil {
			return fmt.Errorf("第 %d 个对象解密失败: %w", i, err)
		}
		var inner nexmemv1.InnerMessage
		if err := proto.Unmarshal(plain, &inner); err != nil {
			return fmt.Errorf("第 %d 个对象正文解析失败: %w", i, err)
		}
		items = append(items, received{ts: msg.Timestamp, text: inner.GetText()})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ts < items[j].ts })
	for i, item := range items {
		if want := fmt.Sprintf("offline-%02d", i); item.text != want {
			return fmt.Errorf("第 %d 条解密正文 %q，期望 %q", i, item.text, want)
		}
	}
	fmt.Printf("OFFLINE_UPLOADED %d\n", len(uploads))
	fmt.Printf("OFFLINE_DECRYPT %d/%d\n", len(items), *count)

	// 7. 校验消息状态与投递事件。
	msgs, err := sender.dao.ListMessages(ctx, convID, nil, *count)
	if err != nil || len(msgs) != *count {
		return fmt.Errorf("读取本地消息失败: %v", err)
	}
	for _, m := range msgs {
		if m.State != store.MessageStateSent {
			return fmt.Errorf("消息 %s 状态为 %d，期望 sent", m.MsgUUID, m.State)
		}
	}
	fmt.Println("OFFLINE_STATE sent")
	fmt.Println("OFFLINE_OUTBOX 0")
	if offlineEvents != *count {
		return fmt.Errorf("离线投递事件 %d 次，期望 %d", offlineEvents, *count)
	}
	fmt.Printf("OFFLINE_EVENTS %d\n", offlineEvents)
	fmt.Println("RESULT PASS")
	return nil
}

type presignerFunc func(string, time.Duration) (string, error)

func (f presignerFunc) PresignPut(key string, ttl time.Duration) (string, error) { return f(key, ttl) }

type sender struct {
	db      *sql.DB
	dao     *store.DAO
	account *identity.Account
	host    host.Host
	svc     *dm.Service
}

func (s *sender) close() {
	if s.svc != nil {
		s.svc.Close()
	}
	if s.host != nil {
		_ = s.host.Close()
	}
	if s.db != nil {
		_ = s.db.Close()
	}
}

func newSender(root, dirURL string, onDelivery func(dm.DeliveryEvent)) (*sender, error) {
	dirPath := filepath.Join(root, "sender")
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		return nil, err
	}
	db, err := store.Open(filepath.Join(dirPath, "nexmem.db"))
	if err != nil {
		return nil, err
	}
	if err := store.Migrate(context.Background(), db); err != nil {
		db.Close()
		return nil, err
	}
	acc, err := identity.LoadOrCreateAccount(filepath.Join(dirPath, "account.json"))
	if err != nil {
		db.Close()
		return nil, err
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(dirPath, "device.key"))
	if err != nil {
		db.Close()
		return nil, err
	}
	h, err := netnode.NewHost(context.Background(), netnode.Config{
		PrivateKey: priv,
		Listen:     []string{"/ip4/127.0.0.1/tcp/0"},
		UserAgent:  "nexmem-offlinetest/0.1.0",
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	client, err := directory.New(directory.Config{BaseURL: dirURL, Signer: acc})
	if err != nil {
		h.Close()
		db.Close()
		return nil, err
	}
	dao := store.NewDAO(db)
	svc, err := dm.New(dm.Options{
		Host:      h,
		DeviceKey: priv,
		DAO:       dao,
		Account:   acc,
		Directory: client,
		Uploader: dm.UploaderFunc(func(ctx context.Context, rawURL string, data []byte) error {
			return blob.PutPresigned(ctx, http.DefaultClient, rawURL, data)
		}),
		OnDelivery: onDelivery,
	})
	if err != nil {
		h.Close()
		db.Close()
		return nil, err
	}
	return &sender{db: db, dao: dao, account: acc, host: h, svc: svc}, nil
}

// httpPut 上传公开档案，并按索引服务规范签名。
func httpPut(signer dirsig.Signer, rawURL, contentType string, body []byte) error {
	req, err := http.NewRequest(http.MethodPut, rawURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", contentType)
	signRequest(req, signer, body)
	return doRequest(req)
}

// httpPost 交存票据，并按索引服务规范签名。
func httpPost(signer dirsig.Signer, rawURL string, body []byte) error {
	req, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	signRequest(req, signer, body)
	return doRequest(req)
}

func signRequest(req *http.Request, signer dirsig.Signer, body []byte) {
	for k, v := range dirsig.Headers(signer, req.Method, req.URL.RequestURI(), time.Now().Unix(), body) {
		req.Header.Set(k, v)
	}
}

func doRequest(req *http.Request) error {
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	return fmt.Errorf("HTTP %d: %s", resp.StatusCode, bytes.TrimSpace(raw))
}
