package dm

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/store"
)

// progressRecorder 线程安全地收集进度回调。
type progressRecorder struct {
	mu     sync.Mutex
	events []TransferProgress
}

func (r *progressRecorder) add(p TransferProgress) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, p)
}

func (r *progressRecorder) snapshot() []TransferProgress {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]TransferProgress, len(r.events))
	copy(out, r.events)
	return out
}

func TestProgressEmitterThrottle(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	var got []TransferProgress
	e := newProgressEmitter(func(p TransferProgress) { got = append(got, p) }, DefaultProgressInterval)
	e.now = func() time.Time { return now }

	const total = int64(100)
	for i := int64(1); i <= 100; i++ {
		now = now.Add(10 * time.Millisecond)
		e.emit(TransferProgress{MsgUUID: "m", Done: i, Total: total})
	}

	if len(got) < 2 {
		t.Fatalf("应至少上报首末两次进度，实际 %d 次", len(got))
	}
	last := got[len(got)-1]
	if last.Done != total || last.Total != total {
		t.Fatalf("最后一次进度应为完成事件，实际 done=%d total=%d", last.Done, last.Total)
	}
	for i := 1; i < len(got); i++ {
		gap := time.Duration(got[i].Done-got[i-1].Done) * 10 * time.Millisecond
		if got[i].Done < total && gap < DefaultProgressInterval {
			t.Fatalf("第 %d 次进度间隔 %s 小于 %s", i, gap, DefaultProgressInterval)
		}
	}
	// 1s 内按 200ms 节流，事件数不应超过 6 次（含完成事件）。
	if len(got) > 7 {
		t.Fatalf("进度事件 %d 次，未被 200ms 节流", len(got))
	}
}

