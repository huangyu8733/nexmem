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
	"time"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/gateway"
)

// TestGroupGatewayInviteAndRemove 验收 P4-10 群成员管理：
// 管理员经网关邀请新成员、移除成员并轮换密钥；
// 重复邀请、移出自己等非法操作统一返回 INVALID_ARG。
func TestGroupGatewayInviteAndRemove(t *testing.T) {
	ctx := context.Background()
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	admin := newKeyTestNode(t, mn, cluster)
	m1 := newKeyTestNode(t, mn, cluster)
	m2 := newKeyTestNode(t, mn, cluster)
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	nodes := []*keyTestNode{admin, m1, m2}
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
	g := gateway.New()
	if err := Bind(g, &Gateway{
		Service: func() *Service { return admin.svc },
		Resolve: resolve,
	}); err != nil {
		t.Fatalf("注册群聊网关: %v", err)
	}

	encode := func(account []byte) string {
		return base64.RawURLEncoding.EncodeToString(account)
	}
	created, gerr := g.Handle(ctx, "group.create",
		json.RawMessage(fmt.Sprintf(`{"title":"成员管理群","members":["%s"]}`, encode(m1.account.Pub()))))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	groupID, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitKeyVersion(t, m1.svc, groupID, KeyVersionInitial)

	// 邀请 m2：沿用当前版本密钥，成员表同步为 3 人。
	invited, gerr := g.Handle(ctx, "group.invite",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s","account":"%s"}`, groupIDText, encode(m2.account.Pub()))))
	if gerr != nil {
		t.Fatalf("group.invite: %v", gerr)
	}
	inviteView := invited.(map[string]any)
	if v := inviteView["key_version"].(int); v != int(KeyVersionInitial) {
		t.Fatalf("邀请后密钥版本 %d，期望 %d", v, KeyVersionInitial)
	}
	if failed := inviteView["failed"].(int); failed != 0 {
		t.Fatalf("邀请时密钥投递失败数 %d，期望 0", failed)
	}
	waitKeyVersion(t, m2.svc, groupID, KeyVersionInitial)
	if list, err := admin.dao.ListMembers(ctx, groupID); err != nil || len(list) != 3 {
		t.Fatalf("邀请后成员表 %d 条（err=%v），期望 3", len(list), err)
	}
	if _, gerr := g.Handle(ctx, "group.invite",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s","account":"%s"}`, groupIDText, encode(m2.account.Pub())))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("重复邀请期望 INVALID_ARG，实际 %v", gerr)
	}

	// 移除 m1：密钥轮换到 v2，只有 admin 与 m2 收到新版本。
	removed, gerr := g.Handle(ctx, "group.remove",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s","account":"%s"}`, groupIDText, encode(m1.account.Pub()))))
	if gerr != nil {
		t.Fatalf("group.remove: %v", gerr)
	}
	removeView := removed.(map[string]any)
	if v := removeView["key_version"].(int); v != int(KeyVersionInitial)+1 {
		t.Fatalf("移除后密钥版本 %d，期望 %d", v, int(KeyVersionInitial)+1)
	}
	if failed := removeView["failed"].(int); failed != 0 {
		t.Fatalf("移除时密钥投递失败数 %d，期望 0", failed)
	}
	waitKeyVersion(t, admin.svc, groupID, KeyVersionInitial+1)
	waitKeyVersion(t, m2.svc, groupID, KeyVersionInitial+1)
	if v, _, ok := m1.svc.keys.Latest(groupID); !ok || v != KeyVersionInitial {
		t.Fatalf("被移除成员的密钥版本 %d（ok=%v），期望仍为 %d", v, ok, KeyVersionInitial)
	}
	if list, err := admin.dao.ListMembers(ctx, groupID); err != nil || len(list) != 2 {
		t.Fatalf("移除后成员表 %d 条（err=%v），期望 2", len(list), err)
	}

	// 移除已不在群的成员 / 移除管理员本人都是参数错误。
	if _, gerr := g.Handle(ctx, "group.remove",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s","account":"%s"}`, groupIDText, encode(m1.account.Pub())))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("移除非成员期望 INVALID_ARG，实际 %v", gerr)
	}
	if _, gerr := g.Handle(ctx, "group.remove",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s","account":"%s"}`, groupIDText, encode(admin.account.Pub())))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("移除管理员本人期望 INVALID_ARG，实际 %v", gerr)
	}
}

// TestGroupGatewayList 验收 P4-13 通讯录群聊分组：
// group.list 返回本机全部群（按群名排序）、成员数、密钥版本与本人角色；
// 普通成员视角为 member、管理员为 admin，参数不是对象时返回 INVALID_ARG。
func TestGroupGatewayList(t *testing.T) {
	ctx := context.Background()
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	admin := newKeyTestNode(t, mn, cluster)
	m1 := newKeyTestNode(t, mn, cluster)
	m2 := newKeyTestNode(t, mn, cluster)
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	nodes := []*keyTestNode{admin, m1, m2}
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
	g := newGateway(admin.svc)
	encode := func(account []byte) string {
		return base64.RawURLEncoding.EncodeToString(account)
	}
	create := func(title string, member []byte) string {
		created, gerr := g.Handle(ctx, "group.create",
			json.RawMessage(fmt.Sprintf(`{"title":"%s","members":["%s"]}`, title, encode(member))))
		if gerr != nil {
			t.Fatalf("group.create %s: %v", title, gerr)
		}
		return created.(map[string]any)["group_id"].(string)
	}
	alphaID := create("Alpha", m1.account.Pub())
	betaID := create("Beta", m2.account.Pub())
	alpha, err := parseGroupID(alphaID)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitGroupKey(t, m1.svc, alpha)

	listed, gerr := g.Handle(ctx, "group.list", json.RawMessage(`{}`))
	if gerr != nil {
		t.Fatalf("group.list: %v", gerr)
	}
	items := listed.(map[string]any)["items"].([]map[string]any)
	if len(items) != 2 {
		t.Fatalf("群列表 %d 条，期望 2", len(items))
	}
	first := items[0]
	if first["title"] != "Alpha" || items[1]["title"] != "Beta" {
		t.Fatalf("群列表顺序 %v / %v，期望按群名升序", first["title"], items[1]["title"])
	}
	if first["group_id"] != alphaID {
		t.Fatalf("群 ID %v，期望 %s", first["group_id"], alphaID)
	}
	if n := first["member_count"].(int); n != 2 {
		t.Fatalf("成员数 %d，期望 2", n)
	}
	if first["role"] != "admin" {
		t.Fatalf("管理员角色 %v，期望 admin", first["role"])
	}
	if v := first["key_version"].(int); v != int(KeyVersionInitial) {
		t.Fatalf("密钥版本 %d，期望 %d", v, KeyVersionInitial)
	}
	if first["storage_configured"].(bool) {
		t.Fatal("新建群不应预置群盘配置")
	}
	if betaID == "" {
		t.Fatal("第二个群 ID 不能为空")
	}

	// 普通成员视角：同一群的角色为 member（等本地群记录落库，密钥先于落库入环）。
	memberGateway := newGateway(m1.svc)
	var memberItems []map[string]any
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		view, gerr := memberGateway.Handle(ctx, "group.list", json.RawMessage(`{}`))
		if gerr != nil {
			t.Fatalf("成员 group.list: %v", gerr)
		}
		memberItems = view.(map[string]any)["items"].([]map[string]any)
		if len(memberItems) == 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(memberItems) != 1 || memberItems[0]["role"] != "member" {
		t.Fatalf("成员群列表 %v，期望 1 条且角色为 member", memberItems)
	}

	// 非对象参数与未启动统一返回契约错误。
	if _, gerr := g.Handle(ctx, "group.list", json.RawMessage(`[]`)); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非对象参数期望 INVALID_ARG，实际 %v", gerr)
	}
	stopped := gateway.New()
	if err := Bind(stopped, &Gateway{Service: func() *Service { return nil }}); err != nil {
		t.Fatalf("注册未启动网关: %v", err)
	}
	if _, gerr := stopped.Handle(ctx, "group.list", json.RawMessage(`{}`)); gerr == nil ||
		gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动期望 NOT_STARTED，实际 %v", gerr)
	}
}

