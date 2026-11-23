package dm

import (
	"context"
	"errors"
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

// fakeDirectory 是离线投递用的索引服务替身。
type fakeDirectory struct {
	mu         sync.Mutex
	profile    *nexmemv1.PublicProfile
	profileErr error
	tickets    []blob.Ticket
	takeErr    error
	takeCalls  int
}

func (f *fakeDirectory) GetProfile(context.Context, []byte) (*nexmemv1.PublicProfile, error) {
	if f.profileErr != nil {
		return nil, f.profileErr
	}
	return f.profile, nil
}

func (f *fakeDirectory) TakeTickets(_ context.Context, _ []byte, take int) ([]blob.Ticket, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.takeCalls++
	if f.takeErr != nil {
		return nil, f.takeErr
	}
	if take <= 0 {
		take = 1
	}
	if take > len(f.tickets) {
		take = len(f.tickets)
	}
	out := append([]blob.Ticket(nil), f.tickets[:take]...)
	f.tickets = f.tickets[take:]
	return out, nil
}

func (f *fakeDirectory) addTickets(n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := 0; i < n; i++ {
		f.tickets = append(f.tickets, blob.Ticket{
			Key:       "im_offline/x/inbox/t.msg",
			URL:       "https://s3.example.com/im_offline/x/inbox/t.msg?X-Amz-Signature=sig",
			ExpiresAt: time.Now().Add(time.Hour).Unix(),
		})
	}
}

// fakeUploader 记录上传载荷，可模拟前 n 次失败。
type fakeUploader struct {
	mu      sync.Mutex
	fail    int
	uploads [][]byte
	urls    []string
}

func (u *fakeUploader) PutPresigned(_ context.Context, rawURL string, data []byte) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.fail > 0 {
		u.fail--
		return errors.New("模拟上传失败")
	}
	u.urls = append(u.urls, rawURL)
	u.uploads = append(u.uploads, append([]byte(nil), data...))
	return nil
}

func (u *fakeUploader) count() int {
	u.mu.Lock()
	defer u.mu.Unlock()
	return len(u.uploads)
}

// offlineProfile 生成对端已开启离线存储的公开档案。
func offlineProfile(t *testing.T, recv *identity.Account, enabled bool) *nexmemv1.PublicProfile {
	t.Helper()
	p := &nexmemv1.PublicProfile{OfflineEnabled: enabled, UpdatedAt: time.Now().Unix()}
	if err := recv.SignProfile(p); err != nil {
		t.Fatalf("签发公开档案: %v", err)
	}
	return p
}

// TestSendTextOfflineFallback 是 P3-06 的核心验收用例：对端离线时自动领取票据、
// 加密上传，发送方置为 sent、不入离队队列，并触发离线投递成功事件。
func TestSendTextOfflineFallback(t *testing.T) {
	recv, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	dirSvc := &fakeDirectory{profile: offlineProfile(t, recv, true)}
	dirSvc.addTickets(2)
	up := &fakeUploader{}

	var events []DeliveryEvent
	var evMu sync.Mutex
	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = up
		o.OnDelivery = func(ev DeliveryEvent) {
			evMu.Lock()
			events = append(events, ev)
			evMu.Unlock()
		}
	})

	ctx := context.Background()
	const text = "离线也能收到"
	msgID, err := sender.svc.SendText(ctx, Target{AccountPub: recv.Pub()}, text, "")
	if err != nil {
		t.Fatalf("离线投递应成功，实际 %v", err)
	}
	if up.count() != 1 {
		t.Fatalf("应上传 1 个离线对象，实际 %d", up.count())
	}

	msg, err := sender.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取本地消息: %v", err)
	}
	if msg.State != store.MessageStateSent {
		t.Fatalf("消息状态应为 sent，实际 %d", msg.State)
	}
	if n, err := sender.dao.CountOutbox(ctx); err != nil || n != 0 {
		t.Fatalf("离线投递成功后离队队列应为空，实际 %d (err=%v)", n, err)
	}

	var offline nexmemv1.OfflineMessage
	if err := proto.Unmarshal(up.uploads[0], &offline); err != nil {
		t.Fatalf("解析离线消息: %v", err)
	}
	if offline.MsgUuid != msgID {
		t.Fatalf("离线消息 UUID %q 与本地 %q 不一致", offline.MsgUuid, msgID)
	}
	if offline.KeyAlg != crypto.EnvelopeKeyAlg {
		t.Fatalf("密钥算法 %d，期望 %d", offline.KeyAlg, crypto.EnvelopeKeyAlg)
	}
	if offline.TtlHours == 0 {
		t.Fatalf("离线消息缺少 TTL")
	}
	if err := identity.VerifyOfflineMessage(&offline); err != nil {
		t.Fatalf("离线消息验签失败: %v", err)
	}

	aad := OfflineAAD(msgID, sender.account.Pub(), recv.Pub())
	plain, err := crypto.OpenMessage(recv.XPriv(), &crypto.SealedMessage{
		KeyAlg:       offline.KeyAlg,
		EncryptedKey: offline.EncryptedKey,
		Nonce:        offline.Nonce,
		Ciphertext:   offline.Ciphertext,
	}, aad)
	if err != nil {
		t.Fatalf("接收方解密失败: %v", err)
	}
	var inner nexmemv1.InnerMessage
	if err := proto.Unmarshal(plain, &inner); err != nil {
		t.Fatalf("解析正文: %v", err)
	}
	if inner.GetText() != text {
		t.Fatalf("正文 %q，期望 %q", inner.GetText(), text)
	}

	evMu.Lock()
	defer evMu.Unlock()
	if len(events) != 1 || !events[0].Offline || events[0].State != store.MessageStateSent ||
		events[0].Reason != "" {
		t.Fatalf("应收到 1 次离线投递成功事件且无原因码，实际 %+v", events)
	}
}