func TestSendFileRoundTrip(t *testing.T) {
	a := newTestNode(t, "A")
	b := newTestNode(t, "B")

	dir := t.TempDir()
	src := filepath.Join(dir, "payload.bin")
	data := make([]byte, 8<<20+123)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, data, 0o600); err != nil {
		t.Fatal(err)
	}

	var sent, recv progressRecorder
	// 直接替换回调，避免新增节点工厂参数。
	a.svc.onProgress = sent.add
	b.svc.onProgress = recv.add

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	target := Target{
		PeerID:     b.svc.host.ID(),
		Addrs:      b.svc.host.Addrs(),
		AccountPub: b.account.Pub(),
	}
	msgID, err := a.svc.SendFile(ctx, target, src, "application/octet-stream")
	if err != nil {
		t.Fatalf("发送文件失败: %v", err)
	}

	convID := ConversationID(a.account.Pub(), b.account.Pub())
	outMsg, err := a.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取发送方消息: %v", err)
	}
	if outMsg.State != store.MessageStateSent {
		t.Fatalf("发送方状态应为 sent，实际 %d", outMsg.State)
	}
	if outMsg.ContentType != int(nexmemv1.ContentType_CONTENT_TYPE_FILE) {
		t.Fatalf("发送方消息类型应为 file，实际 %d", outMsg.ContentType)
	}
	outInner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(outMsg.BodyEnc, outInner); err != nil {
		t.Fatalf("解析发送方附件: %v", err)
	}
	if got := outInner.Attachments[0].GetBlobRef(); got != src {
		t.Fatalf("发送方本机副本应记录绝对路径 %q，实际 %q", src, got)
	}
	wireMsg := &nexmemv1.DirectMessage{}
	if err := proto.Unmarshal(outMsg.Raw, wireMsg); err != nil {
		t.Fatalf("解析发送帧: %v", err)
	}
	wireInner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(wireMsg.GetInner(), wireInner); err != nil {
		t.Fatalf("解析上行附件: %v", err)
	}
	if ref := wireInner.Attachments[0].GetBlobRef(); ref != "" {
		t.Fatalf("上行帧不应携带本机路径，实际 %q", ref)
	}

	recvMsg, err := b.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取接收方消息: %v", err)
	}
	if recvMsg.State != store.MessageStateReceived || recvMsg.Direction != store.DirectionIn {
		t.Fatalf("接收方消息方向/状态错误: dir=%d state=%d", recvMsg.Direction, recvMsg.State)
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(recvMsg.BodyEnc, inner); err != nil {
		t.Fatalf("解析接收方附件: %v", err)
	}
	if len(inner.Attachments) != 1 {
		t.Fatalf("接收方附件条数 %d", len(inner.Attachments))
	}
	att := inner.Attachments[0]
	if att.GetBlobRef() == "" {
		t.Fatal("接收方附件缺少本地落盘路径")
	}
	got, err := os.ReadFile(att.GetBlobRef())
	if err != nil {
		t.Fatalf("读取落盘文件: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("落盘文件内容与源文件不一致")
	}
	want := sha256.Sum256(data)
	if !bytes.Equal(att.GetSha256(), want[:]) {
		t.Fatal("附件摘要与源文件不一致")
	}

	for _, ev := range [][]TransferProgress{sent.snapshot(), recv.snapshot()} {
		if len(ev) == 0 {
			t.Fatal("未收到任何进度事件")
		}
		last := ev[len(ev)-1]
		if last.Done != int64(len(data)) || last.Total != int64(len(data)) {
			t.Fatalf("最终进度应为 100%%，实际 done=%d total=%d", last.Done, last.Total)
		}
	}

	conv, err := b.dao.GetConversation(ctx, convID)
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if conv.Unread != 1 {
		t.Fatalf("未读数应为 1，实际 %d", conv.Unread)
	}
}

func TestSendFileValidation(t *testing.T) {
	n := newTestNode(t, "A")
	ctx := context.Background()
	target := Target{PeerID: n.svc.host.ID(), AccountPub: []byte("bad")}
	if _, err := n.svc.SendFile(ctx, target, "relative.txt", ""); err != ErrInvalidTarget {
		t.Fatalf("非法账号公钥应返回 ErrInvalidTarget，实际 %v", err)
	}
	self := Target{PeerID: n.svc.host.ID(), AccountPub: n.account.Pub()}
	if _, err := n.svc.SendFile(ctx, self, filepath.Join(t.TempDir(), "x"), ""); err != ErrSelfSend {
		t.Fatalf("自发文件应返回 ErrSelfSend，实际 %v", err)
	}
	peerPub := make([]byte, 32)
	peerPub[0] = 1
	other := Target{PeerID: n.svc.host.ID(), AccountPub: peerPub}
	if _, err := n.svc.SendFile(ctx, other, "relative.txt", ""); !errors.Is(err, ErrInvalidFile) {
		t.Fatalf("相对路径应返回 ErrInvalidFile，实际 %v", err)
	}
	if _, err := n.svc.SendFile(ctx, other, filepath.Join(t.TempDir(), "missing"), ""); !errors.Is(err, ErrInvalidFile) {
		t.Fatalf("不存在文件应返回 ErrInvalidFile，实际 %v", err)
	}
}

func TestFileChunkCountNoSizeLimit(t *testing.T) {
	// 单文件大小不再人为设限：1TiB、100TiB 都应通过，只有超出 uint32 分片
	// 序号上限（约 1PiB）才拒绝。
	for _, size := range []int64{1 << 40, 100 << 40, int64(maxFileChunks-1) * DefaultChunkSize} {
		got, err := fileChunkCount(size, DefaultChunkSize)
		if err != nil {
			t.Fatalf("大小 %d 不应被拒绝: %v", size, err)
		}
		if int64(got) != (size+DefaultChunkSize-1)/DefaultChunkSize {
			t.Fatalf("大小 %d 分片数不符: %d", size, got)
		}
	}
	if _, err := fileChunkCount(int64(maxFileChunks+1)*DefaultChunkSize, DefaultChunkSize); !errors.Is(err, ErrFileTooLarge) {
		t.Fatalf("超出 uint32 分片上限应返回 ErrFileTooLarge，实际 %v", err)
	}
}

func TestValidFileAttachment(t *testing.T) {
	good := &nexmemv1.InnerMessage{Attachments: []*nexmemv1.Attachment{{
		Name:   "a.bin",
		Size:   10,
		Key:    make([]byte, 32),
		Sha256: make([]byte, 32),
	}}}
	if !validFileAttachment(good) {
		t.Fatal("合法附件应通过校验")
	}
	bad := &nexmemv1.InnerMessage{Attachments: []*nexmemv1.Attachment{{Name: "a.bin", Size: 10, Sha256: make([]byte, 32)}}}
	if validFileAttachment(bad) {
		t.Fatal("缺少密钥的附件应被拒绝")
	}
}
