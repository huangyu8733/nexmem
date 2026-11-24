package fs

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"

	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
)

type fsNode struct {
	dao     *store.DAO
	account *identity.Account
	host    host.Host
	svc     *Service
	progress []Progress
	mu       sync.Mutex
}

func newFSNode(t *testing.T, tag string) *fsNode {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "nexmem.db"))
	if err != nil {
		t.Fatalf("%s 打开数据库: %v", tag, err)
	}
	if err := store.Migrate(ctx, db); err != nil {
		db.Close()
		t.Fatalf("%s 迁移: %v", tag, err)
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		db.Close()
		t.Fatalf("%s 生成账号: %v", tag, err)
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(dir, "device.key"))
	if err != nil {
		db.Close()
		t.Fatalf("%s 设备密钥: %v", tag, err)
	}
	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey: priv,
		Listen:     []string{"/ip4/127.0.0.1/tcp/0"},
		UserAgent:  "nexmem-fs-test/0.1.0",
	})
	if err != nil {
		db.Close()
		t.Fatalf("%s 启动 host: %v", tag, err)
	}
	n := &fsNode{dao: store.NewDAO(db), account: acc, host: h}
	svc, err := New(Options{
		Host:      h,
		DeviceKey: priv,
		DAO:       n.dao,
		Account:   acc,
		OnProgress: func(p Progress) {
			n.mu.Lock()
			n.progress = append(n.progress, p)
			n.mu.Unlock()
		},
	})
	if err != nil {
		h.Close()
		db.Close()
		t.Fatalf("%s 创建共享服务: %v", tag, err)
	}
	n.svc = svc
	t.Cleanup(func() {
		svc.Close()
		h.Close()
		db.Close()
	})
	return n
}

func (n *fsNode) seed(t *testing.T) Seed {
	t.Helper()
	addrs := make([]string, 0, len(n.host.Addrs()))
	for _, a := range n.host.Addrs() {
		addrs = append(addrs, a.String())
	}
	return Seed{PeerID: n.host.ID().String(), Addrs: addrs}
}

func writeTree(t *testing.T, root string) map[string][]byte {
	t.Helper()
	files := map[string][]byte{
		"readme.txt":       []byte("hello nexmem share\n"),
		"docs/guide.md":    []byte(strings.Repeat("guide content ", 20000)),
		"assets/big.bin":   []byte(strings.Repeat("X", 700000)),
	}
	for rel, data := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return files
}

