package group

// A-02 群聊附件：群盘存密文 + 群消息广播附件元数据 + 下载解密闭环。

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/p2p/net/mock"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

func TestGroupFileSendReceiveDownload(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("a02-group-file-test")
	mn := mocknet.New()
	defer mn.Close()

	c := newStorageCluster(t, mn, nil)
	c.start(t, groupID)

	// 造一个本机文件。
	dir := t.TempDir()
	src := filepath.Join(dir, "hello.txt")
	payload := []byte("群文件端到端内容：加密写群盘，元数据随群消息广播")
	if err := os.WriteFile(src, payload, 0o600); err != nil {
		t.Fatalf("写入源文件: %v", err)
	}

	res, err := c.admin.svc.SendFile(ctx, groupID, src, "text/plain")
	if err != nil {
		t.Fatalf("发送群文件: %v", err)
	}
	if res.MsgUUID == "" || !res.Stored {
		t.Fatalf("发送结果不符: %+v", res)
	}

	// 群盘上应有两个对象：消息信封 + files/ 下的密文。
	var fileKey string
	for key := range c.adminStore.snapshot() {
		if bytes.Contains([]byte(key), []byte("/files/")) {
			fileKey = key
		}
	}
	if fileKey == "" {
		t.Fatal("群盘缺少文件密文对象")
	}

	// 成员应收到一条文件消息，解出附件元数据（含 blob_ref 与密钥）。
	att := waitGroupFileAttachment(t, c.recv[0])
	if att.GetBlobRef() != fileKey {
		t.Fatalf("附件 blob_ref=%q，期望 %q", att.GetBlobRef(), fileKey)
	}
	if att.GetName() != "hello.txt" || att.GetSize() != uint64(len(payload)) {
		t.Fatalf("附件元数据不符: %+v", att)
	}

	// 下载并解密，内容与源文件一致。
	// 注：测试集群里各成员用独立 fake 桶；真实部署所有成员共享同一群盘桶，
	// 这里用写入方（admin）的桶验证群盘取回 + 解密闭环。
	plain, err := c.admin.svc.DownloadFile(ctx, groupID, att.GetBlobRef(), att.GetKey())
	if err != nil {
		t.Fatalf("下载群文件: %v", err)
	}
	if !bytes.Equal(plain, payload) {
		t.Fatalf("下载内容与源文件不一致: %q", plain)
	}
}

func TestGroupFileRejectsOversizeAndRelativePath(t *testing.T) {
	ctx := context.Background()
	groupID := []byte("a02-group-file-invalid")
	mn := mocknet.New()
	defer mn.Close()
	c := newStorageCluster(t, mn, nil)
	c.start(t, groupID)

	if _, err := c.admin.svc.SendFile(ctx, groupID, "relative.txt", "text/plain"); err == nil {
		t.Fatal("相对路径应被拒绝")
	}

	big := filepath.Join(t.TempDir(), "big.bin")
	f, err := os.Create(big)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(groupFileMaxBytes + 1); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if _, err := c.admin.svc.SendFile(ctx, groupID, big, "application/octet-stream"); err == nil {
		t.Fatal("超大文件应被拒绝")
	}
}

// waitGroupFileAttachment 等待成员收到群文件消息并解出附件元数据。
func waitGroupFileAttachment(t *testing.T, ch chan Received) *nexmemv1.Attachment {
	t.Helper()
	for i := 0; i < 200; i++ {
		select {
		case r := <-ch:
			var inner nexmemv1.InnerMessage
			if proto.Unmarshal(r.Plaintext, &inner) == nil && len(inner.GetAttachments()) > 0 {
				return inner.GetAttachments()[0]
			}
		default:
		}
		// 用极短退避，避免忙等占满调度。
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("未收到群文件附件消息")
	return nil
}
