package coreapp

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sync"
	"testing"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/group"
)

// TestGroupAnnouncementEndToEnd 验收 P6-26 群公告端到端链路：
// 管理员设置公告后本机落库并广播控制帧；成员收到帧更新本机公告、
// 发出 group.announcement 事件，且不产生聊天气泡；非管理员不能设置公告。
func TestGroupAnnouncementEndToEnd(t *testing.T) {
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

	// 先建立单聊连接，群广播沿现有连接到达成员。
	call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "connect first",
	})

	created, ok := call(t, gwA, "group.create", map[string]any{
		"title":   "公告群",
		"members": []string{hex.EncodeToString(appB.Account().Pub())},
	}).(map[string]any)
	if !ok {
		t.Fatal("group.create 返回值不是对象")
	}
	groupID, _ := created["group_id"].(string)
	if groupID == "" {
		t.Fatal("group.create 未返回 group_id")
	}

	// 等成员端密钥与群记录落库后再广播公告。
	memberAnnouncement := func() (string, bool) {
		raw, _ := json.Marshal(map[string]any{"group_id": groupID})
		data, gerr := gwB.Handle(context.Background(), "group.members", raw)
		if gerr != nil {
			return "", false
		}
		view, ok := data.(map[string]any)
		if !ok {
			return "", false
		}
		text, _ := view["announcement"].(string)
		return text, true
	}
	waitFor(t, propagationWait, func() bool {
		_, ok := memberAnnouncement()
		return ok
	})
	// 群记录落库先于成员订阅主题；GossipSub 不回放历史，未形成邻居就发布会丢帧。
	waitGroupTopicReady(t, appA, appB, groupID)

	const text = "本周六上午十点全员会议，请准时参加。"
	saved, ok := call(t, gwA, "group.setAnnouncement", map[string]any{
		"group_id":     groupID,
		"announcement": text,
	}).(map[string]any)
	if !ok || saved["announcement"] != text {
		t.Fatalf("group.setAnnouncement 回包异常: %v", saved)
	}

	waitForDiag(t, propagationWait, func() bool {
		got, ok := memberAnnouncement()
		return ok && got == text
	}, func() string {
		got, ok := memberAnnouncement()
		return fmt.Sprintf("B公告=%q ok=%v B事件=%v %s", got, ok, logB.names(),
			groupDiag(appA, appB, groupID))
	})
	waitFor(t, eventWait, func() bool { return logB.has("group.announcement") })

	// 控制帧不产生聊天气泡。
	listed, ok := call(t, gwB, "msg.list", map[string]any{
		"conversation_id": "group:" + groupID,
		"limit":           10,
	}).(map[string]any)
	if !ok {
		t.Fatal("msg.list 返回值不是对象")
	}
	if items, _ := listed["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("群公告不应落消息库，实际 %d 条", len(items))
	}

	// 管理员端与本机记录一致。
	if viewA, ok := call(t, gwA, "group.members", map[string]any{"group_id": groupID}).(map[string]any); !ok ||
		viewA["announcement"] != text {
		t.Fatalf("管理员端公告不一致: %v", viewA)
	}

	// 普通成员不能设置公告。
	if gerr := callErr(t, gwB, "group.setAnnouncement", map[string]any{
		"group_id":     groupID,
		"announcement": "越权公告",
	}); gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非管理员期望 INVALID_ARG，实际 %v", gerr)
	}
}
