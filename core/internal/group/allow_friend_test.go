package group

// 「允许成员互加好友」群设置回归：默认关闭、仅管理员可切换、
// 控制帧只接受管理员、成员侧本地值随生效设置更新。

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"testing"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/gateway"
)

func TestAllowFriendAddNoticeRoundTrip(t *testing.T) {
	for _, want := range []bool{false, true} {
		frame := EncodeAllowFriendAddNotice(want)
		got, ok := ParseAllowFriendAddNotice([]byte(frame))
		if !ok || got != want {
			t.Fatalf("控制帧 %q 解析为 %v/%v，期望 %v/true", frame, got, ok, want)
		}
	}
	if _, ok := ParseAllowFriendAddNotice([]byte("普通群消息")); ok {
		t.Fatal("普通消息被误判为加好友开关控制帧")
	}
}

func TestGroupAllowFriendAddSetting(t *testing.T) {
	ctx := context.Background()
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	admin := newKeyTestNode(t, mn, cluster)
	member := newKeyTestNode(t, mn, cluster)
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	nodes := []*keyTestNode{admin, member}
	resolve := func(_ context.Context, accountPub []byte) (KeyTarget, error) {
		for _, n := range nodes {
			if bytes.Equal(accountPub, n.account.Pub()) {
				return KeyTarget{
					PeerID: n.host.ID(),
					Addrs:  n.host.Addrs(),
					XPub:   n.account.XPub(),
				}, nil
			}
		}
		return KeyTarget{}, fmt.Errorf("未知成员")
	}
	newGateway := func(svc *Service) *gateway.Gateway {
		g := gateway.New()
		if err := Bind(g, &Gateway{
			Service: func() *Service { return svc },
			Resolve: resolve,
		}); err != nil {
			t.Fatalf("注册群聊网关: %v", err)
		}
		return g
	}
	adminGW := newGateway(admin.svc)
	memberGW := newGateway(member.svc)

	memberAccount := base64.RawURLEncoding.EncodeToString(member.account.Pub())
	created, gerr := adminGW.Handle(ctx, "group.create",
		json.RawMessage(fmt.Sprintf(`{"title":"好友权限群","members":["%s"]}`, memberAccount)))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	groupID, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitGroupKey(t, member.svc, groupID)

	members := func(gw *gateway.Gateway) bool {
		view, gerr := gw.Handle(ctx, "group.members",
			json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
		if gerr != nil {
			t.Fatalf("group.members: %v", gerr)
		}
		value, ok := view.(map[string]any)["allow_friend_add"].(bool)
		if !ok {
			t.Fatalf("group.members 缺少 allow_friend_add: %+v", view)
		}
		return value
	}
	set := func(gw *gateway.Gateway, enabled bool) *gateway.Error {
		params, _ := json.Marshal(map[string]any{
			"group_id": groupIDText,
			"enabled":  enabled,
		})
		_, gerr := gw.Handle(ctx, "group.setAllowFriendAdd", params)
		return gerr
	}

	// 新群默认关闭，管理员与成员视角一致。
	if members(adminGW) || members(memberGW) {
		t.Fatal("新群允许加好友应默认关闭")
	}

	// 缺失参数与非管理员都不能改开关。
	_, gerr = adminGW.Handle(ctx, "group.setAllowFriendAdd",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
	if gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺失 enabled 期望 INVALID_ARG，实际 %v", gerr)
	}
	if gerr := set(memberGW, true); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非管理员改开关期望 INVALID_ARG，实际 %v", gerr)
	}

	// 管理员开启后本机立即生效，成员侧需应用管理员控制帧才生效。
	if gerr := set(adminGW, true); gerr != nil {
		t.Fatalf("管理员开启加好友: %v", gerr)
	}
	if !members(adminGW) {
		t.Fatal("管理员开启后本机设置应为 true")
	}
	if members(memberGW) {
		t.Fatal("成员未应用控制帧前不应自动开启")
	}
	applied, err := member.svc.ApplyAllowFriendAdd(ctx, groupID, admin.account.Pub(), true)
	if err != nil || !applied {
		t.Fatalf("应用管理员控制帧: applied=%v err=%v", applied, err)
	}
	if !members(memberGW) {
		t.Fatal("成员应用管理员控制帧后应为 true")
	}

	// 成员伪造的控制帧被忽略，管理员可关闭。
	if err := member.svc.dao.SetGroupAllowFriendAdd(ctx, groupID, false); err != nil {
		t.Fatalf("重置成员本地设置: %v", err)
	}
	applied, err = member.svc.ApplyAllowFriendAdd(ctx, groupID, member.account.Pub(), true)
	if err != nil || applied {
		t.Fatalf("非管理员控制帧应被忽略: applied=%v err=%v", applied, err)
	}
	if members(memberGW) {
		t.Fatal("非管理员控制帧不应改变成员本地设置")
	}
	if gerr := set(adminGW, false); gerr != nil {
		t.Fatalf("管理员关闭加好友: %v", gerr)
	}
	if members(adminGW) {
		t.Fatal("管理员关闭后本机设置应为 false")
	}
}