// waitKeyVersion 等待节点持有指定版本的群密钥。
func waitKeyVersion(t *testing.T, svc *Service, groupID []byte, want uint32) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if version, _, ok := svc.keys.Latest(groupID); ok && version == want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("群 %x 的 v%d 密钥未在超时内到达", groupID, want)
}

// TestGroupGatewayInvitePendingNotice 验收管理员主动拉人的“待同步”语义：
// 目标账号档案/XPub 暂不可用时不再直接返回拉人失败，成员仍写入本机成员表，
// 并通过 OnInvite 给对方投递显式邀请通知。
func TestGroupGatewayInvitePendingNotice(t *testing.T) {
	ctx := context.Background()
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	admin := newKeyTestNode(t, mn, cluster)
	m2 := newKeyTestNode(t, mn, cluster)
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}

	var noticeAccount []byte
	var noticeTitle string
	g := gateway.New()
	if err := Bind(g, &Gateway{
		Service: func() *Service { return admin.svc },
		Resolve: func(_ context.Context, accountPub []byte) (KeyTarget, error) {
			if bytes.Equal(accountPub, m2.account.Pub()) {
				return KeyTarget{}, errors.New("档案缺少账号 X25519 公钥")
			}
			if bytes.Equal(accountPub, admin.account.Pub()) {
				return KeyTarget{
					PeerID: admin.host.ID(),
					Addrs:  admin.host.Addrs(),
					XPub:   admin.account.XPub(),
				}, nil
			}
			return KeyTarget{}, errors.New("未知成员")
		},
		OnInvite: func(_ context.Context, _ []byte, accountPub []byte, title string) (bool, error) {
			noticeAccount = append([]byte(nil), accountPub...)
			noticeTitle = title
			return true, nil
		},
	}); err != nil {
		t.Fatalf("注册群聊网关: %v", err)
	}

	created, gerr := g.Handle(ctx, "group.create",
		json.RawMessage(`{"title":"待同步群","members":[]}`))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	invited, gerr := g.Handle(ctx, "group.invite",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s","account":"%s"}`,
			groupIDText, base64.RawURLEncoding.EncodeToString(m2.account.Pub()))))
	if gerr != nil {
		t.Fatalf("目标待同步时 group.invite 不应直接失败: %v", gerr)
	}
	view := invited.(map[string]any)
	if view["pending"] != true {
		t.Fatalf("pending=%v，期望 true", view["pending"])
	}
	if view["invite_sent"] != true {
		t.Fatalf("invite_sent=%v，期望 true", view["invite_sent"])
	}
	if failed := view["failed"].(int); failed == 0 {
		t.Fatalf("failed=%d，期望密钥投递记为待补发", failed)
	}
	if reason, ok := view["delivery_error"].(string); !ok || !strings.Contains(reason, "X25519") {
		t.Fatalf("delivery_error=%v，期望包含 X25519 原因", view["delivery_error"])
	}
	if !bytes.Equal(noticeAccount, m2.account.Pub()) || noticeTitle != "待同步群" {
		t.Fatalf("邀请通知目标=%x 标题=%q，期望 %x / 待同步群",
			noticeAccount, noticeTitle, m2.account.Pub())
	}
	gid, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	list, err := admin.dao.ListMembers(ctx, gid)
	if err != nil || len(list) != 2 {
		t.Fatalf("待同步时成员表 %d 条（err=%v），期望 2", len(list), err)
	}
}

