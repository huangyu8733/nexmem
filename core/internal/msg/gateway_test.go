package msg_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/msg"
	"github.com/nexmem/core/internal/store"
)

func openDAO(t *testing.T) *store.DAO {
	t.Helper()
	path := filepath.Join(t.TempDir(), "msg.db")
	db, err := store.Open(path)
	if err != nil {
		t.Fatalf("打开数据库: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if err := store.Migrate(context.Background(), db); err != nil {
		t.Fatalf("迁移数据库: %v", err)
	}
	return store.NewDAO(db)
}

func putConversation(t *testing.T, dao *store.DAO, id string, unread int) {
	t.Helper()
	if err := dao.UpsertConversation(context.Background(), store.Conversation{
		ID: id, Kind: store.ConversationKindDM, Title: id, Unread: unread,
	}); err != nil {
		t.Fatalf("写入会话: %v", err)
	}
}

func putMessage(t *testing.T, dao *store.DAO, m store.Message) {
	t.Helper()
	if err := dao.PutMessage(context.Background(), m); err != nil {
		t.Fatalf("写入消息 %s: %v", m.MsgUUID, err)
	}
}

// putTextMessage 写入一条可解出正文的消息，BodyEnc 与生产链路一致为 InnerMessage。
func putTextMessage(t *testing.T, dao *store.DAO, msgUUID, convID, text string, sentAt int64, direction int) {
	t.Helper()
	inner, err := proto.Marshal(&nexmemv1.InnerMessage{Text: text})
	if err != nil {
		t.Fatalf("编码消息正文: %v", err)
	}
	putMessage(t, dao, store.Message{
		MsgUUID:        msgUUID,
		ConversationID: convID,
		SenderAccount:  []byte("account-" + msgUUID),
		SentAt:         sentAt,
		Direction:      direction,
		ContentType:    int(nexmemv1.ContentType_CONTENT_TYPE_TEXT),
		BodyEnc:        inner,
		State:          store.MessageStateAcked,
		Body:           text,
	})
}

func bind(t *testing.T, dao *store.DAO) *gateway.Gateway {
	t.Helper()
	gw := gateway.New()
	err := msg.Bind(gw, &msg.Service{DAO: func() *store.DAO { return dao }})
	if err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	return gw
}

func handle(t *testing.T, gw *gateway.Gateway, method string, params any) (any, *gateway.Error) {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("编码参数: %v", err)
	}
	return gw.Handle(context.Background(), method, raw)
}

// TestListPaginatesDescending 覆盖倒序键集分页、has_more 与正文解出。
func TestListPaginatesDescending(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	for _, m := range []struct {
		id   string
		at   int64
		dir  int
		text string
	}{
		{"m1", 1000, store.DirectionIn, "第一条"},
		{"m2", 2000, store.DirectionOut, "第二条"},
		{"m3", 3000, store.DirectionIn, "第三条"},
		{"m4", 4000, store.DirectionOut, "第四条"},
		{"m5", 5000, store.DirectionIn, "第五条"},
	} {
		putTextMessage(t, dao, m.id, conv, m.text, m.at, m.dir)
	}
	gw := bind(t, dao)

	page1, gerr := handle(t, gw, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 2,
	})
	if gerr != nil {
		t.Fatalf("首页失败: %v", gerr)
	}
	items := page1.(map[string]any)["items"].([]map[string]any)
	if len(items) != 2 || items[0]["msg_uuid"] != "m5" || items[1]["msg_uuid"] != "m4" {
		t.Fatalf("首页内容错误: %+v", items)
	}
	if page1.(map[string]any)["has_more"] != true {
		t.Fatal("首页应有更多")
	}
	if items[0]["text"] != "第五条" || items[0]["direction"] != "in" || items[0]["state"] != "acked" {
		t.Fatalf("首页字段错误: %+v", items[0])
	}
	wantSender := base64.RawURLEncoding.EncodeToString([]byte("account-m5"))
	if items[0]["sender_account"] != wantSender {
		t.Fatalf("发送者编码错误: %v", items[0]["sender_account"])
	}

	page2, gerr := handle(t, gw, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 2, "before_id": "m4",
	})
	if gerr != nil {
		t.Fatalf("第二页失败: %v", gerr)
	}
	items = page2.(map[string]any)["items"].([]map[string]any)
	if len(items) != 2 || items[0]["msg_uuid"] != "m3" || items[1]["msg_uuid"] != "m2" {
		t.Fatalf("第二页内容错误: %+v", items)
	}
	if page2.(map[string]any)["has_more"] != true {
		t.Fatal("第二页应有更多")
	}

	page3, gerr := handle(t, gw, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 2, "before_id": "m2",
	})
	if gerr != nil {
		t.Fatalf("第三页失败: %v", gerr)
	}
	items = page3.(map[string]any)["items"].([]map[string]any)
	if len(items) != 1 || items[0]["msg_uuid"] != "m1" {
		t.Fatalf("第三页内容错误: %+v", items)
	}
	if page3.(map[string]any)["has_more"] != false {
		t.Fatal("末页不应有更多")
	}
}

