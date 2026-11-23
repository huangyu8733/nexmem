package dm

import (
	"bytes"
	"context"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/internal/identity"
)

// fakeWaker 记录唤醒推送调用，便于断言触发时机与节流。
type fakeWaker struct {
	mu       sync.Mutex
	accounts [][]byte
	ch       chan []byte
}

func newFakeWaker() *fakeWaker {
	return &fakeWaker{ch: make(chan []byte, 8)}
}

func (w *fakeWaker) Wake(_ context.Context, accountPub []byte) (bool, error) {
	cp := append([]byte(nil), accountPub...)
	w.mu.Lock()
	w.accounts = append(w.accounts, cp)
	w.mu.Unlock()
	select {
	case w.ch <- cp:
	default:
	}
	return true, nil
}

func (w *fakeWaker) count() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.accounts)
}

// TestOfflineSendTriggersWake 校验离线投递成功后按对端触发一次唤醒推送，
// 且短时间内重复发送不会重复唤醒（节流），推送不进入消息内容。
func TestOfflineSendTriggersWake(t *testing.T) {
	recv, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	dirSvc := &fakeDirectory{profile: offlineProfile(t, recv, true)}
	dirSvc.addTickets(3)
	up := &fakeUploader{}
	waker := newFakeWaker()

	sender := newTestNode(t, "A", func(o *Options) {
		o.Directory = dirSvc
		o.Uploader = up
		o.Waker = waker
	})

	ctx := context.Background()
	if _, err := sender.svc.SendText(ctx, Target{AccountPub: recv.Pub()}, "第一条", ""); err != nil {
		t.Fatalf("离线投递应成功: %v", err)
	}
	select {
	case got := <-waker.ch:
		if !bytes.Equal(got, recv.Pub()) {
			t.Fatalf("唤醒账号不匹配: %x", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("离线投递成功后应触发唤醒推送")
	}

	// 节流窗口内再次发送不应重复唤醒。
	if _, err := sender.svc.SendText(ctx, Target{AccountPub: recv.Pub()}, "第二条", ""); err != nil {
		t.Fatalf("第二次离线投递应成功: %v", err)
	}
	time.Sleep(300 * time.Millisecond)
	if n := waker.count(); n != 1 {
		t.Fatalf("节流窗口内应只唤醒 1 次，实际 %d", n)
	}
}
