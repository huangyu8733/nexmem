package coreapp

import (
	"bytes"
	"context"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/group"
	"github.com/nexmem/core/internal/store"
)

// TestApplyGroupRecall 覆盖 P6-14 群撤回的本地应用规则：
// 只删除撤回发送者本人的入站消息，跨群、他人消息与已删除消息都忽略。
func TestApplyGroupRecall(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	if err := store.Migrate(ctx, db); err != nil {
		t.Fatalf("迁移数据库: %v", err)
	}
	dao := store.NewDAO(db)

	groupID := bytes.Repeat([]byte{0xAB}, 16)
	otherGroupID := bytes.Repeat([]byte{0xCD}, 16)
	conv := groupConversationID(groupID)
	if err := dao.EnsureConversation(ctx, store.Conversation{
		ID: conv, Kind: store.ConversationKindGroup, Title: "测试群",
	}); err != nil {
		t.Fatalf("写入群会话: %v", err)
	}
	sender := bytes.Repeat([]byte{0x01}, 32)
	other := bytes.Repeat([]byte{0x02}, 32)
	const target = "00112233445566778899aabbccddeeff"
	put := func(uuid string, convID string, account []byte, direction int) {
		t.Helper()
		inner, err := proto.Marshal(&nexmemv1.InnerMessage{Text: "原文"})
		if err != nil {
			t.Fatalf("编码消息正文: %v", err)
		}
		if err := dao.PutMessage(ctx, store.Message{
			MsgUUID:        uuid,
			ConversationID: convID,
			SenderAccount:  account,
			SentAt:         1,
			Direction:      direction,
			State:          store.MessageStateReceived,
			BodyEnc:        inner,
			Body:           "原文",
		}); err != nil {
			t.Fatalf("写入消息 %s: %v", uuid, err)
		}
	}
	put(target, conv, sender, store.DirectionIn)

	// 非本人发送的撤回帧不得删除消息。
	ok, err := applyGroupRecall(ctx, dao, group.Received{
		GroupID: groupID, SenderAccount: other,
	}, target)
	if err != nil || ok {
		t.Fatalf("他人撤回帧应被忽略: ok=%v err=%v", ok, err)
	}
	if _, err := dao.GetMessage(ctx, target); err != nil {
		t.Fatalf("他人撤回帧不应删除消息: %v", err)
	}

	// 撤回帧来自本人时删除并返回命中。
	ok, err = applyGroupRecall(ctx, dao, group.Received{
		GroupID: groupID, SenderAccount: sender,
	}, target)
	if err != nil || !ok {
		t.Fatalf("本人撤回帧未生效: ok=%v err=%v", ok, err)
	}
	if _, err := dao.GetMessage(ctx, target); err == nil {
		t.Fatal("撤回后消息仍存在")
	}

	// 目标不存在、跨群与会话外消息都按未命中处理。
	if ok, err := applyGroupRecall(ctx, dao, group.Received{
		GroupID: otherGroupID, SenderAccount: sender,
	}, target); err != nil || ok {
		t.Fatalf("已删除消息应返回未命中: ok=%v err=%v", ok, err)
	}
	const outbound = "ffeeddccbbaa99887766554433221100"
	put(outbound, conv, sender, store.DirectionOut)
	if ok, err := applyGroupRecall(ctx, dao, group.Received{
		GroupID: groupID, SenderAccount: sender,
	}, outbound); err != nil || ok {
		t.Fatalf("本机出站消息不应被入站撤回帧删除: ok=%v err=%v", ok, err)
	}
}
