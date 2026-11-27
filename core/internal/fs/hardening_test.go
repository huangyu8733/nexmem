package fs

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/identity"
)

// TestPartPathNoCollision 回归「a/b 与 a_b 被压平成同一个 .part 文件」的问题。
func TestPartPathNoCollision(t *testing.T) {
	dest := t.TempDir()
	a := partPath(dest, "a/b")
	b := partPath(dest, "a_b")
	if a == b {
		t.Fatalf("路径压平导致分片临时文件碰撞: %s", a)
	}
	for _, p := range []string{a, b} {
		if !strings.HasPrefix(p, filepath.Join(dest, partsDir)+string(filepath.Separator)) {
			t.Fatalf("分片文件应位于隐藏目录: %s", p)
		}
	}
	if err := writePart(dest, "a/b", 0, []byte("ab"), 2); err != nil {
		t.Fatal(err)
	}
	if err := writePart(dest, "a_b", 0, []byte("cd"), 2); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(a)
	if err != nil || string(first) != "ab" {
		t.Fatalf("a/b 内容不符: %q %v", first, err)
	}
	second, err := os.ReadFile(b)
	if err != nil || string(second) != "cd" {
		t.Fatalf("a_b 内容不符: %q %v", second, err)
	}
}

// TestPreparePartsResumesOnlyCompleteChunks 验证断点续传只认已写满且带完成标记的分片。
func TestPreparePartsResumesOnlyCompleteChunks(t *testing.T) {
	dest := t.TempDir()
	m := &Manifest{ID: "manifest-v1", Files: []FileEntry{{
		Path: "big.bin", Size: int64(fsChunkSize) * 3,
	}}}
	root := filepath.Join(dest, partsDir)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, partsMarker), []byte(m.ID), 0o600); err != nil {
		t.Fatal(err)
	}
	// 分片 0 写满并标记；分片 1 写满但没标记；分片 2 有标记但文件没写满。
	if err := writePart(dest, "big.bin", 0, make([]byte, fsChunkSize), m.Files[0].Size); err != nil {
		t.Fatal(err)
	}
	if err := markPartDone(dest, "big.bin", 0); err != nil {
		t.Fatal(err)
	}
	if err := writePart(dest, "big.bin", int64(fsChunkSize), make([]byte, fsChunkSize), m.Files[0].Size); err != nil {
		t.Fatal(err)
	}
	if err := markPartDone(dest, "big.bin", 2); err != nil {
		t.Fatal(err)
	}
	resumed, err := prepareParts(dest, m)
	if err != nil {
		t.Fatal(err)
	}
	if resumed != int64(fsChunkSize) {
		t.Fatalf("续传字节 = %d，期望 %d（只算完整分片）", resumed, fsChunkSize)
	}

	// 清单 ID 变化时旧分片必须丢弃，避免把不同版本内容拼在一起。
	changed := &Manifest{ID: "manifest-v2", Files: m.Files}
	resumed, err = prepareParts(dest, changed)
	if err != nil {
		t.Fatal(err)
	}
	if resumed != 0 {
		t.Fatalf("清单变更后续传字节 = %d，期望 0", resumed)
	}
	if partDone(dest, "big.bin", 0) {
		t.Fatal("清单变更后旧完成标记应被清除")
	}
	raw, err := os.ReadFile(filepath.Join(root, partsMarker))
	if err != nil || strings.TrimSpace(string(raw)) != changed.ID {
		t.Fatalf("清单标记未更新: %q %v", raw, err)
	}
}

// TestManifestVerifyRejectsMalformedCryptoFields 确保清单校验不只是「能 base64 解码」。
func TestManifestVerifyRejectsMalformedCryptoFields(t *testing.T) {
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	validKey := base64.StdEncoding.EncodeToString(make([]byte, 32))
	validSHA := fmt.Sprintf("%x", hashBytes([]byte("abc")))
	cases := []struct {
		name string
		key  string
		sha  string
	}{
		{"短密钥", base64.StdEncoding.EncodeToString(make([]byte, 16)), validSHA},
		{"短摘要", validKey, "deadbeef"},
		{"非十六进制摘要", validKey, strings.Repeat("z", 64)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := &Manifest{Name: "x", CreatedAt: 1, Files: []FileEntry{{
				Path: "a.txt", Size: 3, SHA256: tc.sha, Key: tc.key,
			}}}
			if err := m.Sign(acc); err != nil {
				t.Fatal(err)
			}
			if _, err := m.Verify(); !errors.Is(err, ErrInvalidManifest) {
				t.Fatalf("畸形加密字段应被拒绝，实际: %v", err)
			}
		})
	}
}

// TestImportKeepsLocalShare 导入同 ID 分享码不能覆盖本机已下载记录的 LocalRoot。
func TestImportKeepsLocalShare(t *testing.T) {
	ctx := context.Background()
	n := newFSNode(t, "keep-local")
	root := t.TempDir()
	writeTree(t, root)
	rec, code, err := n.svc.Publish(ctx, root, "资料包")
	if err != nil {
		t.Fatal(err)
	}
	imported, err := n.svc.Import(ctx, code)
	if err != nil {
		t.Fatal(err)
	}
	if imported.LocalRoot != root || imported.Kind != "published" {
		t.Fatalf("导入覆盖了本机共享记录: %+v", imported)
	}
	got, _, err := n.svc.Get(rec.Manifest.ID)
	if err != nil || got.LocalRoot != root {
		t.Fatalf("本机做种能力丢失: %+v %v", got, err)
	}
}

