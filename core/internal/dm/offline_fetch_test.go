package dm

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
)

// fakeInbox 是接收方对象存储的替身；实现 OfflineObjectDeleter 以支持 C-02 测试。
type fakeInbox struct {
	mu       sync.Mutex
	objects  map[string]fakeInboxObject
	deleted  []string
	delFail  bool
}

// Delete 实现 OfflineObjectDeleter。
func (f *fakeInbox) Delete(_ context.Context, key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.delFail {
		return errors.New("模拟删除失败")
	}
	delete(f.objects, key)
	f.deleted = append(f.deleted, key)
	return nil
}

func (f *fakeInbox) deletedCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.deleted)
}

type fakeInboxObject struct {
	data     []byte
	modified time.Time
	etag     string
}

func newFakeInbox() *fakeInbox {
	return &fakeInbox{objects: make(map[string]fakeInboxObject)}
}

func (f *fakeInbox) Put(key string, data []byte, modified time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.objects[key] = fakeInboxObject{
		data:     append([]byte(nil), data...),
		modified: modified,
		etag:     fmt.Sprintf("etag-%d", len(f.objects)),
	}
}

func (f *fakeInbox) List(_ context.Context, prefix string) ([]blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	keys := make([]string, 0, len(f.objects))
	for k := range f.objects {
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	out := make([]blob.ObjectInfo, 0, len(keys))
	for _, k := range keys {
		obj := f.objects[k]
		out = append(out, blob.ObjectInfo{
			Key:          k,
			Size:         int64(len(obj.data)),
			ETag:         obj.etag,
			LastModified: obj.modified,
		})
	}
	return out, nil
}

func (f *fakeInbox) Get(_ context.Context, key string) ([]byte, blob.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	obj, ok := f.objects[key]
	if !ok {
		return nil, blob.ObjectInfo{}, blob.ErrNotFound
	}
	return append([]byte(nil), obj.data...), blob.ObjectInfo{
		Key:          key,
		Size:         int64(len(obj.data)),
		ETag:         obj.etag,
		LastModified: obj.modified,
	}, nil
}

// inboxDirectory 为指定账号签发指向其收件箱前缀的票据。
type inboxDirectory struct {
	mu      sync.Mutex
	profile *nexmemv1.PublicProfile
	issued  int
}

func (d *inboxDirectory) GetProfile(context.Context, []byte) (*nexmemv1.PublicProfile, error) {
	return d.profile, nil
}

func (d *inboxDirectory) TakeTickets(_ context.Context, accountPub []byte, take int) ([]blob.Ticket, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if take <= 0 {
		take = 1
	}
	out := make([]blob.Ticket, 0, take)
	for i := 0; i < take; i++ {
		d.issued++
		key := fmt.Sprintf("%s%04d.msg", blob.InboxPrefix(accountPub), d.issued)
		out = append(out, blob.Ticket{
			Key:       key,
			URL:       "https://s3.example.com/" + key + "?X-Amz-Signature=sig",
			ExpiresAt: time.Now().Add(time.Hour).Unix(),
		})
	}
	return out, nil
}

// inboxUploader 把票据上传写入 fakeInbox。
type inboxUploader struct {
	inbox *fakeInbox
}

func (u *inboxUploader) PutPresigned(_ context.Context, rawURL string, data []byte) error {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return err
	}
	key := strings.TrimPrefix(parsed.Path, "/")
	u.inbox.Put(key, data, time.Now())
	return nil
}

// buildOfflinePayload 构造一条合法的离线消息对象。
func buildOfflinePayload(t *testing.T, sender, recv *identity.Account, msgID, text string, ts time.Time, ttl uint32) []byte {
	t.Helper()
	inner, err := proto.Marshal(&nexmemv1.InnerMessage{Text: text})
	if err != nil {
		t.Fatalf("序列化正文: %v", err)
	}
	aad := OfflineAAD(msgID, sender.Pub(), recv.Pub())
	sealed, err := crypto.SealMessage(recv.XPub(), inner, aad)
	if err != nil {
		t.Fatalf("加密离线消息: %v", err)
	}
	msg := &nexmemv1.OfflineMessage{
		MsgUuid:         msgID,
		Timestamp:       ts.UnixMilli(),
		SenderAccount:   sender.Pub(),
		ReceiverAccount: recv.Pub(),
		ConversationId:  []byte(ConversationID(sender.Pub(), recv.Pub())),
		EncryptedKey:    sealed.EncryptedKey,
		Nonce:           sealed.Nonce,
		Ciphertext:      sealed.Ciphertext,
		KeyAlg:          crypto.EnvelopeKeyAlg,
		ContentType:     nexmemv1.ContentType_CONTENT_TYPE_TEXT,
		TtlHours:        ttl,
	}
	if err := sender.SignOfflineMessage(msg); err != nil {
		t.Fatalf("签名离线消息: %v", err)
	}
	raw, err := proto.Marshal(msg)
	if err != nil {
		t.Fatalf("序列化离线消息: %v", err)
	}
	return raw
}