// TestOfflineUploadRetry 校验上传失败后换一张票据重试。
func TestOfflineUploadRetry(t *testing.T) {
	recv, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	dirSvc := &fakeDirectory{profile: offlineProfile(t, recv, true)}
	dirSvc.addTickets(2)
	up := &fakeUploader{fail: 1}
	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = up
	})

	if _, err := sender.svc.SendText(context.Background(), Target{AccountPub: recv.Pub()}, "retry", ""); err != nil {
		t.Fatalf("换票重试应成功，实际 %v", err)
	}
	if up.count() != 1 {
		t.Fatalf("应最终成功上传 1 次，实际 %d", up.count())
	}
	if dirSvc.takeCalls != 2 {
		t.Fatalf("应领取 2 次票据，实际 %d", dirSvc.takeCalls)
	}
}

// TestOfflineDisabledFallback 校验对方未开启离线存储时回到离队队列并报错，
// 且失败事件带上原因码，供 UI 常驻「仅支持在线发送」提示（P3-09）。
func TestOfflineDisabledFallback(t *testing.T) {
	recv, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	dirSvc := &fakeDirectory{profile: offlineProfile(t, recv, false)}
	up := &fakeUploader{}
	var (
		evMu   sync.Mutex
		events []DeliveryEvent
	)
	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = up
		o.OnDelivery = func(ev DeliveryEvent) {
			evMu.Lock()
			events = append(events, ev)
			evMu.Unlock()
		}
	})

	msgID, err := sender.svc.SendText(context.Background(), Target{AccountPub: recv.Pub()}, "hi", "")
	if err == nil || !errors.Is(err, ErrOfflineDisabled) {
		t.Fatalf("应返回 ErrOfflineDisabled，实际 %v", err)
	}
	msg, gerr := sender.dao.GetMessage(context.Background(), msgID)
	if gerr != nil {
		t.Fatalf("读取消息: %v", gerr)
	}
	if msg.State != store.MessageStateFailed {
		t.Fatalf("消息状态应为 failed，实际 %d", msg.State)
	}
	if n, _ := sender.dao.CountOutbox(context.Background()); n != 1 {
		t.Fatalf("应写入 1 条离队队列，实际 %d", n)
	}
	if up.count() != 0 {
		t.Fatalf("未开启离线存储时不应上传，实际 %d", up.count())
	}

	evMu.Lock()
	defer evMu.Unlock()
	if len(events) != 1 || events[0].State != store.MessageStateFailed ||
		events[0].Reason != ReasonOfflineStorageDisabled {
		t.Fatalf("应上报 1 次带原因码的失败事件，实际 %+v", events)
	}
}