// TestListRejectsInvalidParams 覆盖缺参、非法 limit、未知游标与跨会话游标。
func TestListRejectsInvalidParams(t *testing.T) {
	dao := openDAO(t)
	putTextMessage(t, dao, "m1", "dm:alice", "你好", 1000, store.DirectionIn)
	putTextMessage(t, dao, "x1", "dm:bob", "别人", 1500, store.DirectionIn)
	gw := bind(t, dao)

	cases := []struct {
		name   string
		params map[string]any
	}{
		{"缺少会话", map[string]any{"limit": 10}},
		{"limit 为零", map[string]any{"conversation_id": "dm:alice", "limit": 0}},
		{"limit 超上限", map[string]any{"conversation_id": "dm:alice", "limit": 201}},
		{"未知游标", map[string]any{"conversation_id": "dm:alice", "limit": 10, "before_id": "nope"}},
		{"跨会话游标", map[string]any{"conversation_id": "dm:alice", "limit": 10, "before_id": "x1"}},
	}
	for _, c := range cases {
		if _, gerr := handle(t, gw, "msg.list", c.params); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("%s 应返回 INVALID_ARG，实际 %+v", c.name, gerr)
		}
	}
}

// TestListNotStarted 内核未打开数据库时返回 NOT_STARTED。
func TestListNotStarted(t *testing.T) {
	gw := gateway.New()
	if err := msg.Bind(gw, &msg.Service{}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	_, gerr := handle(t, gw, "msg.list", map[string]any{"conversation_id": "dm:alice", "limit": 10})
	if gerr == nil || gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动应返回 NOT_STARTED，实际 %+v", gerr)
	}
}

// TestSearchReturnsHitWithSnippet 覆盖检索命中的字段、倒序与高亮片段。
func TestSearchReturnsHitWithSnippet(t *testing.T) {
	dao := openDAO(t)
	putConversation(t, dao, "dm:alice", 0)
	putMessage(t, dao, store.Message{
		MsgUUID: "m1", ConversationID: "dm:alice", SentAt: 1000, BodyEnc: []byte("c1"),
		SenderAccount: []byte("alice"),
		Direction:     store.DirectionIn, State: store.MessageStateReceived,
		Body: "明天下午三点开会讨论 nexmem 的检索方案",
	})
	putMessage(t, dao, store.Message{
		MsgUUID: "m2", ConversationID: "dm:alice", SentAt: 2000, BodyEnc: []byte("c2"),
		SenderAccount: []byte("me"),
		Direction:     store.DirectionOut, State: store.MessageStateSent,
		Body: "好的，检索方案我同步一份",
	})
	putMessage(t, dao, store.Message{
		MsgUUID: "m3", ConversationID: "dm:alice", SentAt: 3000, BodyEnc: []byte("c3"),
		SenderAccount: []byte("alice"),
		Direction:     store.DirectionIn, State: store.MessageStateReceived,
		Body: "与话题无关的消息",
	})

	gw := bind(t, dao)
	data, gerr := handle(t, gw, "msg.search", map[string]any{"q": "检索", "limit": 10})
	if gerr != nil {
		t.Fatalf("检索失败: %v", gerr)
	}
	items := data.(map[string]any)["items"].([]map[string]any)
	if len(items) != 2 {
		t.Fatalf("命中条数 = %d，期望 2", len(items))
	}
	// 按 sent_at 倒序：m2 在前。
	if items[0]["msg_uuid"] != "m2" || items[1]["msg_uuid"] != "m1" {
		t.Fatalf("命中顺序错误: %+v", items)
	}
	if items[0]["direction"] != "out" || items[1]["direction"] != "in" {
		t.Fatalf("方向字段错误: %+v", items)
	}
	snippet, _ := items[0]["snippet"].(string)
	if snippet == "" || !contains(snippet, "[检索]") {
		t.Fatalf("片段未高亮关键词: %q", snippet)
	}
}

