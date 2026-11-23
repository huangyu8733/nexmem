package store

import (
	"context"
	"testing"
)

// TestMarkConversationRead 覆盖 P6-07：按水位把出站已发送/已送达消息置为已读，
// 跳过失败、待发送、入站以及水位之后的消息。
func TestMarkConversationRead(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)
	const conv = "dm:alice|bob"

	msgs := []Message{
		{MsgUUID: "m1", SentAt: 1000, Direction: DirectionOut, State: MessageStateSent},
		{MsgUUID: "m2", SentAt: 2000, Direction: DirectionOut, State: MessageStateAcked},
		{MsgUUID: "m3", SentAt: 3000, Direction: DirectionOut, State: MessageStateSent},
		{MsgUUID: "m4", SentAt: 2500, Direction: DirectionIn, State: MessageStateReceived},
		{MsgUUID: "m5", SentAt: 500, Direction: DirectionOut, State: MessageStateFailed},
		{MsgUUID: "m6", SentAt: 1500, Direction: DirectionOut, State: MessageStatePending},
	}
	for _, m := range msgs {
		m.ConversationID = conv
		m.SenderAccount = []byte("sender")
		m.ContentType = 0
		m.BodyEnc = []byte(m.MsgUUID)
		if err := dao.PutMessage(ctx, m); err != nil {
			t.Fatalf("写入消息 %s: %v", m.MsgUUID, err)
		}
	}

	changed, err := dao.MarkConversationRead(ctx, conv, 2000)
	if err != nil {
		t.Fatalf("推进已读: %v", err)
	}
	if len(changed) != 2 {
		t.Fatalf("水位 2000 应推进 2 条，实际 %v", changed)
	}
	wantRead := map[string]bool{"m1": true, "m2": true}
	for _, id := range changed {
		if !wantRead[id] {
			t.Fatalf("不应推进 %s", id)
		}
		delete(wantRead, id)
	}
	if len(wantRead) != 0 {
		t.Fatalf("漏推进: %v", wantRead)
	}

	states := map[string]int{}
	for _, m := range msgs {
		got, err := dao.GetMessage(ctx, m.MsgUUID)
		if err != nil {
			t.Fatalf("读取消息 %s: %v", m.MsgUUID, err)
		}
		states[m.MsgUUID] = got.State
	}
	want := map[string]int{
		"m1": MessageStateRead,
		"m2": MessageStateRead,
		"m3": MessageStateSent,
		"m4": MessageStateReceived,
		"m5": MessageStateFailed,
		"m6": MessageStatePending,
	}
	for id, state := range want {
		if states[id] != state {
			t.Fatalf("消息 %s 状态 = %d, 期望 %d", id, states[id], state)
		}
	}

	again, err := dao.MarkConversationRead(ctx, conv, 2000)
	if err != nil {
		t.Fatalf("重复推进已读: %v", err)
	}
	if len(again) != 0 {
		t.Fatalf("重复推进不应产生变化，实际 %v", again)
	}
}

// TestLatestInboundAt 覆盖已读回执水位：只统计入站消息，并支持时间上限。
func TestLatestInboundAt(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)
	const conv = "dm:alice|bob"

	for _, m := range []Message{
		{MsgUUID: "in1", SentAt: 1200, Direction: DirectionIn, State: MessageStateReceived},
		{MsgUUID: "in2", SentAt: 2600, Direction: DirectionIn, State: MessageStateReceived},
		{MsgUUID: "out1", SentAt: 4000, Direction: DirectionOut, State: MessageStateAcked},
	} {
		m.ConversationID = conv
		m.SenderAccount = []byte("sender")
		m.BodyEnc = []byte(m.MsgUUID)
		if err := dao.PutMessage(ctx, m); err != nil {
			t.Fatalf("写入消息 %s: %v", m.MsgUUID, err)
		}
	}

	at, err := dao.LatestInboundAt(ctx, conv, 0)
	if err != nil || at != 2600 {
		t.Fatalf("入站水位 = %d (err=%v), 期望 2600", at, err)
	}
	at, err = dao.LatestInboundAt(ctx, conv, 2000)
	if err != nil || at != 1200 {
		t.Fatalf("上限 2000 时入站水位 = %d (err=%v), 期望 1200", at, err)
	}
	at, err = dao.LatestInboundAt(ctx, conv, 1000)
	if err != nil || at != 0 {
		t.Fatalf("上限 1000 时入站水位 = %d (err=%v), 期望 0", at, err)
	}
	at, err = dao.LatestInboundAt(ctx, "dm:none|none", 0)
	if err != nil || at != 0 {
		t.Fatalf("空会话水位 = %d (err=%v), 期望 0", at, err)
	}
}
