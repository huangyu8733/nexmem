package dm

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/store"
)

// TestOpenInboundPartialResumes 校验续传起点按完整分片边界计算，并恢复前缀摘要。
func TestOpenInboundPartialResumes(t *testing.T) {
	dir := t.TempDir()
	partPath := filepath.Join(dir, "f.bin"+filePartSuffix)
	metaPath := filepath.Join(dir, "f.bin"+fileMetaSuffix)

	content := []byte("0123456789")
	sum := sha256.Sum256(content)
	meta := &nexmemv1.FileMeta{
		MsgUuid:     "msg-1",
		Size:        uint64(len(content)),
		ChunkSize:   4,
		TotalChunks: 3,
		Sha256:      sum[:],
	}
	if err := os.WriteFile(partPath, content[:4], 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writePartialMeta(metaPath, newPartialFileMeta(meta, sum[:])); err != nil {
		t.Fatal(err)
	}

	start, f, hasher, err := openInboundPartial(partPath, metaPath, meta, sum[:])
	if err != nil {
		t.Fatalf("打开半成品失败: %v", err)
	}
	defer f.Close()
	if start != 1 {
		t.Fatalf("续传起点应为 1，实际 %d", start)
	}
	prefix := sha256.Sum256(content[:4])
	if !bytes.Equal(hasher.Sum(nil), prefix[:]) {
		t.Fatal("续传前缀摘要不正确")
	}
	if _, err := f.Write(content[4:]); err != nil {
		t.Fatal(err)
	}
	if _, err := hasher.Write(content[4:]); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(hasher.Sum(nil), sum[:]) {
		t.Fatal("续传后整文件摘要不正确")
	}
}

// TestOpenInboundPartialTruncatesIncompleteChunk 校验半成品尾部残缺分片被截断。
func TestOpenInboundPartialTruncatesIncompleteChunk(t *testing.T) {
	dir := t.TempDir()
	partPath := filepath.Join(dir, "f.bin"+filePartSuffix)
	metaPath := filepath.Join(dir, "f.bin"+fileMetaSuffix)

	content := []byte("0123456789")
	sum := sha256.Sum256(content)
	meta := &nexmemv1.FileMeta{
		MsgUuid:     "msg-1",
		Size:        uint64(len(content)),
		ChunkSize:   4,
		TotalChunks: 3,
		Sha256:      sum[:],
	}
	if err := os.WriteFile(partPath, content[:6], 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writePartialMeta(metaPath, newPartialFileMeta(meta, sum[:])); err != nil {
		t.Fatal(err)
	}

	start, f, _, err := openInboundPartial(partPath, metaPath, meta, sum[:])
	if err != nil {
		t.Fatalf("打开半成品失败: %v", err)
	}
	f.Close()
	if start != 1 {
		t.Fatalf("残缺分片应回退到 1，实际 %d", start)
	}
	fi, err := os.Stat(partPath)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() != 4 {
		t.Fatalf("半成品应截断到 4 字节，实际 %d", fi.Size())
	}
}

// TestOpenInboundPartialRestartsOnMismatch 校验归属或参数不一致时丢弃旧半成品。
func TestOpenInboundPartialRestartsOnMismatch(t *testing.T) {
	dir := t.TempDir()
	partPath := filepath.Join(dir, "f.bin"+filePartSuffix)
	metaPath := filepath.Join(dir, "f.bin"+fileMetaSuffix)

	content := []byte("0123456789")
	sum := sha256.Sum256(content)
	oldMeta := &nexmemv1.FileMeta{
		MsgUuid:     "msg-old",
		Size:        uint64(len(content)),
		ChunkSize:   4,
		TotalChunks: 3,
		Sha256:      sum[:],
	}
	if err := os.WriteFile(partPath, content[:8], 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writePartialMeta(metaPath, newPartialFileMeta(oldMeta, sum[:])); err != nil {
		t.Fatal(err)
	}

	meta := &nexmemv1.FileMeta{
		MsgUuid:     "msg-new",
		Size:        uint64(len(content)),
		ChunkSize:   4,
		TotalChunks: 3,
		Sha256:      sum[:],
	}
	start, f, _, err := openInboundPartial(partPath, metaPath, meta, sum[:])
	if err != nil {
		t.Fatalf("打开半成品失败: %v", err)
	}
	f.Close()
	if start != 0 {
		t.Fatalf("参数不一致应从 0 重传，实际 %d", start)
	}
	fi, err := os.Stat(partPath)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() != 0 {
		t.Fatalf("旧半成品应被截断为 0，实际 %d", fi.Size())
	}
	saved, ok := loadPartialMeta(metaPath)
	if !ok || saved.MsgUUID != "msg-new" {
		t.Fatalf("续传元数据应更新为新消息，实际 %+v ok=%v", saved, ok)
	}
}

// TestSendFileResumeAfterInterrupt 是 P2-05 的验收用例：首轮传输在分片 20 后被注入断流，
// 发送端重连后应从接收方上报的续传起点继续，最终文件完整且每个分片只被处理一次。
func TestSendFileResumeAfterInterrupt(t *testing.T) {
	var writes atomic.Int32
	var tripped atomic.Bool
	const interruptAt = 20

	b := newTestNode(t, "B", func(o *Options) {
		o.fileInterrupt = func(idx int) bool {
			writes.Add(1)
			if idx == interruptAt && tripped.CompareAndSwap(false, true) {
				return true
			}
			return false
		}
	})
	a := newTestNode(t, "A")

	dir := t.TempDir()
	src := filepath.Join(dir, "resume.bin")
	data := make([]byte, 8<<20+123)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, data, 0o600); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	target := Target{
		PeerID:     b.svc.host.ID(),
		Addrs:      b.svc.host.Addrs(),
		AccountPub: b.account.Pub(),
	}
	msgID, err := a.svc.SendFile(ctx, target, src, "application/octet-stream")
	if err != nil {
		t.Fatalf("断点续传发送失败: %v", err)
	}

	totalChunks := int32((len(data) + DefaultChunkSize - 1) / DefaultChunkSize)
	if got := writes.Load(); got != totalChunks {
		t.Fatalf("分片应只处理 %d 个（续传不重传），实际 %d", totalChunks, got)
	}

	recv, err := b.dao.GetMessage(ctx, msgID)
	if err != nil {
		t.Fatalf("读取接收消息: %v", err)
	}
	if recv.State != store.MessageStateReceived {
		t.Fatalf("接收方状态应为 received，实际 %d", recv.State)
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(recv.BodyEnc, inner); err != nil {
		t.Fatal(err)
	}
	if len(inner.Attachments) != 1 {
		t.Fatalf("附件条数 %d", len(inner.Attachments))
	}
	got, err := os.ReadFile(inner.Attachments[0].GetBlobRef())
	if err != nil {
		t.Fatalf("读取落盘文件: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("续传后文件内容与源文件不一致")
	}

	entries, err := os.ReadDir(b.svc.inboxDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if filepath.Ext(name) == filePartSuffix || len(name) > len(fileMetaSuffix) && name[len(name)-len(fileMetaSuffix):] == fileMetaSuffix {
			t.Fatalf("成功后不应残留半成品或续传元数据: %s", name)
		}
	}
}