func TestManifestSignVerifyAndCode(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	m := &Manifest{
		Name:      "test",
		CreatedAt: 1,
		Files: []FileEntry{{
			Path: "a.txt", Size: 3, SHA256: fmt.Sprintf("%x", hashOfBytes([]byte("abc"))),
			Key: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		}},
	}
	if err := m.Sign(acc); err != nil {
		t.Fatal(err)
	}
	owner, err := m.Verify()
	if err != nil {
		t.Fatalf("清单校验失败: %v", err)
	}
	if owner != acc.ID() {
		t.Fatalf("发布者不符: %s != %s", owner, acc.ID())
	}
	code, err := EncodeCode(m, []Seed{{PeerID: "12D3KooW", Addrs: []string{"/ip4/127.0.0.1/tcp/4001"}}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(code, CodePrefix) {
		t.Fatalf("分享码缺少前缀: %s", code)
	}
	got, seeds, err := DecodeCode(code)
	if err != nil {
		t.Fatalf("解析分享码: %v", err)
	}
	if got.ID != m.ID || len(seeds) != 1 || seeds[0].PeerID != "12D3KooW" {
		t.Fatalf("分享码内容不符: %+v %+v", got, seeds)
	}
	// 篡改签名位应被拒绝。
	bad := *m
	bad.Name = "tampered"
	if _, err := bad.Verify(); err == nil {
		t.Fatal("被篡改的清单应校验失败")
	}
}

func hashOfBytes(b []byte) []byte {
	sum := sha256.Sum256(b)
	return sum[:]
}

func hashBytes(b []byte) []byte {
	return hashOfBytes(b)
}

func TestPublishListRemove(t *testing.T) {
	n := newFSNode(t, "publish")
	root := t.TempDir()
	want := writeTree(t, root)
	rec, code, err := n.svc.Publish(context.Background(), root, "资料包")
	if err != nil {
		t.Fatalf("发布失败: %v", err)
	}
	if rec.Manifest.ID == "" || !strings.HasPrefix(code, CodePrefix) {
		t.Fatalf("发布结果异常: %+v", rec.Manifest)
	}
	if len(rec.Manifest.Files) != len(want) {
		t.Fatalf("文件数不符: %d != %d", len(rec.Manifest.Files), len(want))
	}
	list := n.svc.List()
	if len(list) != 1 || list[0].Manifest.ID != rec.Manifest.ID {
		t.Fatalf("列表不符: %+v", list)
	}
	got, gotCode, err := n.svc.Get(rec.Manifest.ID)
	if err != nil || got.Manifest.ID != rec.Manifest.ID || gotCode == "" {
		t.Fatalf("获取失败: %v %+v", err, got)
	}
	if err := n.svc.Remove(rec.Manifest.ID); err != nil {
		t.Fatal(err)
	}
	if len(n.svc.List()) != 0 {
		t.Fatal("删除后列表应为空")
	}
}

func TestPublishAndDownloadRoundTrip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	seedNode := newFSNode(t, "seed")
	root := t.TempDir()
	want := writeTree(t, root)
	rec, _, err := seedNode.svc.Publish(ctx, root, "资料包")
	if err != nil {
		t.Fatal(err)
	}

	leech := newFSNode(t, "leech")
	imported, err := leech.svc.Import(ctx, mustCode(t, seedNode, rec.Manifest.ID))
	if err != nil {
		t.Fatalf("导入分享码: %v", err)
	}
	if imported.Manifest.ID != rec.Manifest.ID {
		t.Fatal("导入的共享 ID 不符")
	}
	dest := filepath.Join(t.TempDir(), "downloaded")
	got, err := leech.svc.Download(ctx, rec.Manifest.ID, dest, []Seed{seedNode.seed(t)}, 4)
	if err != nil {
		t.Fatalf("下载失败: %v", err)
	}
	if got.Kind != "downloaded" || got.LocalRoot != dest {
		t.Fatalf("下载后未做种: %+v", got)
	}
	for rel, data := range want {
		p := filepath.Join(dest, filepath.FromSlash(rel))
		out, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("缺少文件 %s: %v", rel, err)
		}
		if string(out) != string(data) {
			t.Fatalf("文件 %s 内容不符: %d != %d", rel, len(out), len(data))
		}
	}
	leech.mu.Lock()
	gotProgress := len(leech.progress)
	leech.mu.Unlock()
	if gotProgress == 0 {
		t.Fatal("未上报下载进度")
	}
	// 下载完成后本机应成为种子：第三个节点可从 leech 下载。
	third := newFSNode(t, "third")
	if _, err := third.svc.Import(ctx, mustCode(t, leech, rec.Manifest.ID)); err != nil {
		t.Fatal(err)
	}
	dest2 := filepath.Join(t.TempDir(), "from-leech")
	if _, err := third.svc.Download(ctx, rec.Manifest.ID, dest2, []Seed{leech.seed(t)}, 3); err != nil {
		t.Fatalf("从下载者做种失败: %v", err)
	}
	if out, err := os.ReadFile(filepath.Join(dest2, "readme.txt")); err != nil || string(out) != string(want["readme.txt"]) {
		t.Fatalf("二级做种文件不符: %v %s", err, out)
	}
}

func mustCode(t *testing.T, n *fsNode, id string) string {
	t.Helper()
	_, code, err := n.svc.Get(id)
	if err != nil {
		t.Fatal(err)
	}
	return code
}

func TestMultiSeedParallelDownload(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	root := t.TempDir()
	want := writeTree(t, root)
	// 两个节点发布同一份内容（清单相同 → ID 相同），下载地址分布到两种子。
	a := newFSNode(t, "seed-a")
	b := newFSNode(t, "seed-b")
	recA, _, err := a.svc.Publish(ctx, root, "资料包")
	if err != nil {
		t.Fatal(err)
	}
	recB, _, err := b.svc.Publish(ctx, root, "资料包")
	if err != nil {
		t.Fatal(err)
	}
	if recA.Manifest.ID != recB.Manifest.ID {
		t.Fatal("相同内容的共享 ID 应一致")
	}
	leech := newFSNode(t, "multi-leech")
	if _, err := leech.svc.Import(ctx, mustCode(t, a, recA.Manifest.ID)); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "multi")
	if _, err := leech.svc.Download(ctx, recA.Manifest.ID, dest, []Seed{a.seed(t), b.seed(t)}, 6); err != nil {
		t.Fatalf("多种子下载失败: %v", err)
	}
	for rel, data := range want {
		out, err := os.ReadFile(filepath.Join(dest, filepath.FromSlash(rel)))
		if err != nil || string(out) != string(data) {
			t.Fatalf("多种子下载文件 %s 不符: %v", rel, err)
		}
	}
}

func TestPathTraversalRejected(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	m := &Manifest{Name: "x", CreatedAt: 1, Files: []FileEntry{{
		Path: "../evil", Size: 3, SHA256: fmt.Sprintf("%x", hashBytes([]byte("abc"))),
		Key: base64.StdEncoding.EncodeToString(make([]byte, 32)),
	}}}
	if err := m.Sign(acc); err == nil {
		if _, err := m.Verify(); err == nil {
			t.Fatal("目录穿越路径应被拒绝")
		}
	}
}

var _ = peer.ID("")
var _ = multiaddr.NewMultiaddr