// TestOfflineFetchEndToEnd 校验发送端离线投递后，接收端拉取、解密、入库、推进游标，
// 且重复拉取不重复入库。
func TestOfflineFetchEndToEnd(t *testing.T) {
	inbox := newFakeInbox()
	recv := newTestNode(t, "R", func(o *Options) {
		o.Inbox = inbox
		o.DisableAutoFetch = true
	})
	dirSvc := &inboxDirectory{profile: offlineProfile(t, recv.account, true)}
	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = &inboxUploader{inbox: inbox}
		o.DisableAutoResume = true
	})

	ctx := context.Background()
	const text = "离线也能收到"
	msgID, err := sender.svc.SendText(ctx, Target{AccountPub: recv.account.Pub()}, text, "")
	if err != nil {
		t.Fatalf("离线投递应成功，实际 %v", err)
	}

	rep, err := recv.svc.FetchOffline(ctx)
	if err != nil {
		t.Fatalf("拉取离线消息: %v", err)
	}
	if rep.Imported != 1 || rep.Failed != 0 {
		t.Fatalf("应导入 1 条、失败 0 条，实际 %+v", rep)
	}

	convID := ConversationID(recv.account.Pub(), sender.account.Pub())
	if n, err := recv.dao.CountMessages(ctx, convID); err != nil || n != 1 {
		t.Fatalf("应入库 1 条消息，实际 %d (err=%v)", n, err)
	}
	conv, err := recv.dao.GetConversation(ctx, convID)
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if conv.Unread != 1 {
		t.Fatalf("未读应为 1，实际 %d", conv.Unread)
	}

	msgs, err := recv.dao.ListMessages(ctx, convID, nil, 10)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("读取消息失败: n=%d err=%v", len(msgs), err)
	}
	if msgs[0].MsgUUID != msgID || msgs[0].State != store.MessageStateReceived || msgs[0].Direction != store.DirectionIn {
		t.Fatalf("入库消息字段不符: %+v", msgs[0])
	}
	var inner nexmemv1.InnerMessage
	if err := proto.Unmarshal(msgs[0].BodyEnc, &inner); err != nil {
		t.Fatalf("解析正文: %v", err)
	}
	if inner.GetText() != text {
		t.Fatalf("正文 %q，期望 %q", inner.GetText(), text)
	}

	cur, err := recv.dao.GetCursor(ctx, OfflineScope(recv.account.Pub()))
	if err != nil || cur.SeenAt == 0 {
		t.Fatalf("游标未推进: %+v err=%v", cur, err)
	}

	rep2, err := recv.svc.FetchOffline(ctx)
	if err != nil {
		t.Fatalf("二次拉取: %v", err)
	}
	if rep2.Imported != 0 {
		t.Fatalf("重复拉取不应再次入库，实际 %+v", rep2)
	}
	if n, _ := recv.dao.CountMessages(ctx, convID); n != 1 {
		t.Fatalf("重复拉取后仍应只有 1 条消息，实际 %d", n)
	}
	if conv, _ := recv.dao.GetConversation(ctx, convID); conv.Unread != 1 {
		t.Fatalf("重复拉取不应增加未读，实际 %d", conv.Unread)
	}
}

// TestOfflineFetchDeleteAfterRead 校验 C-02：deleteAfterRead 开启时入库成功后删除对象，
// 关闭时（默认 lifecycle 模式）保留对象；删除失败不阻断入库与游标推进。
func TestOfflineFetchDeleteAfterRead(t *testing.T) {
	for _, tc := range []struct {
		name       string
		deleteFlag bool
		delFail    bool
		wantDelete int
	}{
		{name: "默认生命周期模式保留对象", deleteFlag: false, wantDelete: 0},
		{name: "显式删除模式删除已读对象", deleteFlag: true, wantDelete: 1},
		{name: "删除失败不阻断入库", deleteFlag: true, delFail: true, wantDelete: 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			inbox := newFakeInbox()
			inbox.delFail = tc.delFail
			recv := newTestNode(t, "R", func(o *Options) {
				o.Inbox = inbox
				o.DeleteAfterRead = tc.deleteFlag
				o.DisableAutoFetch = true
			})
			dirSvc := &inboxDirectory{profile: offlineProfile(t, recv.account, true)}
			sender := newTestNode(t, "A", func(o *Options) {
				o.Directory = dirSvc
				o.Uploader = &inboxUploader{inbox: inbox}
				o.DisableAutoResume = true
			})
			ctx := context.Background()
			if _, err := sender.svc.SendText(ctx,
				Target{AccountPub: recv.account.Pub()}, "已读清理", ""); err != nil {
				t.Fatalf("离线投递: %v", err)
			}

			rep, err := recv.svc.FetchOffline(ctx)
			if err != nil {
				t.Fatalf("拉取: %v", err)
			}
			// 无论删除是否成功，消息都必须正常入库。
			if rep.Imported != 1 {
				t.Fatalf("应导入 1 条，实际 %+v", rep)
			}
			if got := inbox.deletedCount(); got != tc.wantDelete {
				t.Fatalf("删除对象数 = %d，期望 %d (rep=%+v)", got, tc.wantDelete, rep)
			}
			if rep.Deleted != tc.wantDelete {
				t.Fatalf("rep.Deleted = %d，期望 %d", rep.Deleted, tc.wantDelete)
			}
			convID := ConversationID(recv.account.Pub(), sender.account.Pub())
			if n, _ := recv.dao.CountMessages(ctx, convID); n != 1 {
				t.Fatalf("入库消息数 = %d，期望 1", n)
			}
			cur, _ := recv.dao.GetCursor(ctx, OfflineScope(recv.account.Pub()))
			if cur.SeenAt == 0 {
				t.Fatal("游标未推进")
			}
		})
	}
}

