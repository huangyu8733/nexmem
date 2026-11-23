package group

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/gateway"
)

// TestGroupGatewayAnnouncement 验收 P6-26 群公告：
// 管理员设置/清除公告、成员资料与群列表回显公告；
// 非管理员、超过 512 字与缺失参数统一返回 INVALID_ARG。
func TestGroupGatewayAnnouncement(t *testing.T) {
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
		return KeyTarget{}, errors.New("未知成员")
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
		json.RawMessage(fmt.Sprintf(`{"title":"公告群","members":["%s"]}`, memberAccount)))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	groupID, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitGroupKey(t, member.svc, groupID)

	const text = "本周六上午十点全员会议，请准时参加。"
	setAnnouncement := func(gw *gateway.Gateway, announcement string) (any, *gateway.Error) {
		params, _ := json.Marshal(map[string]any{
			"group_id":     groupIDText,
			"announcement": announcement,
		})
		return gw.Handle(ctx, "group.setAnnouncement", params)
	}

	saved, gerr := setAnnouncement(adminGW, text)
	if gerr != nil {
		t.Fatalf("group.setAnnouncement: %v", gerr)
	}
	if got := saved.(map[string]any)["announcement"]; got != text {
		t.Fatalf("回包公告 %v，期望 %q", got, text)
	}
	if got, err := admin.dao.GetGroupAnnouncement(ctx, groupID); err != nil || got != text {
		t.Fatalf("本机公告 %q（err=%v），期望 %q", got, err, text)
	}

	view, gerr := adminGW.Handle(ctx, "group.members",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
	if gerr != nil {
		t.Fatalf("group.members: %v", gerr)
	}
	if got := view.(map[string]any)["announcement"]; got != text {
		t.Fatalf("group.members 公告 %v，期望 %q", got, text)
	}
	listed, gerr := adminGW.Handle(ctx, "group.list", json.RawMessage(`{}`))
	if gerr != nil {
		t.Fatalf("group.list: %v", gerr)
	}
	items := listed.(map[string]any)["items"].([]map[string]any)
	if len(items) != 1 || items[0]["announcement"] != text {
		t.Fatalf("group.list 公告不一致: %v", items)
	}

	// 普通成员不能设置公告。
	if _, gerr := setAnnouncement(memberGW, "越权公告"); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非管理员期望 INVALID_ARG，实际 %v", gerr)
	}

	// 超过 512 字必须被拒绝，提示文案固定。
	if _, gerr := setAnnouncement(adminGW, strings.Repeat("长", MaxAnnouncementRunes+1)); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg || !strings.Contains(gerr.Message, "群公告最多 512 字") {
		t.Fatalf("超限期望 INVALID_ARG 与固定提示，实际 %v", gerr)
	}

	// 缺失 announcement 由契约层参数校验拦截。
	if _, gerr := adminGW.Handle(ctx, "group.setAnnouncement",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺失 announcement 期望 INVALID_ARG，实际 %v", gerr)
	}

	// 空串表示清除公告。
	if _, gerr := setAnnouncement(adminGW, ""); gerr != nil {
		t.Fatalf("清除公告: %v", gerr)
	}
	if got, err := admin.dao.GetGroupAnnouncement(ctx, groupID); err != nil || got != "" {
		t.Fatalf("公告应已清除: %q (err=%v)", got, err)
	}
}