// TestSearchFiltersByConversation 覆盖 msg.search 的 conversation_id 过滤接线：
// DAO 早有该能力，此处验证网关把参数透传下去（P6-33）。
func TestSearchFiltersByConversation(t *testing.T) {
	dao := openDAO(t)
	putConversation(t, dao, "dm:alice", 0)
	putConversation(t, dao, "dm:bob", 0)
	putMessage(t, dao, store.Message{
		MsgUUID: "m1", ConversationID: "dm:alice", SentAt: 1000, BodyEnc: []byte("c1"),
		SenderAccount: []byte("alice"),
		Direction:     store.DirectionIn, State: store.MessageStateReceived,
		Body: "检索 关键词",
	})
	putMessage(t, dao, store.Message{
		MsgUUID: "m2", ConversationID: "dm:bob", SentAt: 2000, BodyEnc: []byte("c2"),
		SenderAccount: []byte("bob"),
		Direction:     store.DirectionIn, State: store.MessageStateReceived,
		Body: "检索 关键词",
	})

	gw := bind(t, dao)
	// 限定 dm:bob：只应命中 m2。
	data, gerr := handle(t, gw, "msg.search", map[string]any{
		"q": "检索", "limit": 10, "conversation_id": "dm:bob",
	})
	if gerr != nil {
		t.Fatalf("检索失败: %v", gerr)
	}
	items := data.(map[string]any)["items"].([]map[string]any)
	if len(items) != 1 || items[0]["msg_uuid"] != "m2" {
		t.Fatalf("会话过滤结果错误: %+v", items)
	}
	// 不传 conversation_id：两会话都应命中。
	data, gerr = handle(t, gw, "msg.search", map[string]any{"q": "检索", "limit": 10})
	if gerr != nil {
		t.Fatalf("检索失败: %v", gerr)
	}
	items = data.(map[string]any)["items"].([]map[string]any)
	if len(items) != 2 {
		t.Fatalf("全会话命中数 = %d，期望 2", len(items))
	}
}

// TestSearchRejectsEmptyQuery 空关键词属于非法参数。
func TestSearchRejectsEmptyQuery(t *testing.T) {
	dao := openDAO(t)
	gw := bind(t, dao)
	_, gerr := handle(t, gw, "msg.search", map[string]any{"q": "   ", "limit": 10})
	if gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("空关键词应返回 INVALID_ARG，实际 %+v", gerr)
	}
}

// TestSearchNotStarted 内核未打开数据库时返回 NOT_STARTED。
func TestSearchNotStarted(t *testing.T) {
	gw := gateway.New()
	if err := msg.Bind(gw, &msg.Service{}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	_, gerr := handle(t, gw, "msg.search", map[string]any{"q": "检索", "limit": 10})
	if gerr == nil || gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动应返回 NOT_STARTED，实际 %+v", gerr)
	}
}

// TestMarkReadClearsUnread 覆盖已读推进与未知会话。
func TestMarkReadClearsUnread(t *testing.T) {
	dao := openDAO(t)
	putConversation(t, dao, "dm:alice", 3)
	gw := bind(t, dao)

	if _, gerr := handle(t, gw, "msg.markRead", map[string]any{
		"conversation_id": "dm:alice", "up_to_id": "m9",
	}); gerr != nil {
		t.Fatalf("标记已读失败: %v", gerr)
	}
	c, err := dao.GetConversation(context.Background(), "dm:alice")
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if c.Unread != 0 {
		t.Fatalf("未读数 = %d，期望 0", c.Unread)
	}

	if _, gerr := handle(t, gw, "msg.markRead", map[string]any{
		"conversation_id": "dm:bob", "up_to_id": "",
	}); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("未知会话应返回 INVALID_ARG，实际 %+v", gerr)
	}
	if _, gerr := handle(t, gw, "msg.markRead", map[string]any{
		"conversation_id": "", "up_to_id": "",
	}); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺少会话应返回 INVALID_ARG，实际 %+v", gerr)
	}
}

// TestBindRejectsMissingArgs 装配参数缺失时明确报错。
func TestBindRejectsMissingArgs(t *testing.T) {
	if err := msg.Bind(nil, &msg.Service{}); err == nil {
		t.Fatal("缺少网关应报错")
	}
	if err := msg.Bind(gateway.New(), nil); err == nil {
		t.Fatal("缺少服务应报错")
	}
}

