package dm

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	libp2pcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/wire"
)

// TestSendSignalRelaysToPeer 覆盖 RTC 信令在线透传与事件回调。
func TestSendSignalRelaysToPeer(t *testing.T) {
	a := newTestNode(t, "a")
	got := make(chan RTCSignalEvent, 1)
	b := newTestNode(t, "b", func(o *Options) {
		o.OnRTCSignal = func(ev RTCSignalEvent) { got <- ev }
	})

	target := Target{PeerID: b.host.ID(), Addrs: b.host.Addrs(), AccountPub: b.account.Pub()}
	payload := []byte(`{"type":"offer","sdp":"v=0","mid":"audio"}`)
	if err := a.svc.SendSignal(context.Background(), target, payload); err != nil {
		t.Fatalf("发送 RTC 信令: %v", err)
	}

	select {
	case ev := <-got:
		if !bytes.Equal(ev.Payload, payload) {
			t.Fatalf("载荷不一致: %q", ev.Payload)
		}
		if !bytes.Equal(ev.PeerAccount, a.account.Pub()) {
			t.Fatal("事件中的对端账号不是发送方")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("未收到 RTC 信令事件")
	}
}

// TestSendSignalRejectsInvalidInput 覆盖空载荷、超限、自发与非法账号。
func TestSendSignalRejectsInvalidInput(t *testing.T) {
	a := newTestNode(t, "a")
	ctx := context.Background()
	target := Target{AccountPub: a.account.Pub()}

	if err := a.svc.SendSignal(ctx, target, nil); !errors.Is(err, ErrEmptySignal) {
		t.Fatalf("空载荷应返回 ErrEmptySignal，实际 %v", err)
	}
	oversize := make([]byte, MaxRTCSignalSize+1)
	if err := a.svc.SendSignal(ctx, target, oversize); !errors.Is(err, ErrSignalTooLarge) {
		t.Fatalf("超限载荷应返回 ErrSignalTooLarge，实际 %v", err)
	}
	if err := a.svc.SendSignal(ctx, target, []byte("x")); !errors.Is(err, ErrSelfSend) {
		t.Fatalf("自发应返回 ErrSelfSend，实际 %v", err)
	}
	if err := a.svc.SendSignal(ctx, Target{AccountPub: []byte("bad")}, []byte("x")); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("非法账号应返回 ErrInvalidTarget，实际 %v", err)
	}
	peer := newTestNode(t, "peer")
	if err := a.svc.SendSignal(ctx, Target{AccountPub: peer.account.Pub()}, []byte("x")); !errors.Is(err, ErrPeerUnreached) {
		t.Fatalf("缺少 PeerID 应返回 ErrPeerUnreached，实际 %v", err)
	}
}

// TestHandleRTCStreamRejectsForgedFrame 覆盖签名不符时应丢弃且不回调。
func TestHandleRTCStreamRejectsForgedFrame(t *testing.T) {
	a := newTestNode(t, "a")
	got := make(chan struct{}, 1)
	b := newTestNode(t, "b", func(o *Options) {
		o.OnRTCSignal = func(RTCSignalEvent) { got <- struct{}{} }
	})

	ctx := context.Background()
	if err := a.svc.connect(ctx, Target{PeerID: b.host.ID(), Addrs: b.host.Addrs()}); err != nil {
		t.Fatalf("连接对端: %v", err)
	}
	wrongKey, _, err := libp2pcrypto.GenerateKeyPair(libp2pcrypto.Ed25519, -1)
	if err != nil {
		t.Fatalf("生成伪造密钥: %v", err)
	}
	body, err := proto.Marshal(&nexmemv1.RtcSignal{
		SenderAccount:   a.account.Pub(),
		ReceiverAccount: b.account.Pub(),
		Payload:         []byte("forged"),
	})
	if err != nil {
		t.Fatalf("序列化伪造信令: %v", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_RTC_SIGNAL,
		Payload: body,
	}
	if err := wire.SignFrame(wrongKey, frame); err != nil {
		t.Fatalf("伪造签名: %v", err)
	}
	st, err := a.host.NewStream(ctx, b.host.ID(), wire.PIDRTC)
	if err != nil {
		t.Fatalf("打开 RTC 流: %v", err)
	}
	_ = st.SetDeadline(time.Now().Add(2 * time.Second))
	_ = wire.WriteFrame(st, frame)
	// 接收端验签失败直接断开，不保证回 ACK，读取结果忽略。
	_, _ = wire.ReadFrame(st)
	st.Close()

	select {
	case <-got:
		t.Fatal("伪造签名不应触发 RTC 信令回调")
	case <-time.After(500 * time.Millisecond):
	}
}
