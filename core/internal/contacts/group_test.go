package contacts

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/nexmem/core/gateway"
)

func TestSetGroup(t *testing.T) {
	ctx := context.Background()
	svc := newTestService(t)
	peer := testPeer(0x35)

	c, err := svc.Add(ctx, peer)
	if err != nil {
		t.Fatalf("添加好友: %v", err)
	}
	if c.GroupName != "" {
		t.Fatalf("新好友应无分组: %q", c.GroupName)
	}

	got, err := svc.SetGroup(ctx, peer, "  同事  ")
	if err != nil {
		t.Fatalf("设置分组: %v", err)
	}
	if got != "同事" {
		t.Fatalf("设置分组应去除首尾空白，实际 %q", got)
	}
	c, _ = svc.Get(ctx, peer)
	if c.GroupName != "同事" {
		t.Fatalf("分组应落库，实际 %q", c.GroupName)
	}
	if c.Alias != "" || c.Blocked {
		t.Fatalf("设置分组不应影响备注/拉黑: %+v", c)
	}

	// 再次 Add 不得清除已有分组。
	if _, err := svc.Add(ctx, peer); err != nil {
		t.Fatalf("重复添加: %v", err)
	}
	c, _ = svc.Get(ctx, peer)
	if c.GroupName != "同事" {
		t.Fatalf("重复添加不应清除分组，实际 %q", c.GroupName)
	}

	// 清除分组。
	if _, err := svc.SetGroup(ctx, peer, "  "); err != nil {
		t.Fatalf("清除分组: %v", err)
	}
	c, _ = svc.Get(ctx, peer)
	if c.GroupName != "" {
		t.Fatalf("分组应被清除，实际 %q", c.GroupName)
	}

	// 长度上限按 Unicode 码点计。
	if _, err := svc.SetGroup(ctx, peer, strings.Repeat("字", 33)); err != ErrGroupTooLong {
		t.Fatalf("超长分组应返回 ErrGroupTooLong，实际 %v", err)
	}
	if _, err := svc.SetGroup(ctx, peer, strings.Repeat("字", 32)); err != nil {
		t.Fatalf("32 字分组应合法: %v", err)
	}

	// 非法公钥。
	if _, err := svc.SetGroup(ctx, []byte("bad"), "x"); !errors.Is(err, ErrInvalidPeer) {
		t.Fatalf("非法公钥应返回 ErrInvalidPeer，实际 %v", err)
	}
}

func TestGatewaySetGroup(t *testing.T) {
	ctx := context.Background()
	svc := newTestService(t)
	g := gateway.New()
	if err := Bind(g, svc); err != nil {
		t.Fatalf("接入网关: %v", err)
	}
	peer := testPeer(0x36)
	peerHex := hex.EncodeToString(peer)

	call := func(params string) *gateway.Error {
		_, e := g.Handle(ctx, "contact.setGroup", json.RawMessage(params))
		return e
	}

	if e := call(`{"peer":"` + peerHex + `","group":"家人"}`); e != nil {
		t.Fatalf("设置分组: %v", e)
	}
	c, err := svc.Get(ctx, peer)
	if err != nil {
		t.Fatalf("读取好友: %v", err)
	}
	if c.GroupName != "家人" {
		t.Fatalf("分组应落库，实际 %q", c.GroupName)
	}

	// contact.list 回包带 group_name。
	data, e := g.Handle(ctx, "contact.list", json.RawMessage(`{"limit":10}`))
	if e != nil {
		t.Fatalf("contact.list: %v", e)
	}
	body, _ := json.Marshal(data)
	var list struct {
		Items []struct {
			GroupName string `json:"group_name"`
		} `json:"items"`
	}
	if err := json.Unmarshal(body, &list); err != nil {
		t.Fatalf("解析结果: %v", err)
	}
	if len(list.Items) != 1 || list.Items[0].GroupName != "家人" {
		t.Fatalf("contact.list 应回传 group_name: %s", body)
	}

	// 非法参数。
	if e := call(`{"peer":"` + peerHex + `"}`); e == nil || e.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺少 group 应返回 INVALID_ARG，实际 %v", e)
	}
	if e := call(`{"peer":"not-a-key","group":"x"}`); e == nil || e.Code != gateway.CodeInvalidArg {
		t.Fatalf("非法 peer 应返回 INVALID_ARG，实际 %v", e)
	}
	if e := call(`{"peer":"` + peerHex + `","group":"` + strings.Repeat("a", 33) + `"}`); e == nil || e.Code != gateway.CodeInvalidArg {
		t.Fatalf("超长分组应返回 INVALID_ARG，实际 %v", e)
	}

	// 清除分组。
	if e := call(`{"peer":"` + peerHex + `","group":""}`); e != nil {
		t.Fatalf("清除分组: %v", e)
	}
	c, _ = svc.Get(ctx, peer)
	if c.GroupName != "" {
		t.Fatalf("分组应被清除，实际 %q", c.GroupName)
	}
}
