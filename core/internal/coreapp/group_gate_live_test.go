package coreapp

// P4 阶段门禁实测：真实对象存储下的群盘离线补齐与轮换前向隔离。
//
// 未设置 NEXMEM_S3_ENDPOINT 时跳过；设置后使用真实 S3 兼容后端
// （R2 / MinIO / SeaweedFS）跑完整链路：
//  1. 两端建群并配置群盘（经 group.setStorage 下发密封配置）；
//  2. 成员离线期间群主发送 N 条消息，只落群盘；
//  3. 成员重启上线后由后台拉取自动补齐，补齐率必须 100% 且顺序正确；
//  4. 群主踢人并轮换密钥后再发消息，被移除成员拉取时必须因缺新版本密钥而跳过。

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/group"
)

// liveStorageEnv 读取真实 S3 后端配置，沿用 blob live 测试的环境变量约定。
func liveStorageEnv(t *testing.T) map[string]string {
	t.Helper()
	endpoint := os.Getenv("NEXMEM_S3_ENDPOINT")
	if endpoint == "" {
		t.Skip("未设置 NEXMEM_S3_ENDPOINT，跳过 P4 群盘真实存储门禁")
	}
	get := func(key, fallback string) string {
		if v := os.Getenv(key); v != "" {
			return v
		}
		return fallback
	}
	return map[string]string{
		"endpoint": endpoint,
		"bucket":   get("NEXMEM_S3_BUCKET", "nexmem"),
		"region":   get("NEXMEM_S3_REGION", "us-east-1"),
		"ak":       get("NEXMEM_S3_ACCESS_KEY", "minioadmin"),
		"sk":       get("NEXMEM_S3_SECRET_KEY", "minioadmin"),
	}
}

