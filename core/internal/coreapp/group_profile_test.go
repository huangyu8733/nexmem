package coreapp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/png"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/group"
)

// retryControlFrame 重复下发幂等控制帧 RPC，直到对端状态收敛。
// GossipSub mesh 刚订阅时尚未连通，单次广播可能丢失；真实 UI 中管理员
// 操作后可再次设置，测试需要显式重试以消除 mesh 建立时序的影响。
func retryControlFrame(t *testing.T, send func(), observe func() bool) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		send()
		pollUntil := time.Now().Add(time.Second)
		for time.Now().Before(pollUntil) {
			if observe() {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("控制帧同步超时")
}

func testProfileLevelIcon(t *testing.T) string {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, group.LevelIconSize, group.LevelIconSize))); err != nil {
		t.Fatalf("生成测试 PNG: %v", err)
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

// TestGroupProfileEndToEnd 验收本群称呼与群等级的端到端链路：
// 管理员配置等级、修改成员资料，成员改自己称呼；两端通过控制帧同步、
// 发出 group.levelsChanged / group.memberProfileChanged，且不产生聊天气泡。
func TestGroupProfileEndToEnd(t *testing.T) {
	var (
		mu sync.Mutex
		a  *App
		b  *App
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		for _, app := range []*App{a, b} {
			if app == nil {
				continue
			}
			if acc := app.Account(); acc != nil && string(acc.Pub()) == string(accountPub) {
				return targetOf(app), nil
			}
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})
	gwA, appA, _ := startApp(t, filepath.Join(t.TempDir(), "a"), resolver)
	gwB, appB, logB := startApp(t, filepath.Join(t.TempDir(), "b"), resolver)
	mu.Lock()
	a, b = appA, appB
	mu.Unlock()

	targetResolver := group.TargetResolverFunc(func(_ context.Context, accountPub []byte) (group.KeyTarget, error) {
		mu.Lock()
		defer mu.Unlock()
		for _, app := range []*App{a, b} {
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

	// 先建立单聊连接，群控制帧沿现有连接到达成员。
	call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "connect first",
	})
	created, ok := call(t, gwA, "group.create", map[string]any{
		"title":   "资料群",
		"members": []string{hex.EncodeToString(appB.Account().Pub())},
	}).(map[string]any)
	if !ok {
		t.Fatal("group.create 返回值不是对象")
	}
	groupID, _ := created["group_id"].(string)
	if groupID == "" {
		t.Fatal("group.create 未返回 group_id")
	}

	memberAccount := hex.EncodeToString(appB.Account().Pub())
	memberView := func() (map[string]any, bool) {
		raw, _ := json.Marshal(map[string]any{"group_id": groupID})
		data, gerr := gwB.Handle(context.Background(), "group.members", raw)
		if gerr != nil {
			return nil, false
		}
		view, ok := data.(map[string]any)
		return view, ok
	}
	memberProfile := func(view map[string]any) (string, string) {
		for _, item := range view["members"].([]map[string]any) {
			if item["account"] == base64.RawURLEncoding.EncodeToString(appB.Account().Pub()) {
				nickname, _ := item["nickname"].(string)
				levelID, _ := item["level_id"].(string)
				return nickname, levelID
			}
		}
		return "", ""
	}
	waitFor(t, propagationWait, func() bool {
		_, ok := memberView()
		return ok
	})

	// 管理员开启等级并配置一个等级，成员端通过控制帧同步。
	icon := testProfileLevelIcon(t)
	retryControlFrame(t, func() {
		call(t, gwA, "group.setLevelConfig", map[string]any{
			"group_id": groupID,
			"enabled":  true,
			"levels": []map[string]any{
				{"id": "vip1", "name": "贵宾", "icon_b64": icon},
			},
		})
	}, func() bool {
		view, ok := memberView()
		if !ok || view["level_enabled"] != true {
			return false
		}
		levels, ok := view["levels"].([]group.GroupLevel)
		return ok && len(levels) == 1 && levels[0].ID == "vip1"
	})
	waitFor(t, eventWait, func() bool { return logB.has("group.levelsChanged") })

	// 管理员设置成员本群称呼与等级，成员端收到资料变更事件。
	retryControlFrame(t, func() {
		call(t, gwA, "group.setMemberProfile", map[string]any{
			"group_id": groupID, "account": memberAccount,
			"nickname": "队长", "level_id": "vip1",
		})
	}, func() bool {
		view, ok := memberView()
		if !ok {
			return false
		}
		nickname, levelID := memberProfile(view)
		return nickname == "队长" && levelID == "vip1"
	})
	waitFor(t, eventWait, func() bool { return logB.has("group.memberProfileChanged") })

	// 成员改自己称呼无需管理员，管理员端同样收到同步帧。
	retryControlFrame(t, func() {
		call(t, gwB, "group.setMemberProfile", map[string]any{
			"group_id": groupID, "account": memberAccount, "nickname": "小名",
		})
	}, func() bool {
		data, gerr := gwA.Handle(context.Background(), "group.members",
			json.RawMessage(mustJSON(map[string]any{"group_id": groupID})))
		if gerr != nil {
			return false
		}
		view := data.(map[string]any)
		for _, item := range view["members"].([]map[string]any) {
			if item["account"] == base64.RawURLEncoding.EncodeToString(appB.Account().Pub()) {
				return item["nickname"] == "小名"
			}
		}
		return false
	})

	// 关闭等级后成员等级 ID 被清空，并通过控制帧同步。
	retryControlFrame(t, func() {
		call(t, gwA, "group.setLevelConfig", map[string]any{
			"group_id": groupID, "enabled": false, "levels": []any{},
		})
	}, func() bool {
		view, ok := memberView()
		if !ok || view["level_enabled"] != false {
			return false
		}
		_, levelID := memberProfile(view)
		return levelID == ""
	})

	// 全部控制帧都不产生聊天气泡。
	listed, ok := call(t, gwB, "msg.list", map[string]any{
		"conversation_id": "group:" + groupID,
		"limit":           10,
	}).(map[string]any)
	if !ok {
		t.Fatal("msg.list 返回值不是对象")
	}
	if items, _ := listed["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("控制帧不应落消息库，实际 %d 条", len(items))
	}
}

func mustJSON(v any) string {
	raw, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(raw)
}