// TestOfflineTicketPoolEmpty 校验票据耗尽时明确报错并保留离队队列。
func TestOfflineTicketPoolEmpty(t *testing.T) {
	recv, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	dirSvc := &fakeDirectory{profile: offlineProfile(t, recv, true)}
	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = &fakeUploader{}
	})

	if _, err := sender.svc.SendText(context.Background(), Target{AccountPub: recv.Pub()}, "hi", ""); err == nil ||
		!errors.Is(err, ErrOfflineNoTickets) {
		t.Fatalf("应返回 ErrOfflineNoTickets，实际 %v", err)
	}
	if n, _ := sender.dao.CountOutbox(context.Background()); n != 1 {
		t.Fatalf("应写入 1 条离队队列，实际 %d", n)
	}
}

// TestResumeUsesOfflineDelivery 校验补发扫描在直连不可达时改走离线投递。
func TestResumeUsesOfflineDelivery(t *testing.T) {
	recv, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	dirSvc := &fakeDirectory{profile: offlineProfile(t, recv, true)}
	up := &fakeUploader{}
	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = up
		o.DisableAutoResume = true
		o.Resolver = PeerResolverFunc(func(context.Context, []byte) (Target, error) {
			// 只有账号没有 PeerID，直连必然失败。
			return Target{AccountPub: recv.Pub()}, nil
		})
	})

	ctx := context.Background()
	msgID, err := sender.svc.SendText(ctx, Target{AccountPub: recv.Pub()}, "queued", "")
	if err == nil {
		t.Fatalf("票据池为空时应返回错误")
	}
	if n, _ := sender.dao.CountOutbox(ctx); n != 1 {
		t.Fatalf("应写入 1 条离队队列，实际 %d", n)
	}

	dirSvc.addTickets(1)
	rep, err := sender.svc.ResumeOutbox(ctx)
	if err != nil {
		t.Fatalf("补发失败: %v", err)
	}
	if rep.Delivered != 1 || rep.Retained != 0 {
		t.Fatalf("补发结果应为 1 送达 0 保留，实际 %+v", rep)
	}
	if n, _ := sender.dao.CountOutbox(ctx); n != 0 {
		t.Fatalf("补发成功后离队队列应为空，实际 %d", n)
	}
	msg, err := sender.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取消息: %v", err)
	}
	if msg.State != store.MessageStateSent {
		t.Fatalf("补发后消息状态应为 sent，实际 %d", msg.State)
	}
}

// TestOfflineMetricsCallbacks 校验 P3 门禁的桶用量（对象数/字节数）与票据消耗
// 可经回调观测；上传失败计入失败数。
func TestOfflineMetricsCallbacks(t *testing.T) {
	recv, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	dirSvc := &fakeDirectory{profile: offlineProfile(t, recv, true)}
	dirSvc.addTickets(1)
	up := &fakeUploader{}

	var (
		ticketsTaken int
		uploads      int
		uploadBytes  int64
		failures     int
	)
	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = up
		o.OnTicketTake = func(n int) { ticketsTaken += n }
		o.OnOfflineUpload = func(bytes int64, ok bool) {
			if ok {
				uploads++
				uploadBytes += bytes
				return
			}
			failures++
		}
	})

	if _, err := sender.svc.SendText(context.Background(), Target{AccountPub: recv.Pub()}, "metrics", ""); err != nil {
		t.Fatalf("离线投递应成功，实际 %v", err)
	}
	if ticketsTaken != 1 {
		t.Fatalf("票据消耗应为 1，实际 %d", ticketsTaken)
	}
	if uploads != 1 || uploadBytes <= 0 || failures != 0 {
		t.Fatalf("桶用量观测错误: uploads=%d bytes=%d failures=%d", uploads, uploadBytes, failures)
	}

	// 上传持续失败时应计入失败数，且不再累加对象数。
	dirSvc.addTickets(2)
	up.fail = 2
	if _, err := sender.svc.SendText(context.Background(), Target{AccountPub: recv.Pub()}, "metrics-fail", ""); err == nil {
		t.Fatal("上传持续失败时应返回错误")
	}
	if uploads != 1 || failures != 1 {
		t.Fatalf("失败计数错误: uploads=%d failures=%d", uploads, failures)
	}
	if ticketsTaken != 3 {
		t.Fatalf("票据消耗应为 3，实际 %d", ticketsTaken)
	}
}
