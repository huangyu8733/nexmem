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

// TestGroupLevelAndMemberProfileGateway 覆盖本群称呼与群等级的服务端语义：
// 管理员配置等级、成员改自己称呼、改他人/自提等级需要管理员、等级关闭清空、
// group.members 输出新字段，以及入站控制帧的管理员/本人校验。
func TestGroupLevelAndMemberProfileGateway(t *testing.T) {
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
				return KeyTarget{PeerID: n.host.ID(), Addrs: n.host.Addrs(), XPub: n.account.XPub()}, nil
			}
		}
		return KeyTarget{}, errors.New("未知成员")
	}
	newGateway := func(svc *Service) *gateway.Gateway {
		g := gateway.New()
		if err := Bind(g, &Gateway{Service: func() *Service { return svc }, Resolve: resolve}); err != nil {
			t.Fatalf("注册群聊网关: %v", err)
		}
		return g
	}
	adminGW, memberGW := newGateway(admin.svc), newGateway(member.svc)

	accountText := func(pub []byte) string { return base64.RawURLEncoding.EncodeToString(pub) }
	memberAccount := accountText(member.account.Pub())
	created, gerr := adminGW.Handle(ctx, "group.create",
		json.RawMessage(fmt.Sprintf(`{"title":"等级群","members":["%s"]}`, memberAccount)))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	groupID, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitGroupKey(t, member.svc, groupID)

	strPtr := func(s string) *string { return &s }
	setLevels := func(gw *gateway.Gateway, enabled bool, levels []GroupLevel) (any, *gateway.Error) {
		params, _ := json.Marshal(map[string]any{
			"group_id": groupIDText, "enabled": enabled, "levels": levels,
		})
		return gw.Handle(ctx, "group.setLevelConfig", params)
	}
	setProfile := func(gw *gateway.Gateway, account string, nickname, levelID *string) (any, *gateway.Error) {
		params := map[string]any{"group_id": groupIDText, "account": account}
		if nickname != nil {
			params["nickname"] = *nickname
		}
		if levelID != nil {
			params["level_id"] = *levelID
		}
		raw, _ := json.Marshal(params)
		return gw.Handle(ctx, "group.setMemberProfile", raw)
	}
	view := func(gw *gateway.Gateway) map[string]any {
		data, gerr := gw.Handle(ctx, "group.members",
			json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
		if gerr != nil {
			t.Fatalf("group.members: %v", gerr)
		}
		return data.(map[string]any)
	}
	findMember := func(v map[string]any, account string) map[string]any {
		for _, item := range v["members"].([]map[string]any) {
			if item["account"] == account {
				return item
			}
		}
		t.Fatalf("成员 %s 不在 group.members 中: %v", account, v)
		return nil
	}

	// 新群默认关闭等级，成员资料为空，且输出新字段。
	for _, gw := range []*gateway.Gateway{adminGW, memberGW} {
		v := view(gw)
		if v["level_enabled"] != false {
			t.Fatalf("新群等级应默认关闭: %v", v["level_enabled"])
		}
		if levels, ok := v["levels"].([]GroupLevel); !ok || len(levels) != 0 {
			t.Fatalf("新群等级列表应为空数组: %#v", v["levels"])
		}
		for _, item := range v["members"].([]map[string]any) {
			if item["nickname"] != "" || item["level_id"] != "" {
				t.Fatalf("新群成员资料应为空: %v", item)
			}
		}
	}

	icon := testLevelIcon(t, LevelIconSize)
	levels := []GroupLevel{{ID: "vip1", Name: "贵宾", IconB64: icon}}
	saved, gerr := setLevels(adminGW, true, levels)
	if gerr != nil || saved.(map[string]any)["enabled"] != true {
		t.Fatalf("管理员设置等级失败: %v / %v", saved, gerr)
	}
	checkLevels := func(gw *gateway.Gateway) {
		v := view(gw)
		if v["level_enabled"] != true {
			t.Fatalf("等级开关未生效: %v", v)
		}
		got := v["levels"].([]GroupLevel)
		if len(got) != 1 || got[0].ID != "vip1" || got[0].Name != "贵宾" || got[0].IconB64 != icon {
			t.Fatalf("等级列表不一致: %+v", got)
		}
	}
	checkLevels(adminGW)
	// 成员端按控制帧应用后才能看到新配置（coreapp 中由 onGroupMessage 完成）。
	if applied, err := member.svc.ApplyLevelConfig(ctx, groupID, admin.account.Pub(),
		LevelConfig{Enabled: true, Levels: levels}); err != nil || !applied {
		t.Fatalf("成员应用等级帧失败: %v / %v", applied, err)
	}
	checkLevels(memberGW)

	// 数量超限、非管理员设置等级都返回 INVALID_ARG。
	tooMany := make([]GroupLevel, 0, MaxLevels+1)
	for i := 0; i <= MaxLevels; i++ {
		tooMany = append(tooMany, GroupLevel{ID: fmt.Sprintf("lv%d", i), Name: "等级"})
	}
	if _, gerr := setLevels(adminGW, true, tooMany); gerr == nil || gerr.Code != gateway.CodeInvalidArg ||
		!strings.Contains(gerr.Message, ErrLevelConfigTooMany.Error()) {
		t.Fatalf("13 项等级期望 INVALID_ARG, 实际 %v", gerr)
	}
	if _, gerr := setLevels(memberGW, true, levels); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非管理员设置等级期望 INVALID_ARG, 实际 %v", gerr)
	}

	// 成员可以改自己的称呼；但设置非空等级 ID 仍需管理员。
	if _, gerr := setProfile(memberGW, memberAccount, strPtr("小名"), nil); gerr != nil {
		t.Fatalf("成员改自己称呼: %v", gerr)
	}
	if got := findMember(view(memberGW), memberAccount)["nickname"]; got != "小名" {
		t.Fatalf("本机称呼未生效: %v", got)
	}
	if applied, err := admin.svc.ApplyMemberProfile(ctx, groupID, member.account.Pub(),
		MemberProfile{Account: memberAccount, Nickname: "小名", LevelID: ""}); err != nil || !applied {
		t.Fatalf("管理员应用成员称呼帧失败: %v / %v", applied, err)
	}
	if got := findMember(view(adminGW), memberAccount)["nickname"]; got != "小名" {
		t.Fatalf("管理员视角称呼未生效: %v", got)
	}
	if _, gerr := setProfile(memberGW, memberAccount, nil, strPtr("vip1")); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("成员自提等级期望 INVALID_ARG, 实际 %v", gerr)
	}
	if _, gerr := setProfile(memberGW, accountText(admin.account.Pub()), strPtr("越权"), nil); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("成员改他人称呼期望 INVALID_ARG, 实际 %v", gerr)
	}

	// 管理员可以改任意成员的称呼与等级；空串表示清除。
	if _, gerr := setProfile(adminGW, memberAccount, strPtr("队长"), strPtr("vip1")); gerr != nil {
		t.Fatalf("管理员设置成员资料: %v", gerr)
	}
	checkProfile := func(gw *gateway.Gateway) {
		m := findMember(view(gw), memberAccount)
		if m["nickname"] != "队长" || m["level_id"] != "vip1" {
			t.Fatalf("管理员设置的资料未生效: %v", m)
		}
	}
	checkProfile(adminGW)

	// 管理员给自己设置等级走同一条权限判断，不能被 self 分支误拒。
	adminAccount := accountText(admin.account.Pub())
	if saved, gerr := setProfile(adminGW, adminAccount, nil, strPtr("vip1")); gerr != nil ||
		saved.(map[string]any)["level_id"] != "vip1" {
		t.Fatalf("管理员给自己设置等级失败: %v / %v", saved, gerr)
	}
	if got := findMember(view(adminGW), adminAccount)["level_id"]; got != "vip1" {
		t.Fatalf("管理员自身等级未生效: %v", got)
	}

	if applied, err := member.svc.ApplyMemberProfile(ctx, groupID, admin.account.Pub(),
		MemberProfile{Account: memberAccount, Nickname: "队长", LevelID: "vip1"}); err != nil || !applied {
		t.Fatalf("成员应用资料帧失败: %v / %v", applied, err)
	}
	checkProfile(memberGW)
	if _, gerr := setProfile(adminGW, memberAccount, strPtr(strings.Repeat("长", MaxNicknameRunes+1)), nil); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("超长称呼期望 INVALID_ARG, 实际 %v", gerr)
	}
	if _, gerr := setProfile(adminGW, memberAccount, nil, strPtr("missing")); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg || !strings.Contains(gerr.Message, ErrLevelNotFound.Error()) {
		t.Fatalf("不存在的等级 ID 期望 INVALID_ARG, 实际 %v", gerr)
	}
	if saved, gerr := setProfile(adminGW, memberAccount, strPtr(""), strPtr("")); gerr != nil ||
		saved.(map[string]any)["nickname"] != "" || saved.(map[string]any)["level_id"] != "" {
		t.Fatalf("空串清除失败: %v / %v", saved, gerr)
	}

	// 关闭等级后，全部成员等级 ID 必须清空。
	if _, gerr := setProfile(adminGW, memberAccount, strPtr("队长"), strPtr("vip1")); gerr != nil {
		t.Fatalf("重新设置等级: %v", gerr)
	}
	if _, gerr := setLevels(adminGW, false, []GroupLevel{}); gerr != nil {
		t.Fatalf("关闭等级: %v", gerr)
	}
	checkDisabled := func(gw *gateway.Gateway) {
		v := view(gw)
		if v["level_enabled"] != false {
			t.Fatalf("等级关闭未生效: %v", v)
		}
		if got := findMember(v, memberAccount)["level_id"]; got != "" {
			t.Fatalf("关闭等级应清空成员等级 ID: %v", got)
		}
	}
	checkDisabled(adminGW)
	if applied, err := member.svc.ApplyLevelConfig(ctx, groupID, admin.account.Pub(),
		LevelConfig{Enabled: false, Levels: []GroupLevel{}}); err != nil || !applied {
		t.Fatalf("成员应用关闭等级帧失败: %v / %v", applied, err)
	}
	checkDisabled(memberGW)

	// 入站帧的权限校验：非管理员不能改配置或他人资料，本人帧不能自提等级。
	if applied, err := member.svc.ApplyLevelConfig(ctx, groupID, member.account.Pub(),
		LevelConfig{Enabled: true, Levels: levels}); err != nil || applied {
		t.Fatalf("非管理员等级帧应丢弃: %v / %v", applied, err)
	}
	selfEscalate := MemberProfile{Account: memberAccount, Nickname: "自提", LevelID: "vip1"}
	if applied, err := member.svc.ApplyMemberProfile(ctx, groupID, member.account.Pub(), selfEscalate); err != nil || applied {
		t.Fatalf("本人自提等级帧应丢弃: %v / %v", applied, err)
	}
	otherFrame := MemberProfile{Account: accountText(admin.account.Pub()), Nickname: "越权", LevelID: ""}
	if applied, err := member.svc.ApplyMemberProfile(ctx, groupID, member.account.Pub(), otherFrame); err != nil || applied {
		t.Fatalf("非管理员改他人帧应丢弃: %v / %v", applied, err)
	}
	selfNickname := MemberProfile{Account: memberAccount, Nickname: "本人改名", LevelID: ""}
	if applied, err := member.svc.ApplyMemberProfile(ctx, groupID, member.account.Pub(), selfNickname); err != nil || !applied {
		t.Fatalf("本人改称呼帧应接受: %v / %v", applied, err)
	}
	if got := findMember(view(memberGW), memberAccount)["nickname"]; got != "本人改名" {
		t.Fatalf("本人改名帧未生效: %v", got)
	}
	adminFrame := MemberProfile{Account: memberAccount, Nickname: "管理员改名", LevelID: ""}
	if applied, err := member.svc.ApplyMemberProfile(ctx, groupID, admin.account.Pub(), adminFrame); err != nil || !applied {
		t.Fatalf("管理员资料帧应接受: %v / %v", applied, err)
	}
	if got := findMember(view(memberGW), memberAccount)["nickname"]; got != "管理员改名" {
		t.Fatalf("管理员资料帧未生效: %v", got)
	}
}