// TestGetDoesNotAdvertiseSelfWithoutLocalFile 未下载的共享不能把本机写进分享码当种子。
func TestGetDoesNotAdvertiseSelfWithoutLocalFile(t *testing.T) {
	ctx := context.Background()
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	m := &Manifest{Name: "远端", CreatedAt: 1, Files: []FileEntry{{
		Path: "x.txt", Size: 3, SHA256: fmt.Sprintf("%x", hashBytes([]byte("abc"))),
		Key: base64.StdEncoding.EncodeToString(make([]byte, 32)),
	}}}
	if err := m.Sign(acc); err != nil {
		t.Fatal(err)
	}
	code, err := EncodeCode(m, nil)
	if err != nil {
		t.Fatal(err)
	}
	n := newFSNode(t, "no-local")
	imported, err := n.svc.Import(ctx, code)
	if err != nil {
		t.Fatal(err)
	}
	_, outCode, err := n.svc.Get(imported.Manifest.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, seeds, err := DecodeCode(outCode)
	if err != nil {
		t.Fatal(err)
	}
	if len(seeds) != 0 {
		t.Fatalf("未下载共享不应广播本机种子: %+v", seeds)
	}
}

// TestDownloadRejectsForeignOwner 同 ID 但 Owner 不同的清单不能被种子偷换。
func TestDownloadRejectsForeignOwner(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ownerA := newFSNode(t, "owner-a")
	ownerB := newFSNode(t, "owner-b")
	root := t.TempDir()
	writeTree(t, root)

	recA, codeA, err := ownerA.svc.Publish(ctx, root, "资料包")
	if err != nil {
		t.Fatal(err)
	}
	// 同一份内容由另一个账号签名：ID 相同、Owner 不同，签名各自有效。
	foreign := *recA.Manifest
	if err := foreign.Sign(ownerB.account); err != nil {
		t.Fatal(err)
	}
	if foreign.ID != recA.Manifest.ID || foreign.Owner == recA.Manifest.Owner {
		t.Fatal("测试前提不成立：同内容应同 ID 且不同 Owner")
	}
	ownerB.svc.mu.Lock()
	ownerB.svc.shares[foreign.ID] = &ShareRecord{
		Manifest: &foreign, LocalRoot: root, Kind: "published", CreatedAt: foreign.CreatedAt,
	}
	ownerB.svc.mu.Unlock()

	leech := newFSNode(t, "owner-leech")
	if _, err := leech.svc.Import(ctx, codeA); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "foreign")
	if _, err := leech.svc.Download(ctx, foreign.ID, dest, []Seed{ownerB.seed(t)}, 2); !errors.Is(err, ErrNoSeeds) {
		t.Fatalf("Owner 不符的种子应被跳过，实际: %v", err)
	}
	if _, err := os.Stat(dest); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("拒绝后不应创建目标目录: %v", err)
	}
}

// TestConcurrentDownloadSameShare 同一共享的并发下载必须串行，且不写坏文件。
func TestConcurrentDownloadSameShare(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	seedNode := newFSNode(t, "concurrent-seed")
	root := t.TempDir()
	want := writeTree(t, root)
	rec, code, err := seedNode.svc.Publish(ctx, root, "资料包")
	if err != nil {
		t.Fatal(err)
	}
	leech := newFSNode(t, "concurrent-leech")
	if _, err := leech.svc.Import(ctx, code); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "same-dest")
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = leech.svc.Download(ctx, rec.Manifest.ID, dest, []Seed{seedNode.seed(t)}, 3)
		}(i)
	}
	wg.Wait()
	ok, done := 0, 0
	for _, err := range errs {
		switch {
		case err == nil:
			ok++
		case errors.Is(err, ErrDownloadDone):
			done++
		default:
			t.Fatalf("并发下载返回意外错误: %v", err)
		}
	}
	if ok != 1 || done != 1 {
		t.Fatalf("应恰好一次成功、一次已完成，实际 ok=%d done=%d", ok, done)
	}
	for rel, data := range want {
		out, err := os.ReadFile(filepath.Join(dest, filepath.FromSlash(rel)))
		if err != nil || string(out) != string(data) {
			t.Fatalf("并发下载文件 %s 损坏: %v", rel, err)
		}
	}
}

// TestDownloadHandlerBoundsParallel fs.download 网关层拒绝超大并发参数。
func TestDownloadHandlerBoundsParallel(t *testing.T) {
	n := newFSNode(t, "gateway-parallel")
	g := gateway.New()
	if err := Bind(g, &Gateway{Service: func() *Service { return n.svc }}); err != nil {
		t.Fatal(err)
	}
	req, err := json.Marshal(gateway.Request{
		ID: 1, Method: "fs.download",
		Params: json.RawMessage(`{"share_id":"abc","dest":"/tmp/nexmem-guard","parallel":33}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	var res struct {
		OK    bool           `json:"ok"`
		Error *gateway.Error `json:"error"`
	}
	if err := json.Unmarshal(g.Serve(context.Background(), req), &res); err != nil {
		t.Fatal(err)
	}
	if res.OK || res.Error == nil || res.Error.Code != gateway.CodeInvalidArg {
		t.Fatalf("应返回 INVALID_ARG，实际: %+v", res)
	}
	if !strings.Contains(res.Error.Message, "parallel") {
		t.Fatalf("错误信息应指出 parallel 参数: %s", res.Error.Message)
	}
}