// TestListSinceIncremental 覆盖按 seq 升序增量拉取、会话隔离与空页终止。
func TestListSinceIncremental(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	putTextMessage(t, dao, "m1", conv, "第一条", 1000, store.DirectionIn)
	putTextMessage(t, dao, "x1", "dm:bob", "别的会话", 1500, store.DirectionIn)
	putTextMessage(t, dao, "m2", conv, "第二条", 2000, store.DirectionOut)
	putTextMessage(t, dao, "m3", conv, "第三条", 3000, store.DirectionIn)
	gw := bind(t, dao)

	data, gerr := handle(t, gw, "msg.listSince", map[string]any{
		"conversation_id": conv, "after_seq": 0,
	})
	if gerr != nil {
		t.Fatalf("增量拉取失败: %v", gerr)
	}
	items := data.(map[string]any)["items"].([]map[string]any)
	if len(items) != 3 {
		t.Fatalf("应返回 3 条, 实际 %d: %+v", len(items), items)
	}
	if items[0]["msg_uuid"] != "m1" || items[1]["msg_uuid"] != "m2" || items[2]["msg_uuid"] != "m3" {
		t.Fatalf("顺序错误: %+v", items)
	}
	if items[0]["text"] != "第一条" || items[0]["direction"] != "in" {
		t.Fatalf("字段错误: %+v", items[0])
	}
	prev := int64(-1)
	for _, item := range items {
		seq, _ := item["seq"].(int64)
		if seq <= prev {
			t.Fatalf("seq 未严格递增: %d -> %d", prev, seq)
		}
		prev = seq
	}

	// 用末条 seq 续读应得到空页，避免客户端重复消费。
	again, gerr := handle(t, gw, "msg.listSince", map[string]any{
		"conversation_id": conv, "after_seq": items[2]["seq"],
	})
	if gerr != nil {
		t.Fatalf("续读失败: %v", gerr)
	}
	if rest := again.(map[string]any)["items"].([]map[string]any); len(rest) != 0 {
		t.Fatalf("续读应为空, 实际 %+v", rest)
	}

	// 从中间序号继续只返回其后的消息。
	mid, gerr := handle(t, gw, "msg.listSince", map[string]any{
		"conversation_id": conv, "after_seq": items[0]["seq"],
	})
	if gerr != nil {
		t.Fatalf("增量续读失败: %v", gerr)
	}
	if rest := mid.(map[string]any)["items"].([]map[string]any); len(rest) != 2 || rest[0]["msg_uuid"] != "m2" {
		t.Fatalf("增量续读结果错误: %+v", rest)
	}

	// 参数校验：缺会话、负序号、未知方法均须 INVALID_ARG。
	for _, c := range []struct {
		name   string
		params map[string]any
	}{
		{"缺少会话", map[string]any{"after_seq": 0}},
		{"负序号", map[string]any{"conversation_id": conv, "after_seq": -1}},
		{"缺序号", map[string]any{"conversation_id": conv}},
	} {
		if _, gerr := handle(t, gw, "msg.listSince", c.params); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("%s 应返回 INVALID_ARG，实际 %+v", c.name, gerr)
		}
	}

	// 未接入 DAO 时返回 NOT_STARTED。
	empty := gateway.New()
	if err := msg.Bind(empty, &msg.Service{}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	if _, gerr := handle(t, empty, "msg.listSince", map[string]any{
		"conversation_id": conv, "after_seq": 0,
	}); gerr == nil || gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未启动应返回 NOT_STARTED，实际 %+v", gerr)
	}
}

// TestListExposesReplyTo 覆盖 msg.list / msg.listSince 回显被引用消息 ID（P6-32）。
func TestListExposesReplyTo(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	putTextMessage(t, dao, "m1", conv, "原文", 1000, store.DirectionIn)
	inner, err := proto.Marshal(&nexmemv1.InnerMessage{Text: "收到", ReplyTo: "m1"})
	if err != nil {
		t.Fatalf("编码引用消息: %v", err)
	}
	putMessage(t, dao, store.Message{
		MsgUUID:        "m2",
		ConversationID: conv,
		SenderAccount:  []byte("account-m2"),
		SentAt:         2000,
		Direction:      store.DirectionOut,
		ContentType:    int(nexmemv1.ContentType_CONTENT_TYPE_TEXT),
		BodyEnc:        inner,
		State:          store.MessageStateSent,
		Body:           "收到",
	})
	gw := bind(t, dao)

	for _, method := range []string{"msg.list", "msg.listSince"} {
		params := map[string]any{"conversation_id": conv}
		if method == "msg.list" {
			params["limit"] = 10
		} else {
			params["after_seq"] = 0
		}
		data, gerr := handle(t, gw, method, params)
		if gerr != nil {
			t.Fatalf("%s 拉取失败: %v", method, gerr)
		}
		items := data.(map[string]any)["items"].([]map[string]any)
		if len(items) != 2 {
			t.Fatalf("%s 应返回 2 条, 实际 %d", method, len(items))
		}
		// 按 msg_uuid 定位，避免依赖两种方法的排序方向。
		var original, reply *map[string]any
		for i := range items {
			switch items[i]["msg_uuid"] {
			case "m1":
				original = &items[i]
			case "m2":
				reply = &items[i]
			}
		}
		if original == nil || reply == nil {
			t.Fatalf("%s 缺少消息: %+v", method, items)
		}
		if _, ok := (*original)["reply_to"]; ok {
			t.Fatalf("%s 非引用消息不应回显 reply_to: %+v", method, *original)
		}
		if (*reply)["reply_to"] != "m1" {
			t.Fatalf("%s 未回显 reply_to: %+v", method, *reply)
		}
	}
}

