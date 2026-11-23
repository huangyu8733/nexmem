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

// TestGroupGatewayAlias 验收 P6-27 群备注：
// 任意成员可设置/清除本机备注，备注回显在 group.list / group.members，
// 但不会同步给其他成员；超限与缺失参数统一返回 INVALID_ARG。
func TestGroupGatewayAlias(t *testing.T) {
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
		json.RawMessage(fmt.Sprintf(`{"title":"备注群","members":["%s"]}`, memberAccount)))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	groupID, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitGroupKey(t, member.svc, groupID)

	setAlias := func(gw *gateway.Gateway, alias string) (any, *gateway.Error) {
		params, _ := json.Marshal(map[string]any{
			"group_id": groupIDText,
			"alias":    alias,
		})
		return gw.Handle(ctx, "group.setAlias", params)
	}

	const alias = "值班通知群"
	saved, gerr := setAlias(memberGW, alias)
	if gerr != nil {
		t.Fatalf("成员设置群备注: %v", gerr)
	}
	if got := saved.(map[string]any)["alias"]; got != alias {
		t.Fatalf("回包备注 %v，期望 %q", got, alias)
	}
	if got, err := member.dao.GetGroupAlias(ctx, groupID); err != nil || got != alias {
		t.Fatalf("本机备注 %q（err=%v），期望 %q", got, err, alias)
	}

	// 成员视角回显备注；管理员视角不受影响，证明备注不上行。
	view, gerr := memberGW.Handle(ctx, "group.members",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
	if gerr != nil {
		t.Fatalf("group.members: %v", gerr)
	}
	if got := view.(map[string]any)["alias"]; got != alias {
		t.Fatalf("group.members 备注 %v，期望 %q", got, alias)
	}
	listed, gerr := memberGW.Handle(ctx, "group.list", json.RawMessage(`{}`))
	if gerr != nil {
		t.Fatalf("group.list: %v", gerr)
	}
	items := listed.(map[string]any)["items"].([]map[string]any)
	if len(items) != 1 || items[0]["alias"] != alias {
		t.Fatalf("group.list 备注不一致: %v", items)
	}
	if got, err := admin.dao.GetGroupAlias(ctx, groupID); err != nil || got != "" {
		t.Fatalf("管理员不应看到成员本机备注: %q (err=%v)", got, err)
	}

	// 超过 32 字必须被拒绝，提示文案固定。
	if _, gerr := setAlias(memberGW, strings.Repeat("长", MaxGroupAliasRunes+1)); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg || !strings.Contains(gerr.Message, "群备注最多 32 字") {
		t.Fatalf("超限期望 INVALID_ARG 与固定提示，实际 %v", gerr)
	}

	// 缺失 alias 由契约层参数校验拦截。
	if _, gerr := memberGW.Handle(ctx, "group.setAlias",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺失 alias 期望 INVALID_ARG，实际 %v", gerr)
	}

	// 不存在的群返回 INVALID_ARG。
	missingParams, _ := json.Marshal(map[string]any{
		"group_id": "fffeeeddccbbaa998877665544332211",
		"alias":    "x",
	})
	if _, gerr := memberGW.Handle(ctx, "group.setAlias", missingParams); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("不存在的群期望 INVALID_ARG，实际 %v", gerr)
	}

	// 空串表示清除备注。
	if _, gerr := setAlias(memberGW, ""); gerr != nil {
		t.Fatalf("清除群备注: %v", gerr)
	}
	if got, err := member.dao.GetGroupAlias(ctx, groupID); err != nil || got != "" {
		t.Fatalf("备注应已清除: %q (err=%v)", got, err)
	}
}
