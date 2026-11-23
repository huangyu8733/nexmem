package store

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
)

func newTestDAO(t *testing.T) *DAO {
	t.Helper()
	db, err := Open(filepath.Join(t.TempDir(), "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := Migrate(context.Background(), db); err != nil {
		db.Close()
		t.Fatalf("迁移失败: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return NewDAO(db)
}

func TestMessagePagination(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	const total = 25
	for i := 0; i < total; i++ {
		if err := dao.PutMessage(ctx, Message{
			MsgUUID:        fmt.Sprintf("m%02d", i),
			ConversationID: "dm:alice|bob",
			SenderAccount:  []byte("alice"),
			SentAt:         int64(1000 + i),
			Direction:      DirectionOut,
			ContentType:    0,
			BodyEnc:        []byte{byte(i)},
			State:          MessageStateAcked,
		}); err != nil {
			t.Fatalf("写入第 %d 条消息失败: %v", i, err)
		}
	}

	seen := make(map[string]bool)
	var cursor *MessageCursor
	pages := 0
	for {
		page, err := dao.ListMessages(ctx, "dm:alice|bob", cursor, 10)
		if err != nil {
			t.Fatalf("分页查询失败: %v", err)
		}
		if len(page) == 0 {
			break
		}
		pages++
		for i, m := range page {
			if seen[m.MsgUUID] {
				t.Fatalf("消息 %s 重复出现", m.MsgUUID)
			}
			seen[m.MsgUUID] = true
			if i > 0 && m.SentAt > page[i-1].SentAt {
				t.Fatalf("分页未按时间倒序: %d -> %d", page[i-1].SentAt, m.SentAt)
			}
		}
		last := page[len(page)-1]
		cursor = &MessageCursor{SentAt: last.SentAt, MsgUUID: last.MsgUUID}
	}
	if pages != 3 {
		t.Fatalf("25 条消息按 10 条分页应为 3 页, 实际 %d", pages)
	}
	if len(seen) != total {
		t.Fatalf("应遍历到 %d 条消息, 实际 %d", total, len(seen))
	}

	first, err := dao.ListMessages(ctx, "dm:alice|bob", nil, 10)
	if err != nil {
		t.Fatal(err)
	}
	if first[0].MsgUUID != "m24" {
		t.Fatalf("首页第一条应是最新消息 m24, 实际 %s", first[0].MsgUUID)
	}

	if n, err := dao.CountMessages(ctx, "dm:alice|bob"); err != nil || n != total {
		t.Fatalf("消息计数应为 %d, 实际 %d (err=%v)", total, n, err)
	}
}

func TestMessageUpsertAndDelete(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	m := Message{
		MsgUUID:        "u1",
		ConversationID: "dm:a|b",
		SenderAccount:  []byte("a"),
		SentAt:         10,
		Direction:      DirectionOut,
		ContentType:    0,
		BodyEnc:        []byte("v1"),
		State:          MessageStatePending,
	}
	if err := dao.PutMessage(ctx, m); err != nil {
		t.Fatal(err)
	}

	m.BodyEnc = []byte("v2")
	m.State = MessageStateAcked
	if err := dao.PutMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	got, err := dao.GetMessage(ctx, "u1")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.BodyEnc, []byte("v2")) || got.State != MessageStateAcked {
		t.Fatalf("幂等写入应更新密文与状态, 实际 body=%q state=%d", got.BodyEnc, got.State)
	}

	if err := dao.UpdateMessageState(ctx, "missing", MessageStateFailed); !errors.Is(err, ErrNotFound) {
		t.Fatalf("更新不存在消息应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.DeleteMessage(ctx, "u1"); err != nil {
		t.Fatal(err)
	}
	if _, err := dao.GetMessage(ctx, "u1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("删除后应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.DeleteMessage(ctx, "u1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound, 实际 %v", err)
	}
}

// TestMessageSeqMonotonic 覆盖消息序号单调递增、重复写入不变与删除后不回退。
func TestMessageSeqMonotonic(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	put := func(id, body string, sentAt int64) int64 {
		t.Helper()
		if err := dao.PutMessage(ctx, Message{
			MsgUUID:        id,
			ConversationID: "dm:a|b",
			SenderAccount:  []byte("a"),
			SentAt:         sentAt,
			Direction:      DirectionOut,
			BodyEnc:        []byte(body),
			State:          MessageStateAcked,
		}); err != nil {
			t.Fatalf("写入消息 %s 失败: %v", id, err)
		}
		m, err := dao.GetMessage(ctx, id)
		if err != nil {
			t.Fatalf("读取消息 %s 失败: %v", id, err)
		}
		return m.Seq
	}

	first := put("m1", "v1", 100)
	second := put("m2", "v2", 200)
	if second <= first {
		t.Fatalf("序号应严格递增, 实际 %d -> %d", first, second)
	}

	// 幂等重写同一 msg_uuid 不得换号，否则客户端游标会漏消息。
	if again := put("m1", "v1-updated", 300); again != first {
		t.Fatalf("重复写入应保留原序号 %d, 实际 %d", first, again)
	}

	// 删除最新消息后新消息必须拿更大的号，避免客户端 after_seq 回退。
	if err := dao.DeleteMessage(ctx, "m2"); err != nil {
		t.Fatalf("删除消息失败: %v", err)
	}
	third := put("m3", "v3", 400)
	if third <= second {
		t.Fatalf("删除后新消息序号应大于历史最大值 %d, 实际 %d", second, third)
	}

	// 入站幂等受理路径同样分配序号。
	inserted, err := dao.AcceptInboundMessage(ctx, ConversationKindDM, Message{
		MsgUUID:        "in1",
		ConversationID: "dm:a|b",
		SenderAccount:  []byte("b"),
		SentAt:         500,
		Direction:      DirectionIn,
		BodyEnc:        []byte("hi"),
		State:          MessageStateReceived,
	})
	if err != nil || !inserted {
		t.Fatalf("受理入站消息失败: inserted=%v err=%v", inserted, err)
	}
	in, err := dao.GetMessage(ctx, "in1")
	if err != nil {
		t.Fatal(err)
	}
	if in.Seq <= third {
		t.Fatalf("入站消息序号应大于 %d, 实际 %d", third, in.Seq)
	}
}

// TestListMessagesSince 覆盖按 seq 升序增量读取、会话隔离与条数截断。
func TestListMessagesSince(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	for _, m := range []struct {
		id   string
		conv string
	}{
		{"a1", "dm:a|b"},
		{"b1", "dm:a|c"},
		{"a2", "dm:a|b"},
		{"a3", "dm:a|b"},
	} {
		if err := dao.PutMessage(ctx, Message{
			MsgUUID:        m.id,
			ConversationID: m.conv,
			SenderAccount:  []byte("a"),
			SentAt:         100,
			Direction:      DirectionOut,
			BodyEnc:        []byte(m.id),
			State:          MessageStateAcked,
		}); err != nil {
			t.Fatalf("写入消息 %s 失败: %v", m.id, err)
		}
	}

	all, err := dao.ListMessagesSince(ctx, "dm:a|b", 0, 10)
	if err != nil {
		t.Fatalf("增量查询失败: %v", err)
	}
	if len(all) != 3 || all[0].MsgUUID != "a1" || all[1].MsgUUID != "a2" || all[2].MsgUUID != "a3" {
		t.Fatalf("增量结果或顺序错误: %+v", all)
	}

	tail, err := dao.ListMessagesSince(ctx, "dm:a|b", all[1].Seq, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail) != 1 || tail[0].MsgUUID != "a3" {
		t.Fatalf("按 after_seq 续读错误: %+v", tail)
	}

	limited, err := dao.ListMessagesSince(ctx, "dm:a|b", 0, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(limited) != 2 || limited[0].MsgUUID != "a1" || limited[1].MsgUUID != "a2" {
		t.Fatalf("条数截断错误: %+v", limited)
	}

	empty, err := dao.ListMessagesSince(ctx, "dm:none", 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(empty) != 0 {
		t.Fatalf("未知会话应返回空列表, 实际 %d 条", len(empty))
	}
}

func TestConversationCRUD(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	convs := []Conversation{
		{ID: "dm:a|b", Kind: ConversationKindDM, Title: "", LastMsgAt: 100},
		{ID: "group:g1", Kind: ConversationKindGroup, Title: "研发群", LastMsgAt: 200, Unread: 3},
		{ID: "dm:a|c", Kind: ConversationKindDM, Title: "老同学", LastMsgAt: 0},
	}
	for _, c := range convs {
		if err := dao.UpsertConversation(ctx, c); err != nil {
			t.Fatalf("写入会话 %s 失败: %v", c.ID, err)
		}
	}

	list, err := dao.ListConversations(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	wantOrder := []string{"group:g1", "dm:a|b", "dm:a|c"}
	if len(list) != len(wantOrder) {
		t.Fatalf("会话数应为 %d, 实际 %d", len(wantOrder), len(list))
	}
	for i, id := range wantOrder {
		if list[i].ID != id {
			t.Fatalf("第 %d 个会话应为 %s, 实际 %s", i, id, list[i].ID)
		}
	}

	if err := dao.TouchConversation(ctx, "dm:a|c", 300); err != nil {
		t.Fatal(err)
	}
	if err := dao.TouchConversation(ctx, "dm:a|c", 50); err != nil {
		t.Fatal(err)
	}
	c, err := dao.GetConversation(ctx, "dm:a|c")
	if err != nil {
		t.Fatal(err)
	}
	if c.LastMsgAt != 300 {
		t.Fatalf("最近消息时间只增不减, 期望 300, 实际 %d", c.LastMsgAt)
	}

	if err := dao.SetConversationUnread(ctx, "dm:a|c", 7); err != nil {
		t.Fatal(err)
	}
	if c, err = dao.GetConversation(ctx, "dm:a|c"); err != nil || c.Unread != 7 {
		t.Fatalf("未读数应为 7, 实际 %d (err=%v)", c.Unread, err)
	}

	if _, err := dao.GetConversation(ctx, "missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在会话应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.TouchConversation(ctx, "missing", 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("更新不存在会话应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.DeleteConversation(ctx, "dm:a|b"); err != nil {
		t.Fatal(err)
	}
	if err := dao.DeleteConversation(ctx, "dm:a|b"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound, 实际 %v", err)
	}
}

func TestInboxCursor(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	if _, err := dao.GetCursor(ctx, "dm:bob"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在游标应返回 ErrNotFound, 实际 %v", err)
	}
	cur := InboxCursor{Scope: "dm:bob", ObjectKey: "inbox/bob/1.json", ETag: "e1", SeenAt: 100}
	if err := dao.PutCursor(ctx, cur); err != nil {
		t.Fatal(err)
	}
	cur.ObjectKey = "inbox/bob/2.json"
	cur.ETag = "e2"
	cur.SeenAt = 200
	if err := dao.PutCursor(ctx, cur); err != nil {
		t.Fatal(err)
	}
	got, err := dao.GetCursor(ctx, "dm:bob")
	if err != nil {
		t.Fatal(err)
	}
	if got.ObjectKey != cur.ObjectKey || got.ETag != cur.ETag || got.SeenAt != 200 {
		t.Fatalf("游标更新失败: %+v", got)
	}
	list, err := dao.ListCursors(ctx)
	if err != nil || len(list) != 1 {
		t.Fatalf("游标列表应有 1 条, 实际 %d (err=%v)", len(list), err)
	}
	if err := dao.DeleteCursor(ctx, "dm:bob"); err != nil {
		t.Fatal(err)
	}
	if err := dao.DeleteCursor(ctx, "dm:bob"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound, 实际 %v", err)
	}
}

func TestGroupAndMembers(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	g := Group{
		GroupID:        []byte("g1"),
		Title:          "研发群",
		MyRole:         1,
		KeyVersion:     2,
		GroupKeyEnc:    []byte("enc-key"),
		StorageCfgEnc:  []byte("enc-cfg"),
		OfflineEnabled: true,
	}
	if err := dao.PutGroup(ctx, g); err != nil {
		t.Fatal(err)
	}
	got, err := dao.GetGroup(ctx, []byte("g1"))
	if err != nil {
		t.Fatal(err)
	}
	if got.Title != "研发群" || got.KeyVersion != 2 || !got.OfflineEnabled || !bytes.Equal(got.GroupKeyEnc, []byte("enc-key")) {
		t.Fatalf("群记录读取不一致: %+v", got)
	}

	members := []GroupMember{
		{AccountPub: []byte("a"), Role: 1, JoinedAt: 10},
		{AccountPub: []byte("b"), Role: 0, JoinedAt: 20},
		{AccountPub: []byte("c"), Role: 0, JoinedAt: 30},
	}
	if err := dao.ReplaceMembers(ctx, []byte("g1"), members); err != nil {
		t.Fatal(err)
	}
	list, err := dao.ListMembers(ctx, []byte("g1"))
	if err != nil || len(list) != 3 {
		t.Fatalf("群成员应为 3 人, 实际 %d (err=%v)", len(list), err)
	}
	if list[0].AccountPub[0] != 'a' || list[2].AccountPub[0] != 'c' {
		t.Fatalf("群成员应按加入时间排序: %+v", list)
	}

	if err := dao.ReplaceMembers(ctx, []byte("g1"), members[:1]); err != nil {
		t.Fatal(err)
	}
	if list, err = dao.ListMembers(ctx, []byte("g1")); err != nil || len(list) != 1 {
		t.Fatalf("整体替换后应剩 1 人, 实际 %d (err=%v)", len(list), err)
	}

	if err := dao.PutGroupKey(ctx, []byte("g1"), 1, []byte("enc-v1")); err != nil {
		t.Fatal(err)
	}
	if err := dao.PutGroupKey(ctx, []byte("g1"), 2, []byte("enc-v2")); err != nil {
		t.Fatal(err)
	}
	// 同版本覆盖写入应保持幂等。
	if err := dao.PutGroupKey(ctx, []byte("g1"), 2, []byte("enc-v2b")); err != nil {
		t.Fatal(err)
	}
	keys, err := dao.ListGroupKeys(ctx, []byte("g1"))
	if err != nil || len(keys) != 2 {
		t.Fatalf("群密钥应为 2 个版本, 实际 %d (err=%v)", len(keys), err)
	}
	if keys[0].Version != 1 || keys[1].Version != 2 || !bytes.Equal(keys[1].KeyEnc, []byte("enc-v2b")) {
		t.Fatalf("群密钥版本或内容不符: %+v", keys)
	}

	if err := dao.DeleteGroup(ctx, []byte("g1")); err != nil {
		t.Fatal(err)
	}
	if _, err := dao.GetGroup(ctx, []byte("g1")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("删除后应返回 ErrNotFound, 实际 %v", err)
	}
	if list, err = dao.ListMembers(ctx, []byte("g1")); err != nil || len(list) != 0 {
		t.Fatalf("删群后成员应为空, 实际 %d (err=%v)", len(list), err)
	}
	if keys, err = dao.ListGroupKeys(ctx, []byte("g1")); err != nil || len(keys) != 0 {
		t.Fatalf("删群后密钥应为空, 实际 %d (err=%v)", len(keys), err)
	}
	if err := dao.DeleteGroup(ctx, []byte("g1")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复删群应返回 ErrNotFound, 实际 %v", err)
	}
}

func TestKV(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	if _, err := dao.GetKV(ctx, "theme"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在配置应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.SetKV(ctx, "theme", []byte("dark")); err != nil {
		t.Fatal(err)
	}
	if err := dao.SetKV(ctx, "theme", []byte("light")); err != nil {
		t.Fatal(err)
	}
	v, err := dao.GetKV(ctx, "theme")
	if err != nil || string(v) != "light" {
		t.Fatalf("配置应为 light, 实际 %q (err=%v)", v, err)
	}
	if err := dao.DeleteKV(ctx, "theme"); err != nil {
		t.Fatal(err)
	}
	if err := dao.DeleteKV(ctx, "theme"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound, 实际 %v", err)
	}
}