// TestGroupGatewayCreateMembersAndSend 验收 P1-20 群聊网关装配：
// group.create 建群并分发密钥，group.members 读出成员与群盘状态，
// dm.sendGroupText 广播成功且如实上报未配置群盘。
func TestGroupGatewayCreateMembersAndSend(t *testing.T) {
	ctx := context.Background()
	mn := mocknet.New()
	defer mn.Close()

	cluster := &keyCluster{xpubs: make(map[string][]byte)}
	admin := newKeyTestNode(t, mn, cluster)
	m1 := newKeyTestNode(t, mn, cluster)
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("建立链路: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立连接: %v", err)
	}

	g := gateway.New()
	resolve := func(_ context.Context, accountPub []byte) (KeyTarget, error) {
		if !bytes.Equal(accountPub, m1.account.Pub()) {
			return KeyTarget{}, errors.New("未知成员")
		}
		return KeyTarget{
			PeerID: m1.host.ID(),
			Addrs:  m1.host.Addrs(),
			XPub:   m1.account.XPub(),
		}, nil
	}
	if err := Bind(g, &Gateway{
		Service: func() *Service { return admin.svc },
		Resolve: resolve,
	}); err != nil {
		t.Fatalf("注册群聊网关: %v", err)
	}

	member := base64.RawURLEncoding.EncodeToString(m1.account.Pub())
	created, gerr := g.Handle(ctx, "group.create",
		json.RawMessage(fmt.Sprintf(`{"title":"研发群","members":["%s"]}`, member)))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	if failed := created.(map[string]any)["failed"].(int); failed != 0 {
		t.Fatalf("密钥投递失败数 %d，期望 0", failed)
	}
	groupID, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitGroupKey(t, m1.svc, groupID)

	members, gerr := g.Handle(ctx, "group.members",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
	if gerr != nil {
		t.Fatalf("group.members: %v", gerr)
	}
	view := members.(map[string]any)
	if view["title"] != "研发群" {
		t.Fatalf("群名称 %v，期望 研发群", view["title"])
	}
	if view["storage_configured"].(bool) {
		t.Fatal("新建群不应预置群盘配置")
	}
	if n := len(view["members"].([]map[string]any)); n != 2 {
		t.Fatalf("成员数 %d，期望 2", n)
	}

	sent, gerr := g.Handle(ctx, "dm.sendGroupText",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s","text":"大家好"}`, groupIDText)))
	if gerr != nil {
		t.Fatalf("dm.sendGroupText: %v", gerr)
	}
	sentView := sent.(map[string]any)
	if sentView["msg_uuid"].(string) == "" {
		t.Fatal("msg_uuid 不能为空")
	}
	if sentView["stored"].(bool) {
		t.Fatal("未配置群盘时 stored 应为 false")
	}
	if sentView["storage_error"].(string) == "" {
		t.Fatal("未配置群盘时应给出 storage_error")
	}

	// 非法群 ID 属于参数错误。
	_, gerr = g.Handle(ctx, "group.members", json.RawMessage(`{"group_id":"not-a-group"}`))
	if gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非法群 ID 期望 INVALID_ARG，实际 %v", gerr)
	}

	// 未启动时统一返回 NOT_STARTED。
	stopped := gateway.New()
	if err := Bind(stopped, &Gateway{Service: func() *Service { return nil }}); err != nil {
		t.Fatalf("注册未启动网关: %v", err)
	}
	_, gerr = stopped.Handle(ctx, "group.members",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
	if gerr == nil || gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动期望 NOT_STARTED，实际 %v", gerr)
	}
}