// TestListExposesSeqAsSinceCursor 覆盖 msg.list 列表项回传 seq 作为增量基准：
// 客户端用最新一条的 seq 调 msg.listSince 应得到空页，用最早的 seq 续读得到其后全部（P6-31）。
func TestListExposesSeqAsSinceCursor(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	putTextMessage(t, dao, "m1", conv, "第一条", 1000, store.DirectionIn)
	putTextMessage(t, dao, "m2", conv, "第二条", 2000, store.DirectionOut)
	putTextMessage(t, dao, "m3", conv, "第三条", 3000, store.DirectionIn)
	gw := bind(t, dao)

	data, gerr := handle(t, gw, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 10,
	})
	if gerr != nil {
		t.Fatalf("拉取消息失败: %v", gerr)
	}
	items := data.(map[string]any)["items"].([]map[string]any)
	if len(items) != 3 {
		t.Fatalf("应返回 3 条, 实际 %d", len(items))
	}
	// msg.list 按 sent_at 倒序，seq 应严格递减且均为正数。
	prev := int64(1 << 62)
	for _, item := range items {
		seq, ok := item["seq"].(int64)
		if !ok || seq <= 0 {
			t.Fatalf("列表项缺少有效 seq: %+v", item)
		}
		if seq >= prev {
			t.Fatalf("msg.list 未按 seq 递减: %d -> %d", prev, seq)
		}
		prev = seq
	}

	oldest := items[len(items)-1]["seq"]
	mid, gerr := handle(t, gw, "msg.listSince", map[string]any{
		"conversation_id": conv, "after_seq": oldest,
	})
	if gerr != nil {
		t.Fatalf("用 msg.list 的 seq 续读失败: %v", gerr)
	}
	if rest := mid.(map[string]any)["items"].([]map[string]any); len(rest) != 2 {
		t.Fatalf("从最早 seq 续读应得 2 条, 实际 %+v", rest)
	}

	latest := items[0]["seq"]
	end, gerr := handle(t, gw, "msg.listSince", map[string]any{
		"conversation_id": conv, "after_seq": latest,
	})
	if gerr != nil {
		t.Fatalf("用最新 seq 续读失败: %v", gerr)
	}
	if rest := end.(map[string]any)["items"].([]map[string]any); len(rest) != 0 {
		t.Fatalf("用最新 seq 续读应为空, 实际 %+v", rest)
	}
}

// TestListItemExposesAttachmentPath 覆盖文件消息附件的元数据与接收端落盘路径回传。
func TestListItemExposesAttachmentPath(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	inner, err := proto.Marshal(&nexmemv1.InnerMessage{
		Attachments: []*nexmemv1.Attachment{{
			Name:    "报告.pdf",
			Size:    2048,
			Mime:    "application/pdf",
			BlobRef: `D:\nexmem\files\f1.pdf`,
		}},
	})
	if err != nil {
		t.Fatalf("编码附件消息: %v", err)
	}
	putMessage(t, dao, store.Message{
		MsgUUID:        "f1",
		ConversationID: conv,
		SenderAccount:  []byte("account-f1"),
		SentAt:         1000,
		Direction:      store.DirectionIn,
		ContentType:    int(nexmemv1.ContentType_CONTENT_TYPE_FILE),
		BodyEnc:        inner,
		State:          store.MessageStateAcked,
	})
	gw := bind(t, dao)

	data, gerr := handle(t, gw, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 10,
	})
	if gerr != nil {
		t.Fatalf("拉取消息失败: %v", gerr)
	}
	items := data.(map[string]any)["items"].([]map[string]any)
	if len(items) != 1 {
		t.Fatalf("应返回 1 条, 实际 %d", len(items))
	}
	atts, ok := items[0]["attachments"].([]map[string]any)
	if !ok || len(atts) != 1 {
		t.Fatalf("附件字段缺失: %+v", items[0])
	}
	if atts[0]["name"] != "报告.pdf" || fmt.Sprint(atts[0]["size"]) != "2048" || atts[0]["mime"] != "application/pdf" {
		t.Fatalf("附件元数据错误: %+v", atts[0])
	}
	if atts[0]["path"] != `D:\nexmem\files\f1.pdf` {
		t.Fatalf("接收端落盘路径未回传: %+v", atts[0])
	}

	// 发送端附件没有 BlobRef 时不应输出 path 字段。
	sendInner, err := proto.Marshal(&nexmemv1.InnerMessage{
		Attachments: []*nexmemv1.Attachment{{Name: "a.txt", Size: 1}},
	})
	if err != nil {
		t.Fatalf("编码发送端附件: %v", err)
	}
	putMessage(t, dao, store.Message{
		MsgUUID:        "f2",
		ConversationID: conv,
		SenderAccount:  []byte("account-f2"),
		SentAt:         2000,
		Direction:      store.DirectionOut,
		ContentType:    int(nexmemv1.ContentType_CONTENT_TYPE_FILE),
		BodyEnc:        sendInner,
		State:          store.MessageStateAcked,
	})
	again, gerr := handle(t, gw, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 10,
	})
	if gerr != nil {
		t.Fatalf("再次拉取消息失败: %v", gerr)
	}
	out := again.(map[string]any)["items"].([]map[string]any)[0]["attachments"].([]map[string]any)
	if _, exists := out[0]["path"]; exists {
		t.Fatalf("发送端不应输出本地路径: %+v", out[0])
	}
}

