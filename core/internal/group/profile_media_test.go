package group

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"strings"
	"testing"

	mocknet "github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/gateway"
)

func testAvatarB64(t *testing.T) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, GroupAvatarSize, GroupAvatarSize))
	for y := 0; y < GroupAvatarSize; y++ {
		for x := 0; x < GroupAvatarSize; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x), G: uint8(y), B: 128, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 80}); err != nil {
		t.Fatalf("编码测试头像: %v", err)
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func TestGroupProfileMediaNotices(t *testing.T) {
	avatar := testAvatarB64(t)
	frame, err := EncodeGroupAvatarNotice(avatar)
	if err != nil {
		t.Fatalf("编码群头像控制帧: %v", err)
	}
	got, ok := ParseGroupAvatarNotice([]byte(frame))
	if !ok || got != avatar {
		t.Fatalf("群头像控制帧往返失败: ok=%v", ok)
	}
	if _, ok := ParseGroupAvatarNotice([]byte("普通群消息")); ok {
		t.Fatalf("普通消息不应解析为群头像")
	}
	if _, err := EncodeGroupAvatarNotice("!!!not-base64"); !errors.Is(err, ErrGroupAvatarInvalid) {
		t.Fatalf("非法头像期望 ErrGroupAvatarInvalid，实际 %v", err)
	}
	if _, ok := ParseGroupAvatarNotice([]byte(avatarNoticePrefix + "!!!")); ok {
		t.Fatalf("非法头像控制帧应被拒绝")
	}

	text := "这是一个测试群，欢迎交流。"
	frame, err = EncodeGroupDescriptionNotice(text)
	if err != nil {
		t.Fatalf("编码群介绍控制帧: %v", err)
	}
	got, ok = ParseGroupDescriptionNotice([]byte(frame))
	if !ok || got != text {
		t.Fatalf("群介绍控制帧往返失败: ok=%v", ok)
	}
	if _, err := EncodeGroupDescriptionNotice(strings.Repeat("长", MaxGroupDescriptionRunes+1)); !errors.Is(err, ErrGroupDescriptionTooLong) {
		t.Fatalf("超长介绍期望 ErrGroupDescriptionTooLong，实际 %v", err)
	}
}

func TestGroupGatewayProfileMedia(t *testing.T) {
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
	adminGW := newGateway(admin.svc)
	memberGW := newGateway(member.svc)

	memberAccount := base64.RawURLEncoding.EncodeToString(member.account.Pub())
	created, gerr := adminGW.Handle(ctx, "group.create",
		json.RawMessage(fmt.Sprintf(`{"title":"资料群","members":["%s"]}`, memberAccount)))
	if gerr != nil {
		t.Fatalf("group.create: %v", gerr)
	}
	groupIDText := created.(map[string]any)["group_id"].(string)
	groupID, err := parseGroupID(groupIDText)
	if err != nil {
		t.Fatalf("解析群 ID: %v", err)
	}
	waitGroupKey(t, member.svc, groupID)

	avatar := testAvatarB64(t)
	const description = "欢迎加入测试群，这里讨论 Flutter 与 Go。"
	if _, gerr := adminGW.Handle(ctx, "group.setAvatar", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","avatar_b64":"%s"}`, groupIDText, avatar))); gerr != nil {
		t.Fatalf("group.setAvatar: %v", gerr)
	}
	if _, gerr := adminGW.Handle(ctx, "group.setDescription", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","description":%q}`, groupIDText, description))); gerr != nil {
		t.Fatalf("group.setDescription: %v", gerr)
	}
	if got, err := admin.dao.GetGroupAvatar(ctx, groupID); err != nil || got != avatar {
		t.Fatalf("本机群头像不一致: err=%v", err)
	}
	if got, err := admin.dao.GetGroupDescription(ctx, groupID); err != nil || got != description {
		t.Fatalf("本机群介绍 %q（err=%v），期望 %q", got, err, description)
	}

	view, gerr := adminGW.Handle(ctx, "group.members",
		json.RawMessage(fmt.Sprintf(`{"group_id":"%s"}`, groupIDText)))
	if gerr != nil {
		t.Fatalf("group.members: %v", gerr)
	}
	payload := view.(map[string]any)
	if payload["avatar_b64"] != avatar || payload["description"] != description {
		t.Fatalf("group.members 未回显头像/介绍: %v", payload)
	}
	listed, gerr := adminGW.Handle(ctx, "group.list", json.RawMessage(`{}`))
	if gerr != nil {
		t.Fatalf("group.list: %v", gerr)
	}
	items := listed.(map[string]any)["items"].([]map[string]any)
	if len(items) != 1 || items[0]["avatar_b64"] != avatar || items[0]["description"] != description {
		t.Fatalf("group.list 未回显头像/介绍: %v", items)
	}

	// 非管理员不能设置群资料。
	if _, gerr := memberGW.Handle(ctx, "group.setDescription", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","description":"越权"}`, groupIDText))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非管理员期望 INVALID_ARG，实际 %v", gerr)
	}
	if _, gerr := memberGW.Handle(ctx, "group.setAvatar", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","avatar_b64":"%s"}`, groupIDText, avatar))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非管理员期望 INVALID_ARG，实际 %v", gerr)
	}

	// 越长介绍与非法头像被契约层拒绝。
	if _, gerr := adminGW.Handle(ctx, "group.setDescription", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","description":%q}`, groupIDText, strings.Repeat("长", MaxGroupDescriptionRunes+1)))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("超长介绍期望 INVALID_ARG，实际 %v", gerr)
	}
	if _, gerr := adminGW.Handle(ctx, "group.setAvatar", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","avatar_b64":"!!!"}`, groupIDText))); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非法头像期望 INVALID_ARG，实际 %v", gerr)
	}

	// 空串表示清除。
	if _, gerr := adminGW.Handle(ctx, "group.setAvatar", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","avatar_b64":""}`, groupIDText))); gerr != nil {
		t.Fatalf("清除群头像: %v", gerr)
	}
	if _, gerr := adminGW.Handle(ctx, "group.setDescription", json.RawMessage(
		fmt.Sprintf(`{"group_id":"%s","description":""}`, groupIDText))); gerr != nil {
		t.Fatalf("清除群介绍: %v", gerr)
	}
	if got, _ := admin.dao.GetGroupAvatar(ctx, groupID); got != "" {
		t.Fatalf("群头像应已清除，实际 %q", got)
	}
	if got, _ := admin.dao.GetGroupDescription(ctx, groupID); got != "" {
		t.Fatalf("群介绍应已清除，实际 %q", got)
	}
}
