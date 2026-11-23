package coreapp

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/internal/dm"
)

// TestBackupRestoreOnNewDevice 覆盖 P6-05 验收：备份在另一台设备导入并重启后，
// 账号身份、好友与历史消息完整恢复，且旧设备密钥被正确轮换（不再阻塞启动）。
func TestBackupRestoreOnNewDevice(t *testing.T) {
	var (
		mu sync.Mutex
		a  *App
		b  *App
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if string(a.Account().Pub()) == string(accountPub) {
			return targetOf(a), nil
		}
		if string(b.Account().Pub()) == string(accountPub) {
			return targetOf(b), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	gwA, appA, _ := startApp(t, filepath.Join(t.TempDir(), "a"), resolver)
	_, appB, logB := startApp(t, filepath.Join(t.TempDir(), "b"), resolver)
	mu.Lock()
	a, b = appA, appB
	mu.Unlock()

	// 好友与历史：A 把 B 加为好友并发出一条消息。
	call(t, gwA, "contact.add", map[string]any{
		"peer":  hex.EncodeToString(appB.Account().Pub()),
		"alias": "恢复用好友",
	})
	conv := dm.ConversationID(appA.Account().Pub(), appB.Account().Pub())
	call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "restore me",
	})
	waitFor(t, 5*time.Second, func() bool { return logB.has("message.new") })

	passphrase := base64.StdEncoding.EncodeToString([]byte("restore-passphrase"))
	backupPath := filepath.Join(t.TempDir(), "restore.nxbak")
	call(t, gwA, "backup.export", map[string]any{
		"path":           backupPath,
		"passphrase_b64": passphrase,
	})
	if _, err := os.Stat(backupPath); err != nil {
		t.Fatalf("备份文件未生成: %v", err)
	}
	srcAccountID := appA.Account().ID()
	call(t, gwA, "core.stop", map[string]any{})

	// 目标设备：全新目录，先按正常流程生成自己的账号与设备密钥。
	dirC := filepath.Join(t.TempDir(), "c")
	gwC, appC, _ := startApp(t, dirC, nil)
	deviceBefore := appC.PeerID()
	if appC.Account().ID() == srcAccountID {
		t.Fatal("目标设备初始账号不应与源设备相同")
	}
	call(t, gwC, "backup.import", map[string]any{
		"path":           backupPath,
		"passphrase_b64": passphrase,
	})

	// 重启：账号切换为备份中的身份，旧设备密钥无法解封时自动轮换。
	call(t, gwC, "core.stop", map[string]any{})
	if _, err := appC.Start(context.Background(), Config{
		DataDir: dirC,
		Listen:  []string{"/ip4/127.0.0.1/tcp/0"},
	}); err != nil {
		t.Fatalf("导入备份后重启失败: %v", err)
	}
	if appC.Account().ID() != srcAccountID {
		t.Fatalf("恢复后账号 = %s, 期望 %s", appC.Account().ID(), srcAccountID)
	}
	if appC.PeerID() == deviceBefore {
		t.Fatal("账号切换后仍复用旧设备密钥")
	}

	// 好友与历史消息可读。
	contacts, ok := call(t, gwC, "contact.list", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("恢复后 contact.list 返回值不是对象")
	}
	items := listItems(t, contacts)
	if len(items) != 1 {
		t.Fatalf("恢复后联系人数量 = %d, 期望 1", len(items))
	}
	if c, _ := items[0].(map[string]any); c["alias"] != "恢复用好友" {
		t.Fatalf("恢复后联系人备注错误: %v", items[0])
	}

	hist, ok := call(t, gwC, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 10,
	}).(map[string]any)
	if !ok {
		t.Fatal("恢复后 msg.list 返回值不是对象")
	}
	msgs := listItems(t, hist)
	if len(msgs) != 1 {
		t.Fatalf("恢复后历史消息 = %d 条, 期望 1", len(msgs))
	}
	if m, _ := msgs[0].(map[string]any); m["text"] != "restore me" || m["direction"] != "out" {
		t.Fatalf("恢复后历史消息字段错误: %v", msgs[0])
	}

	convs, ok := call(t, gwC, "conversation.list", map[string]any{"limit": 20}).(map[string]any)
	if !ok {
		t.Fatal("恢复后 conversation.list 返回值不是对象")
	}
	found := false
	for _, raw := range listItems(t, convs) {
		if c, _ := raw.(map[string]any); c["conversation_id"] == conv {
			found = true
			if c["last_text"] != "restore me" {
				t.Fatalf("恢复后会话摘要错误: %v", c)
			}
		}
	}
	if !found {
		t.Fatal("恢复后会话列表缺少单聊会话")
	}
}

// TestRestoreKeepsMatchingDeviceKey 确认同一账号重复导入不会轮换设备密钥。
func TestRestoreKeepsMatchingDeviceKey(t *testing.T) {
	dir := t.TempDir()
	gw, app, _ := startApp(t, dir, nil)
	peer := app.PeerID()
	backupPath := filepath.Join(t.TempDir(), "same.nxbak")
	passphrase := base64.StdEncoding.EncodeToString([]byte("same-passphrase"))
	call(t, gw, "backup.export", map[string]any{
		"path":           backupPath,
		"passphrase_b64": passphrase,
	})
	call(t, gw, "backup.import", map[string]any{
		"path":           backupPath,
		"passphrase_b64": passphrase,
	})
	call(t, gw, "core.stop", map[string]any{})
	if _, err := app.Start(context.Background(), Config{
		DataDir: dir,
		Listen:  []string{"/ip4/127.0.0.1/tcp/0"},
	}); err != nil {
		t.Fatalf("同账号恢复后重启失败: %v", err)
	}
	if app.PeerID() != peer {
		t.Fatal("同账号恢复不应轮换设备密钥")
	}
}
