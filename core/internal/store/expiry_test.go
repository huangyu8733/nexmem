package store

import (
	"context"
	"testing"
)

// TestDeleteExpiredMessages 验证定时消息按 expires_at 物理删除、返回事件标识、
// 同步清理全文索引，并保留未到期 messages。
func TestDeleteExpiredMessages(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	messages := []Message{
		{MsgUUID: "expired-1", SenderAccount: []byte("a"), ConversationID: "dm:a|b", SentAt: 1000, Direction: DirectionIn,
			ContentType: 0, BodyEnc: []byte{1}, State: MessageStateReceived, ExpiresAt: 2000,
			Body: "到期内容甲"},
		{MsgUUID: "expired-2", SenderAccount: []byte("b"), ConversationID: "group:g", SentAt: 1100, Direction: DirectionOut,
			ContentType: 0, BodyEnc: []byte{2}, State: MessageStateSent, ExpiresAt: 2500,
			Body: "到期内容乙"},
		{MsgUUID: "alive", SenderAccount: []byte("a"), ConversationID: "dm:a|b", SentAt: 1200, Direction: DirectionIn,
			ContentType: 0, BodyEnc: []byte{3}, State: MessageStateReceived, ExpiresAt: 9000,
			Body: "未到期内容"},
		{MsgUUID: "forever", SenderAccount: []byte("a"), ConversationID: "dm:a|b", SentAt: 1300, Direction: DirectionIn,
			ContentType: 0, BodyEnc: []byte{4}, State: MessageStateReceived, ExpiresAt: 0,
			Body: "永不过期内容"},
	}
	for _, m := range messages {
		if err := dao.PutMessage(ctx, m); err != nil {
			t.Fatalf("写入 %s 失败: %v", m.MsgUUID, err)
		}
	}

	expired, err := dao.DeleteExpiredMessages(ctx, 3000)
	if err != nil {
		t.Fatalf("清理到期消息失败: %v", err)
	}
	if len(expired) != 2 {
		t.Fatalf("到期消息数 = %d，期望 2", len(expired))
	}
	got := map[string]string{}
	for _, e := range expired {
		got[e.MsgUUID] = e.ConversationID
	}
	if got["expired-1"] != "dm:a|b" || got["expired-2"] != "group:g" {
		t.Fatalf("到期事件标识不正确: %+v", got)
	}

	for _, uuid := range []string{"expired-1", "expired-2"} {
		if _, err := dao.GetMessage(ctx, uuid); err == nil {
			t.Fatalf("到期消息 %s 应已被物理删除", uuid)
		}
	}
	for _, uuid := range []string{"alive", "forever"} {
		if _, err := dao.GetMessage(ctx, uuid); err != nil {
			t.Fatalf("未到期消息 %s 应保留，实际 %v", uuid, err)
		}
	}

	// 全文索引同步清理：已删除消息的 msg_uuid 不应残留在索引表中。
	var n int
	if err := dao.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM message_search WHERE msg_uuid IN ('expired-1','expired-2')`).Scan(&n); err != nil {
		t.Fatalf("查询全文索引失败: %v", err)
	}
	if n != 0 {
		t.Fatalf("到期消息的全文索引应清理，实际剩余 %d 条", n)
	}

	// 再次清理应为空（幂等）。
	again, err := dao.DeleteExpiredMessages(ctx, 3000)
	if err != nil || len(again) != 0 {
		t.Fatalf("重复清理应返回空，实际 %v / %v", again, err)
	}
}
