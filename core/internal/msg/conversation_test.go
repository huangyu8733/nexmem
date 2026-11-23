package msg_test

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"testing"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/msg"
	"github.com/nexmem/core/internal/store"
)

// bindWithAccount 注入本机账号公钥，供 conversation.list 反解单聊对端。
func bindWithAccount(t *testing.T, dao *store.DAO, self []byte) *gateway.Gateway {
	t.Helper()
	gw := gateway.New()
	err := msg.Bind(gw, &msg.Service{
		DAO:     func() *store.DAO { return dao },
		Account: func() []byte { return self },
	})
	if err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	return gw
}

func dmConversationID(self, peer []byte) string {
	if string(self) > string(peer) {
		self, peer = peer, self
	}
	return "dm:" + hex.EncodeToString(self) + "|" + hex.EncodeToString(peer)
}

// TestConversationList 覆盖倒序排序、正文解出、peer 反解与 has_more。
func TestConversationList(t *testing.T) {
	dao := openDAO(t)
	ctx := context.Background()
	self := []byte{0x01, 0x02, 0x03}
	peer := []byte{0x04, 0x05, 0x06}
	convA := dmConversationID(self, peer)
	convB := "dm:aaaa"

	putTextMessage(t, dao, "a1", convA, "早上好", 1000, store.DirectionOut)
	putTextMessage(t, dao, "a2", convA, "收到", 2000, store.DirectionIn)
	putTextMessage(t, dao, "b1", convB, "更早的会话", 500, store.DirectionIn)

	for _, c := range []store.Conversation{
		{ID: convA, Kind: store.ConversationKindDM, Title: "对端", LastMsgAt: 2000, Unread: 2},
		{ID: convB, Kind: store.ConversationKindDM, Title: "另一个", LastMsgAt: 500},
		{ID: "dm:empty", Kind: store.ConversationKindDM, Title: ""},
	} {
		if err := dao.UpsertConversation(ctx, c); err != nil {
			t.Fatalf("写入会话 %s: %v", c.ID, err)
		}
	}

	gw := bindWithAccount(t, dao, self)
	res, gerr := handle(t, gw, "conversation.list", map[string]any{"limit": 2})
	if gerr != nil {
		t.Fatalf("conversation.list 失败: %v", gerr)
	}
	data := res.(map[string]any)
	if data["has_more"] != true {
		t.Fatalf("limit=2 时应有更多会话: %#v", data)
	}
	items := data["items"].([]map[string]any)
	if len(items) != 2 {
		t.Fatalf("应返回 2 条，实际 %d", len(items))
	}
	if items[0]["conversation_id"] != convA || items[1]["conversation_id"] != convB {
		t.Fatalf("会话未按最近消息倒序: %#v", items)
	}
	if items[0]["last_text"] != "收到" || items[0]["last_direction"] != "in" {
		t.Fatalf("最后一条正文/方向不正确: %#v", items[0])
	}
	if items[0]["unread"] != 2 || items[0]["kind"] != "dm" {
		t.Fatalf("未读或类型不正确: %#v", items[0])
	}
	wantPeer := base64.RawURLEncoding.EncodeToString(peer)
	if items[0]["peer"] != wantPeer {
		t.Fatalf("peer 应为 %s，实际 %v", wantPeer, items[0]["peer"])
	}
	if _, ok := items[1]["last_msg_at"]; !ok {
		t.Fatalf("last_msg_at 缺失: %#v", items[1])
	}

	// 无消息会话排在最后且不带正文；peer 反解依赖本机账号。
	all, gerr := handle(t, gw, "conversation.list", nil)
	if gerr != nil {
		t.Fatalf("默认 limit 失败: %v", gerr)
	}
	allData := all.(map[string]any)
	if allData["has_more"] != false {
		t.Fatalf("全量应无更多: %#v", allData)
	}
	allItems := allData["items"].([]map[string]any)
	if len(allItems) != 3 || allItems[2]["conversation_id"] != "dm:empty" {
		t.Fatalf("无消息会话应排最后: %#v", allItems)
	}
	if _, ok := allItems[2]["last_text"]; ok {
		t.Fatalf("无消息会话不应有 last_text: %#v", allItems[2])
	}
	if _, ok := allItems[2]["peer"]; ok {
		t.Fatalf("非本机参与的会话不应给出 peer: %#v", allItems[2])
	}
}

