package fs

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
)

// TestDeviceFolderDownload 是真机联调用例：在手机上通过「文件与传输 → 共享 →
// 发布文件夹」发布一个目录，拿到分享码后设置下面两个环境变量即可让本机作为
// 接收端，从手机这个种子实际下载并逐文件校验：
//
//	NEXMEM_DEVICE_SHARE_CODE=nexmem://fs/... \
//	NEXMEM_DEVICE_SEED=/ip4/192.168.0.103/tcp/39583 \
//	go test ./internal/fs -run TestDeviceFolderDownload -count=1 -v
//
// 未注入变量时自动跳过，不影响常规测试。
func TestDeviceFolderDownload(t *testing.T) {
	code := os.Getenv("NEXMEM_DEVICE_SHARE_CODE")
	seedAddr := os.Getenv("NEXMEM_DEVICE_SEED")
	if code == "" || seedAddr == "" {
		t.Skip("未注入 NEXMEM_DEVICE_SHARE_CODE / NEXMEM_DEVICE_SEED，跳过真机联调")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	manifest, seeds, err := DecodeCode(code)
	if err != nil {
		t.Fatalf("解析真机分享码: %v", err)
	}
	if len(seeds) == 0 {
		t.Fatal("分享码里没有种子地址")
	}

	leech := newFSNode(t, "device-leech")
	imported, err := leech.svc.Import(ctx, code)
	if err != nil {
		t.Fatalf("导入真机分享码: %v", err)
	}
	if imported.Manifest.ID != manifest.ID {
		t.Fatal("导入后 share ID 不一致")
	}

	// 真机在 VPN 下会 advertise 公网/VPN 地址；联调时改用局域网可达地址。
	deviceSeed := Seed{PeerID: seeds[0].PeerID, Addrs: []string{seedAddr}}
	dest := filepath.Join(t.TempDir(), "device-download")
	got, err := leech.svc.Download(ctx, manifest.ID, dest, []Seed{deviceSeed}, 4)
	if err != nil {
		t.Fatalf("从真机下载失败: %v", err)
	}
	if got.LocalRoot != dest {
		t.Fatalf("下载目标不符: %s", got.LocalRoot)
	}
	for _, f := range manifest.Files {
		raw, err := os.ReadFile(filepath.Join(dest, filepath.FromSlash(f.Path)))
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", f.Path, err)
		}
		if int64(len(raw)) != f.Size {
			t.Fatalf("%s 大小不符: %d != %d", f.Path, len(raw), f.Size)
		}
		sum := sha256.Sum256(raw)
		if fmt.Sprintf("%x", sum) != f.SHA256 {
			t.Fatalf("%s 摘要不符", f.Path)
		}
		t.Logf("校验通过: %s (%d 字节)", f.Path, f.Size)
	}
}

// TestDevicePublishForPhone 是真机联调的反向用例：把本机一个目录发布为共享，
// 把种子地址改写成手机可达的局域网地址，写入 NEXMEM_DEVICE_CODE_OUT 指向的文件，
// 然后保持进程存活（默认 3 分钟）供手机导入并下载。
//
//	NEXMEM_DEVICE_PUBLISH_DIR=/tmp/nexmem-mac-share \
//	NEXMEM_DEVICE_CODE_OUT=/tmp/nexmem-mac-code.txt \
//	NEXMEM_DEVICE_LAN_IP=192.168.0.104 \
//	go test ./internal/fs -run TestDevicePublishForPhone -count=1 -v -timeout 240s
func TestDevicePublishForPhone(t *testing.T) {
	dir := os.Getenv("NEXMEM_DEVICE_PUBLISH_DIR")
	out := os.Getenv("NEXMEM_DEVICE_CODE_OUT")
	lanIP := os.Getenv("NEXMEM_DEVICE_LAN_IP")
	if dir == "" || out == "" || lanIP == "" {
		t.Skip("未注入 NEXMEM_DEVICE_PUBLISH_DIR / CODE_OUT / LAN_IP，跳过真机联调")
	}
	ctx := context.Background()
	root := t.TempDir()
	db, err := store.Open(filepath.Join(root, "nexmem.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := store.Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(root, "device.key"))
	if err != nil {
		t.Fatal(err)
	}
	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey: priv,
		Listen:     []string{"/ip4/0.0.0.0/tcp/0"},
		UserAgent:  "nexmem-device-check/0.1.0",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	svc, err := New(Options{Host: h, DeviceKey: priv, DAO: store.NewDAO(db), Account: acc})
	if err != nil {
		t.Fatal(err)
	}
	defer svc.Close()
	rec, code, err := svc.Publish(ctx, dir, "mac-device-share")
	if err != nil {
		t.Fatalf("发布目录失败: %v", err)
	}
	m, seeds, err := DecodeCode(code)
	if err != nil {
		t.Fatal(err)
	}
	// 从实际监听地址取端口，替换为手机可达的局域网 IP。
	var lanAddr string
	for _, a := range h.Addrs() {
		parts := strings.Split(a.String(), "/")
		for i, part := range parts {
			if part == "tcp" && i+1 < len(parts) {
				lanAddr = fmt.Sprintf("/ip4/%s/tcp/%s", lanIP, parts[i+1])
				break
			}
		}
		if lanAddr != "" {
			break
		}
	}
	if lanAddr == "" {
		t.Fatal("主机没有 TCP 监听地址")
	}
	seeds = mergeSeeds([]Seed{{PeerID: seeds[0].PeerID, Addrs: []string{lanAddr}}})
	code, err = EncodeCode(m, seeds)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(out, []byte(code), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Logf("已发布 share=%s，分享码写入 %s，种子=%+v", rec.Manifest.ID, out, seeds)
	wait := 600 * time.Second
	if raw := os.Getenv("NEXMEM_DEVICE_WAIT_SEC"); raw != "" {
		if sec, err := time.ParseDuration(raw + "s"); err == nil {
			wait = sec
		}
	}
	t.Logf("等待手机导入并下载（%s）...", wait)
	time.Sleep(wait)
}