// TestP4GateGroupOfflineCatchUpLive 校验「离线成员补齐率 100%」与「轮换后前向隔离」。
func TestP4GateGroupOfflineCatchUpLive(t *testing.T) {
	env := liveStorageEnv(t)

	var (
		mu   sync.Mutex
		appA *App
		appB *App
	)
	resolv := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		for _, app := range []*App{appA, appB} {
			if app == nil {
				continue
			}
			acc := app.Account()
			if acc == nil || string(acc.Pub()) != string(accountPub) {
				continue
			}
			return targetOf(app), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	dirB := filepath.Join(t.TempDir(), "b")
	gwA, appA0, _ := startApp(t, filepath.Join(t.TempDir(), "a"), resolv)
	gwB, appB0, _ := startApp(t, dirB, resolv)
	mu.Lock()
	appA, appB = appA0, appB0
	mu.Unlock()

	// 测试环境没有索引服务，群成员目标解析器按账号直接给出设备地址。
	targetResolver := group.TargetResolverFunc(func(_ context.Context, accountPub []byte) (group.KeyTarget, error) {
		mu.Lock()
		defer mu.Unlock()
		for _, app := range []*App{appA, appB} {
			if app == nil {
				continue
			}
			acc := app.Account()
			if acc == nil || string(acc.Pub()) != string(accountPub) {
				continue
			}
			return group.KeyTarget{
				PeerID: app.hostOrNilID(), Addrs: app.hostOrNilAddrs(),
				AccountPub: accountPub, XPub: acc.XPub(),
			}, nil
		}
		return group.KeyTarget{}, dm.ErrInvalidTarget
	})
	appA.SetGroupTargetResolver(targetResolver)
	appB.SetGroupTargetResolver(targetResolver)

	// 先建立单聊连接，群密钥信封可沿现有连接到达。
	call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "connect first",
	})

	created, ok := call(t, gwA, "group.create", map[string]any{
		"title":   "P4 门禁群",
		"members": []string{hex.EncodeToString(appB.Account().Pub())},
	}).(map[string]any)
	if !ok {
		t.Fatal("group.create 返回值不是对象")
	}
	groupIDStr, _ := created["group_id"].(string)
	groupID, err := base64.RawURLEncoding.DecodeString(groupIDStr)
	if err != nil || len(groupID) == 0 {
		t.Fatalf("群 ID 非法: %q", groupIDStr)
	}

	// 管理员通过网关配置群盘，配置随密钥信封分发给成员。
	call(t, gwA, "group.setStorage", map[string]any{
		"group_id":   groupIDStr,
		"endpoint":   env["endpoint"],
		"bucket":     env["bucket"],
		"prefix":     "",
		"region":     env["region"],
		"ak":         env["ak"],
		"sk":         env["sk"],
		"path_style": true,
	})
	waitFor(t, 15*time.Second, func() bool {
		view, ok := call(t, gwB, "group.members", map[string]any{"group_id": groupIDStr}).(map[string]any)
		if !ok {
			return false
		}
		configured, _ := view["storage_configured"].(bool)
		return configured
	})

	// 成员离线。
	if err := appB.Stop(); err != nil {
		t.Fatalf("停止成员节点: %v", err)
	}

	const offlineMessages = 10
	for i := 0; i < offlineMessages; i++ {
		res, ok := call(t, gwA, "dm.sendGroupText", map[string]any{
			"group_id": groupIDStr,
			"text":     fmt.Sprintf("离线群消息-%02d", i),
		}).(map[string]any)
		if !ok {
			t.Fatalf("第 %d 条群消息返回值不是对象", i)
		}
		if stored, _ := res["stored"].(bool); !stored {
			t.Fatalf("第 %d 条群消息未落群盘: %v", i, res["storage_error"])
		}
	}

	// 成员重启上线，后台拉取应在启动后自动补齐。
	started := time.Now()
	if _, err := appB.Start(context.Background(), Config{DataDir: dirB, Listen: []string{"/ip4/127.0.0.1/tcp/0"}}); err != nil {
		t.Fatalf("重启成员节点: %v", err)
	}
	convID := "group:" + groupIDStr
	var items []map[string]any
	waitFor(t, 30*time.Second, func() bool {
		resp, ok := call(t, gwB, "msg.list", map[string]any{
			"conversation_id": convID,
			"limit":           50,
		}).(map[string]any)
		if !ok {
			return false
		}
		items, _ = resp["items"].([]map[string]any)
		return len(items) >= offlineMessages
	})
	elapsed := time.Since(started).Round(time.Millisecond)

	// 补齐内容与顺序必须与离线期间发送一致（msg.list 按时间倒序）。
	for i, item := range items {
		want := fmt.Sprintf("离线群消息-%02d", offlineMessages-1-i)
		if item["text"] != want || item["direction"] != "in" {
			t.Fatalf("第 %d 条补齐消息不符: %v，期望 %s", i, item, want)
		}
	}

	// 重复拉取不得重复入库。
	rep, err := appB.groupService().FetchGroup(context.Background(), groupID)
	if err != nil {
		t.Fatalf("重复拉取群盘: %v", err)
	}
	if rep.Imported != 0 {
		t.Fatalf("重复拉取导入了 %d 条，期望 0", rep.Imported)
	}
	resp, _ := call(t, gwB, "msg.list", map[string]any{"conversation_id": convID, "limit": 50}).(map[string]any)
	if n := len(resp["items"].([]map[string]any)); n != offlineMessages {
		t.Fatalf("重复拉取后消息数 %d，期望 %d", n, offlineMessages)
	}

	// 踢人并轮换到 v2：被移除成员不会收到新密钥。
	svcA := appA.groupService()
	key, _, err := svcA.RemoveMember(context.Background(), groupID, appB.Account().Pub(), nil)
	if err != nil {
		t.Fatalf("移除成员: %v", err)
	}
	if key.Version != 2 {
		t.Fatalf("轮换后密钥版本 %d，期望 2", key.Version)
	}

	const rotatedMessages = 3
	for i := 0; i < rotatedMessages; i++ {
		res, ok := call(t, gwA, "dm.sendGroupText", map[string]any{
			"group_id": groupIDStr,
			"text":     fmt.Sprintf("轮换后-%02d", i),
		}).(map[string]any)
		if !ok {
			t.Fatalf("轮换后第 %d 条群消息返回值不是对象", i)
		}
		if stored, _ := res["stored"].(bool); !stored {
			t.Fatalf("轮换后第 %d 条群消息未落群盘: %v", i, res["storage_error"])
		}
	}

	// 被移除成员拉取：v2 消息因缺密钥被跳过，本地消息数不变。
	rep, err = appB.groupService().FetchGroup(context.Background(), groupID)
	if err != nil {
		t.Fatalf("被移除成员拉取群盘: %v", err)
	}
	if rep.Imported != 0 {
		t.Fatalf("被移除成员导入了 %d 条新版本消息，期望 0", rep.Imported)
	}
	if rep.Scanned < rotatedMessages {
		t.Fatalf("被移除成员扫描到 %d 个对象，期望至少 %d", rep.Scanned, rotatedMessages)
	}
	resp, _ = call(t, gwB, "msg.list", map[string]any{"conversation_id": convID, "limit": 50}).(map[string]any)
	if n := len(resp["items"].([]map[string]any)); n != offlineMessages {
		t.Fatalf("轮换后被移除成员消息数 %d，期望仍为 %d", n, offlineMessages)
	}

	// 被移除成员本地群资料不会收到 v2，密钥版本仍停留在 1。
	viewB, _ := call(t, gwB, "group.members", map[string]any{"group_id": groupIDStr}).(map[string]any)
	if version := fmt.Sprint(viewB["key_version"]); version != "1" {
		t.Fatalf("被移除成员密钥版本 %v，期望 1", viewB["key_version"])
	}

	t.Logf("CATCHUP_SENT=%d", offlineMessages)
	t.Logf("CATCHUP_IMPORTED=%d", len(items))
	t.Logf("CATCHUP_RATE=%.0f%%", float64(len(items))/float64(offlineMessages)*100)
	t.Logf("CATCHUP_ELAPSED=%s", elapsed)
	t.Logf("ROTATION_VERSION=%d", key.Version)
	t.Logf("ROTATION_SCANNED=%d", rep.Scanned)
	t.Logf("ROTATION_ISOLATED=true")
}