// TestDeleteConversation 覆盖 conversation.delete：删除后会话列表不再返回，
// 未知会话与缺参返回 INVALID_ARG，内核未启动返回 NOT_STARTED（P6-07）。
func TestDeleteConversation(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	putConversation(t, dao, conv, 2)
	putTextMessage(t, dao, "m1", conv, "你好", 1000, store.DirectionIn)
	gw := bind(t, dao)

	if _, gerr := handle(t, gw, "conversation.delete", map[string]any{"conversation_id": conv}); gerr != nil {
		t.Fatalf("删除会话失败: %v", gerr)
	}
	listed, gerr := handle(t, gw, "conversation.list", map[string]any{"limit": 10})
	if gerr != nil {
		t.Fatalf("读取会话列表失败: %v", gerr)
	}
	if items := listed.(map[string]any)["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("删除后仍返回会话: %+v", items)
	}
	// 历史消息保留，供后续重新拉取或搜索。
	if msgs, err := dao.ListMessages(context.Background(), conv, nil, 10); err != nil || len(msgs) != 1 {
		t.Fatalf("删除会话不应删除消息: len=%d err=%v", len(msgs), err)
	}

	if _, gerr := handle(t, gw, "conversation.delete", map[string]any{"conversation_id": conv}); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("重复删除期望 INVALID_ARG，实际 %v", gerr)
	}
	if _, gerr := handle(t, gw, "conversation.delete", map[string]any{}); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺少 conversation_id 期望 INVALID_ARG，实际 %v", gerr)
	}

	stopped := gateway.New()
	if err := msg.Bind(stopped, &msg.Service{}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	if _, gerr := handle(t, stopped, "conversation.delete", map[string]any{"conversation_id": conv}); gerr == nil ||
		gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("内核未启动期望 NOT_STARTED，实际 %v", gerr)
	}
}

