package coreapp

// 「允许群成员互加好友」端到端验收：管理员开启后本机落库并经控制帧同步给成员，
// 成员发出 group.allowFriendAddChanged 事件且不产生聊天气泡；普通成员无法修改。

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"sync"
	"testing"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/group"
)

func TestGroupAllowFriendAddEndToEnd(t *testing.T) {
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
			acc := app.Account()
			if acc != nil && string(acc.Pub()) == string(accountPub) {
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

	call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "connect first",
	})
	created, ok := call(t, gwA, "group.create", map[string]any{
		"title":   "加好友权限群",
		"members": []string{hex.EncodeToString(appB.Account().Pub())},
	}).(map[string]any)
	if !ok {
		t.Fatal("group.create 返回值不是对象")
	}
	groupID, _ := created["group_id"].(string)
	if groupID == "" {
		t.Fatal("group.create 未返回 group_id")
	}

	allowFriendAdd := func(gw *gateway.Gateway) (bool, bool) {
		raw, _ := json.Marshal(map[string]any{"group_id": groupID})
		data, gerr := gw.Handle(context.Background(), "group.members", raw)
		if gerr != nil {
			return false, false
		}
		view, ok := data.(map[string]any)
		if !ok {
			return false, false
		}
		enabled, ok := view["allow_friend_add"].(bool)
		return enabled, ok
	}
	waitFor(t, propagationWait, func() bool {
		_, ok := allowFriendAdd(gwB)
		return ok
	})
	if enabled, _ := allowFriendAdd(gwA); enabled {
		t.Fatal("新群加好友权限应默认关闭")
	}
	if enabled, _ := allowFriendAdd(gwB); enabled {
		t.Fatal("新群成员侧加好友权限应默认关闭")
	}

	saved, ok := call(t, gwA, "group.setAllowFriendAdd", map[string]any{
		"group_id": groupID,
		"enabled":  true,
	}).(map[string]any)
	if !ok || saved["enabled"] != true {
		t.Fatalf("group.setAllowFriendAdd 回包异常: %v", saved)
	}
	waitFor(t, propagationWait, func() bool {
		enabled, ok := allowFriendAdd(gwB)
		return ok && enabled
	})
	waitFor(t, eventWait, func() bool {
		return logB.has("group.allowFriendAddChanged")
	})

	listed, ok := call(t, gwB, "msg.list", map[string]any{
		"conversation_id": "group:" + groupID,
		"limit":           10,
	}).(map[string]any)
	if !ok {
		t.Fatal("msg.list 返回值不是对象")
	}
	if items, _ := listed["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("群设置控制帧不应落消息库，实际 %d 条", len(items))
	}

	if gerr := callErr(t, gwB, "group.setAllowFriendAdd", map[string]any{
		"group_id": groupID,
		"enabled":  true,
	}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非管理员期望 INVALID_ARG，实际 %v", gerr)
	}
}