// TestOfflineFetchOnStartup 校验接收方上线后 5s 内可见已上传的离线消息。
func TestOfflineFetchOnStartup(t *testing.T) {
	senderAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成发送方账号: %v", err)
	}
	recvAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}

	inbox := newFakeInbox()
	const msgID = "0192a000-0000-7000-8000-000000000001"
	payload := buildOfflinePayload(t, senderAcc, recvAcc, msgID, "上线即收", time.Now(), 24)
	inbox.Put(blob.InboxPrefix(recvAcc.Pub())+"0001.msg", payload, time.Now())

	recv := newTestNode(t, "R", func(o *Options) {
		o.Account = recvAcc
		o.Inbox = inbox
		o.FetchInterval = 50 * time.Millisecond
	})

	convID := ConversationID(recvAcc.Pub(), senderAcc.Pub())
	deadline := time.Now().Add(5 * time.Second)
	for {
		if n, err := recv.dao.CountMessages(context.Background(), convID); err == nil && n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("上线 5s 内未看到离线消息")
		}
		time.Sleep(20 * time.Millisecond)
	}

	msgs, err := recv.dao.ListMessages(context.Background(), convID, nil, 10)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("读取消息失败: n=%d err=%v", len(msgs), err)
	}
	if msgs[0].MsgUUID != msgID {
		t.Fatalf("消息 UUID %q，期望 %q", msgs[0].MsgUUID, msgID)
	}
}

// TestOfflineFetchSkipsInvalid 校验篡改、串号、过期与超限对象被丢弃且不入库。
func TestOfflineFetchSkipsInvalid(t *testing.T) {
	senderAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成发送方账号: %v", err)
	}
	recvAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	otherAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成第三方账号: %v", err)
	}

	inbox := newFakeInbox()
	prefix := blob.InboxPrefix(recvAcc.Pub())
	now := time.Now()

	// 1. 密文被篡改。
	tampered := buildOfflinePayload(t, senderAcc, recvAcc, "m-tampered", "x", now, 24)
	off := &nexmemv1.OfflineMessage{}
	if err := proto.Unmarshal(tampered, off); err != nil {
		t.Fatalf("解析离线消息: %v", err)
	}
	off.Ciphertext[0] ^= 0xff
	tampered, _ = proto.Marshal(off)
	inbox.Put(prefix+"t1.msg", tampered, now)

	// 2. 接收方不是本账号（签名同时失效）。
	misdirected := buildOfflinePayload(t, senderAcc, recvAcc, "m-misdirected", "x", now, 24)
	off = &nexmemv1.OfflineMessage{}
	_ = proto.Unmarshal(misdirected, off)
	off.ReceiverAccount = otherAcc.Pub()
	misdirected, _ = proto.Marshal(off)
	inbox.Put(prefix+"t2.msg", misdirected, now)

	// 3. TTL 已过期。
	expired := buildOfflinePayload(t, senderAcc, recvAcc, "m-expired", "x", now.Add(-48*time.Hour), 24)
	inbox.Put(prefix+"t3.msg", expired, now)

	// 4. 超出单对象上限。
	oversize := make([]byte, MaxOfflineObjectSize+1)
	inbox.Put(prefix+"t4.msg", oversize, now)

	recv := newTestNode(t, "R", func(o *Options) {
		o.Account = recvAcc
		o.Inbox = inbox
		o.DisableAutoFetch = true
	})

	rep, err := recv.svc.FetchOffline(context.Background())
	if err != nil {
		t.Fatalf("拉取离线消息: %v", err)
	}
	if rep.Imported != 0 || rep.Skipped != 4 {
		t.Fatalf("应全部丢弃（导入 0、跳过 4），实际 %+v", rep)
	}
	convID := ConversationID(recvAcc.Pub(), senderAcc.Pub())
	if n, _ := recv.dao.CountMessages(context.Background(), convID); n != 0 {
		t.Fatalf("非法对象不应入库，实际 %d", n)
	}
	if cur, err := recv.dao.GetCursor(context.Background(), OfflineScope(recvAcc.Pub())); err != nil || cur.SeenAt == 0 {
		t.Fatalf("游标未推进: %+v err=%v", cur, err)
	}
}

// TestOfflineFetchNotConfigured 校验未注入收件箱时返回明确错误。
func TestOfflineFetchNotConfigured(t *testing.T) {
	n := newTestNode(t, "R")
	if _, err := n.svc.FetchOffline(context.Background()); !errors.Is(err, ErrOfflineFetchDisabled) {
		t.Fatalf("应返回 ErrOfflineFetchDisabled，实际 %v", err)
	}
}