// TestClearConversation 覆盖 P6-13 conversation.clear：清空本机历史与检索索引、
// 会话保留且未读归零；未知会话与缺参返回 INVALID_ARG，内核未启动返回 NOT_STARTED。
func TestClearConversation(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	putConversation(t, dao, conv, 3)
	putTextMessage(t, dao, "m1", conv, "欢迎回来", 1000, store.DirectionIn)
	putTextMessage(t, dao, "m2", conv, "欢迎回来，路上小心", 2000, store.DirectionOut)
	gw := bind(t, dao)

	out, gerr := handle(t, gw, "conversation.clear", map[string]any{"conversation_id": conv})
	if gerr != nil {
		t.Fatalf("清空会话失败: %v", gerr)
	}
	if deleted := out.(map[string]any)["deleted"].(int); deleted != 2 {
		t.Fatalf("清空条数 = %d，期望 2", deleted)
	}
	if msgs, err := dao.ListMessages(context.Background(), conv, nil, 10); err != nil || len(msgs) != 0 {
		t.Fatalf("清空后仍有消息: len=%d err=%v", len(msgs), err)
	}
	hits, err := dao.SearchMessages(context.Background(), store.MessageSearchQuery{Query: "欢迎回来"})
	if err != nil || len(hits) != 0 {
		t.Fatalf("清空后仍能检索到消息: hits=%d err=%v", len(hits), err)
	}
	kept, err := dao.GetConversation(context.Background(), conv)
	if err != nil {
		t.Fatalf("清空不应删除会话: %v", err)
	}
	if kept.Unread != 0 {
		t.Fatalf("清空后未读 = %d，期望 0", kept.Unread)
	}

	// 空会话重复清空返回 0，不报错。
	out, gerr = handle(t, gw, "conversation.clear", map[string]any{"conversation_id": conv})
	if gerr != nil {
		t.Fatalf("重复清空失败: %v", gerr)
	}
	if deleted := out.(map[string]any)["deleted"].(int); deleted != 0 {
		t.Fatalf("空会话清空条数 = %d，期望 0", deleted)
	}

	if _, gerr := handle(t, gw, "conversation.clear", map[string]any{"conversation_id": "dm:ghost"}); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("未知会话期望 INVALID_ARG，实际 %v", gerr)
	}
	if _, gerr := handle(t, gw, "conversation.clear", map[string]any{}); gerr == nil ||
		gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺少 conversation_id 期望 INVALID_ARG，实际 %v", gerr)
	}

	stopped := gateway.New()
	if err := msg.Bind(stopped, &msg.Service{}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	if _, gerr := handle(t, stopped, "conversation.clear", map[string]any{"conversation_id": conv}); gerr == nil ||
		gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("内核未启动期望 NOT_STARTED，实际 %v", gerr)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// TestRecallMessage 覆盖 P6-12 / P6-14 撤回：2 分钟内的己方单聊或群聊消息可撤回，
// 先删本机再回调通知；超时、他人消息、未知会话与未知消息均拒绝。
func TestRecallMessage(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	const groupConv = "group:Z3JvdXAx"
	now := time.Now().UnixMilli()
	putConversation(t, dao, conv, 0)
	putTextMessage(t, dao, "mine", conv, "我发的", now, store.DirectionOut)
	putTextMessage(t, dao, "old", conv, "三分钟前", now-3*time.Minute.Milliseconds(), store.DirectionOut)
	putTextMessage(t, dao, "theirs", conv, "对方发的", now, store.DirectionIn)
	putTextMessage(t, dao, "grp", groupConv, "群消息", now, store.DirectionOut)

	gw := gateway.New()
	var recalled []string
	err := msg.Bind(gw, &msg.Service{
		DAO: func() *store.DAO { return dao },
		OnRecalled: func(conversationID, msgUUID string) {
			recalled = append(recalled, conversationID+"/"+msgUUID)
		},
	})
	if err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}

	data, gerr := handle(t, gw, "msg.recall", map[string]any{
		"conversation_id": conv, "msg_uuid": "mine",
	})
	if gerr != nil {
		t.Fatalf("撤回失败: %v", gerr)
	}
	if data.(map[string]any)["recalled"] != true {
		t.Fatalf("撤回结果错误: %+v", data)
	}
	if _, err := dao.GetMessage(context.Background(), "mine"); err == nil {
		t.Fatal("撤回后本机消息仍存在")
	}
	if len(recalled) != 1 || recalled[0] != conv+"/mine" {
		t.Fatalf("OnRecalled 回调错误: %+v", recalled)
	}

	// 群聊会话同样允许撤回己方 2 分钟内的消息（P6-14）。
	data, gerr = handle(t, gw, "msg.recall", map[string]any{
		"conversation_id": groupConv, "msg_uuid": "grp",
	})
	if gerr != nil {
		t.Fatalf("群聊撤回失败: %v", gerr)
	}
	if data.(map[string]any)["recalled"] != true {
		t.Fatalf("群聊撤回结果错误: %+v", data)
	}
	if _, err := dao.GetMessage(context.Background(), "grp"); err == nil {
		t.Fatal("群聊撤回后本机消息仍存在")
	}
	if len(recalled) != 2 || recalled[1] != groupConv+"/grp" {
		t.Fatalf("群聊 OnRecalled 回调错误: %+v", recalled)
	}

	cases := []struct {
		name   string
		params map[string]any
	}{
		{"超过 2 分钟", map[string]any{"conversation_id": conv, "msg_uuid": "old"}},
		{"他人消息", map[string]any{"conversation_id": conv, "msg_uuid": "theirs"}},
		{"未知会话", map[string]any{"conversation_id": "channel:g1", "msg_uuid": "theirs"}},
		{"未知消息", map[string]any{"conversation_id": conv, "msg_uuid": "missing"}},
		{"缺少 conversation_id", map[string]any{"msg_uuid": "theirs"}},
		{"缺少 msg_uuid", map[string]any{"conversation_id": conv}},
	}
	for _, c := range cases {
		if _, gerr := handle(t, gw, "msg.recall", c.params); gerr == nil ||
			gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("%s 期望 INVALID_ARG，实际 %v", c.name, gerr)
		}
	}
	if _, err := dao.GetMessage(context.Background(), "old"); err != nil {
		t.Fatal("超时消息不应被删除")
	}

	// 未注入 OnRecalled 时撤回仍成功（只做本地删除）。
	putTextMessage(t, dao, "mine2", conv, "再发一条", time.Now().UnixMilli(), store.DirectionOut)
	gw2 := gateway.New()
	if err := msg.Bind(gw2, &msg.Service{
		DAO: func() *store.DAO { return dao },
	}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	data, gerr = handle(t, gw2, "msg.recall", map[string]any{
		"conversation_id": conv, "msg_uuid": "mine2",
	})
	if gerr != nil {
		t.Fatalf("无回调撤回失败: %v", gerr)
	}
	if data.(map[string]any)["recalled"] != true {
		t.Fatalf("无回调撤回结果错误: %+v", data)
	}
	if _, err := dao.GetMessage(context.Background(), "mine2"); err == nil {
		t.Fatal("无回调撤回后本机消息仍存在")
	}

	stopped := gateway.New()
	if err := msg.Bind(stopped, &msg.Service{}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	if _, gerr := handle(t, stopped, "msg.recall", map[string]any{
		"conversation_id": conv, "msg_uuid": "x",
	}); gerr == nil || gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("内核未启动期望 NOT_STARTED，实际 %v", gerr)
	}
}