// TestUpdateConversationFlags 覆盖 P6-17：置顶 / 免打扰落库并在列表回显。
func TestUpdateConversationFlags(t *testing.T) {
	dao := openDAO(t)
	ctx := context.Background()
	conv := "dm:alice|bob"
	for _, c := range []store.Conversation{
		{ID: conv, Kind: store.ConversationKindDM, Title: "Alice", LastMsgAt: 100},
		{ID: "dm:carol|dave", Kind: store.ConversationKindDM, Title: "Carol", LastMsgAt: 200},
	} {
		if err := dao.UpsertConversation(ctx, c); err != nil {
			t.Fatalf("写入会话 %s: %v", c.ID, err)
		}
	}
	gw := bindWithAccount(t, dao, []byte{0x01})

	if _, gerr := handle(t, gw, "conversation.update", map[string]any{
		"conversation_id": conv,
		"pinned":          true,
	}); gerr != nil {
		t.Fatalf("置顶失败: %v", gerr)
	}
	if _, gerr := handle(t, gw, "conversation.update", map[string]any{
		"conversation_id": conv,
		"muted":           true,
	}); gerr != nil {
		t.Fatalf("免打扰失败: %v", gerr)
	}
	got, err := dao.GetConversation(ctx, conv)
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if !got.Pinned || !got.Muted {
		t.Fatalf("标记未落库: pinned=%v muted=%v", got.Pinned, got.Muted)
	}

	res, gerr := handle(t, gw, "conversation.list", nil)
	if gerr != nil {
		t.Fatalf("conversation.list 失败: %v", gerr)
	}
	items := res.(map[string]any)["items"].([]map[string]any)
	if items[0]["conversation_id"] != conv {
		t.Fatalf("置顶会话应排最前: %#v", items)
	}
	if items[0]["pinned"] != true || items[0]["muted"] != true {
		t.Fatalf("列表未回显标记: %#v", items[0])
	}

	// 取消置顶后恢复按最近消息倒序。
	if _, gerr := handle(t, gw, "conversation.update", map[string]any{
		"conversation_id": conv,
		"pinned":          false,
	}); gerr != nil {
		t.Fatalf("取消置顶失败: %v", gerr)
	}
	res, gerr = handle(t, gw, "conversation.list", nil)
	if gerr != nil {
		t.Fatalf("conversation.list 失败: %v", gerr)
	}
	items = res.(map[string]any)["items"].([]map[string]any)
	if items[0]["conversation_id"] != "dm:carol|dave" {
		t.Fatalf("取消置顶后应按时间倒序: %#v", items)
	}

	for name, params := range map[string]map[string]any{
		"缺 conversation_id": {},
		"未提供任何标记":           {"conversation_id": conv},
		"未知会话":              {"conversation_id": "dm:missing", "pinned": true},
	} {
		if _, gerr := handle(t, gw, "conversation.update", params); gerr == nil {
			t.Fatalf("%s 应返回 INVALID_ARG", name)
		} else if gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("%s 错误码 = %s，期望 INVALID_ARG", name, gerr.Code)
		}
	}
}

func TestConversationListGroupTitleUsesGroupRecord(t *testing.T) {
	dao := openDAO(t)
	ctx := context.Background()
	groupID := []byte("group-1")
	convID := "group:" + base64.RawURLEncoding.EncodeToString(groupID)
	if err := dao.PutGroup(ctx, store.Group{
		GroupID: groupID, Title: "研发群", GroupKeyEnc: []byte{0x01},
	}); err != nil {
		t.Fatalf("写入群: %v", err)
	}
	if err := dao.UpsertConversation(ctx, store.Conversation{
		ID: convID, Kind: store.ConversationKindGroup, Title: "旧标题", LastMsgAt: 100,
	}); err != nil {
		t.Fatalf("写入群会话: %v", err)
	}

	gw := bindWithAccount(t, dao, []byte{0x01})
	res, gerr := handle(t, gw, "conversation.list", map[string]any{})
	if gerr != nil {
		t.Fatalf("conversation.list 失败: %v", gerr)
	}
	item := res.(map[string]any)["items"].([]map[string]any)[0]
	if item["title"] != "研发群" {
		t.Fatalf("群标题应取 groups 表，实际 %v", item["title"])
	}
	if item["kind"] != "group" || item["group_id"] != base64.RawURLEncoding.EncodeToString(groupID) {
		t.Fatalf("群条目字段不正确: %#v", item)
	}

	// 本机群备注优先于群名，清除后备注回落群名（P6-27）。
	if err := dao.SetGroupAlias(ctx, groupID, "值班群"); err != nil {
		t.Fatalf("写入群备注: %v", err)
	}
	res, gerr = handle(t, gw, "conversation.list", map[string]any{})
	if gerr != nil {
		t.Fatalf("conversation.list 失败: %v", gerr)
	}
	item = res.(map[string]any)["items"].([]map[string]any)[0]
	if item["title"] != "值班群" {
		t.Fatalf("群备注应覆盖会话标题，实际 %v", item["title"])
	}
	if err := dao.SetGroupAlias(ctx, groupID, ""); err != nil {
		t.Fatalf("清除群备注: %v", err)
	}
	res, gerr = handle(t, gw, "conversation.list", map[string]any{})
	if gerr != nil {
		t.Fatalf("conversation.list 失败: %v", gerr)
	}
	item = res.(map[string]any)["items"].([]map[string]any)[0]
	if item["title"] != "研发群" {
		t.Fatalf("清除备注后应回落群名，实际 %v", item["title"])
	}
}

// TestConversationListErrors 覆盖非法 limit 与未启动状态。
func TestConversationListErrors(t *testing.T) {
	dao := openDAO(t)
	gw := bindWithAccount(t, dao, nil)
	for _, limit := range []int{-1, 201} {
		if _, gerr := handle(t, gw, "conversation.list", map[string]any{"limit": limit}); gerr == nil ||
			gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("limit=%d 应返回 INVALID_ARG，实际 %v", limit, gerr)
		}
	}
	if _, gerr := handle(t, gw, "conversation.list", "not-an-object"); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("非对象参数应返回 INVALID_ARG，实际 %v", gerr)
	}

	stopped := gateway.New()
	if err := msg.Bind(stopped, &msg.Service{DAO: func() *store.DAO { return nil }}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	if _, gerr := handle(t, stopped, "conversation.list", map[string]any{}); gerr == nil ||
		gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动应返回 NOT_STARTED，实际 %v", gerr)
	}
}