// TestDeleteMessage 覆盖 msg.delete（P6-11 长按 / 右键删除）：
// 删除后历史与检索都不再返回该条，跨会话与未知消息拒绝，缺参 INVALID_ARG，
// 内核未启动返回 NOT_STARTED。
func TestDeleteMessage(t *testing.T) {
	dao := openDAO(t)
	const conv = "dm:alice"
	const other = "dm:bob"
	putConversation(t, dao, conv, 0)
	putConversation(t, dao, other, 0)
	putTextMessage(t, dao, "keep", conv, "保留的内容", 1000, store.DirectionIn)
	putTextMessage(t, dao, "drop", conv, "待删除的内容", 2000, store.DirectionIn)
	putTextMessage(t, dao, "elsewhere", other, "其他会话的内容", 3000, store.DirectionIn)
	gw := bind(t, dao)

	searchHits := func(q string) []map[string]any {
		data, gerr := handle(t, gw, "msg.search", map[string]any{"q": q, "limit": 10})
		if gerr != nil {
			t.Fatalf("检索 %q 失败: %v", q, gerr)
		}
		return data.(map[string]any)["items"].([]map[string]any)
	}
	if hits := searchHits("待删除"); len(hits) != 1 {
		t.Fatalf("删除前应检索到 1 条，实际 %d", len(hits))
	}

	if _, gerr := handle(t, gw, "msg.delete", map[string]any{
		"conversation_id": conv, "msg_uuid": "drop",
	}); gerr != nil {
		t.Fatalf("删除消息失败: %v", gerr)
	}
	if _, err := dao.GetMessage(context.Background(), "drop"); err == nil {
		t.Fatal("删除后仍能读到消息")
	}
	listed, gerr := handle(t, gw, "msg.list", map[string]any{"conversation_id": conv, "limit": 10})
	if gerr != nil {
		t.Fatalf("读取历史失败: %v", gerr)
	}
	items := listed.(map[string]any)["items"].([]map[string]any)
	if len(items) != 1 || items[0]["msg_uuid"] != "keep" {
		t.Fatalf("删除后历史应为 1 条 keep，实际 %+v", items)
	}
	if hits := searchHits("待删除"); len(hits) != 0 {
		t.Fatalf("删除后仍能检索到 %d 条", len(hits))
	}
	// 其他会话的消息不受影响。
	if _, err := dao.GetMessage(context.Background(), "elsewhere"); err != nil {
		t.Fatalf("删除误伤其他会话: %v", err)
	}

	cases := []struct {
		name   string
		params map[string]any
	}{
		{"重复删除", map[string]any{"conversation_id": conv, "msg_uuid": "drop"}},
		{"未知消息", map[string]any{"conversation_id": conv, "msg_uuid": "missing"}},
		{"跨会话", map[string]any{"conversation_id": conv, "msg_uuid": "elsewhere"}},
		{"缺少 conversation_id", map[string]any{"msg_uuid": "keep"}},
		{"缺少 msg_uuid", map[string]any{"conversation_id": conv}},
	}
	for _, c := range cases {
		if _, gerr := handle(t, gw, "msg.delete", c.params); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("%s 期望 INVALID_ARG，实际 %v", c.name, gerr)
		}
	}

	stopped := gateway.New()
	if err := msg.Bind(stopped, &msg.Service{}); err != nil {
		t.Fatalf("接入消息服务: %v", err)
	}
	if _, gerr := handle(t, stopped, "msg.delete", map[string]any{
		"conversation_id": conv, "msg_uuid": "keep",
	}); gerr == nil || gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("内核未启动期望 NOT_STARTED，实际 %v", gerr)
	}
}
