package dm

import (
	"context"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

// inboundMsg 构造一条格式合法的入站消息及其线上载荷。
func inboundMsg(t *testing.T, sender, receiver *testNode, text string, ts int64) (*nexmemv1.DirectMessage, []byte) {
	t.Helper()
	id, err := newUUIDv7(ts)
	if err != nil {
		t.Fatalf("生成消息 ID: %v", err)
	}
	inner, err := proto.Marshal(&nexmemv1.InnerMessage{Text: text})
	if err != nil {
		t.Fatalf("序列化正文: %v", err)
	}
	msg := &nexmemv1.DirectMessage{
		MsgUuid:         id,
		Timestamp:       ts,
		SenderAccount:   sender.account.Pub(),
		ReceiverAccount: receiver.account.Pub(),
		ConversationId:  []byte(ConversationID(receiver.account.Pub(), sender.account.Pub())),
		ContentType:     nexmemv1.ContentType_CONTENT_TYPE_TEXT,
		Inner:           inner,
	}
	payload, err := proto.Marshal(msg)
	if err != nil {
		t.Fatalf("序列化消息: %v", err)
	}
	return msg, payload
}

// TestAcceptInboundDuplicateOnlyOnce 是 P2-02 的验收用例：同一 msg_uuid 投递 10 次只入库 1 条，
// 未读数只加 1，且首次返回 AckOK、其余返回 AckDup。
func TestAcceptInboundDuplicateOnlyOnce(t *testing.T) {
	a := newTestNode(t, "A")
	b := newTestNode(t, "B")
	ctx := context.Background()

	msg, payload := inboundMsg(t, a, b, "hello", time.Now().UnixMilli())
	convID := ConversationID(a.account.Pub(), b.account.Pub())

	for i := 0; i < 10; i++ {
		code := b.svc.acceptInbound(ctx, msg, payload)
		want := AckDup
		if i == 0 {
			want = AckOK
		}
		if code != want {
			t.Fatalf("第 %d 次投递 ACK 码应为 %d，实际 %d", i+1, want, code)
		}
	}
	if n, err := b.dao.CountMessages(ctx, convID); err != nil || n != 1 {
		t.Fatalf("重复投递后应只有 1 条消息，实际 %d 条 (err=%v)", n, err)
	}
	conv, err := b.dao.GetConversation(ctx, convID)
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if conv.Unread != 1 {
		t.Fatalf("未读数应为 1，实际 %d", conv.Unread)
	}
}

// TestAcceptInboundConcurrentDuplicates 验证并发重复帧也不会重复入库或重复计未读。
func TestAcceptInboundConcurrentDuplicates(t *testing.T) {
	a := newTestNode(t, "A")
	b := newTestNode(t, "B")
	ctx := context.Background()

	msg, payload := inboundMsg(t, a, b, "concurrent", time.Now().UnixMilli())
	convID := ConversationID(a.account.Pub(), b.account.Pub())

	const workers = 10
	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		count = map[int32]int{}
	)
	start := make(chan struct{})
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			code := b.svc.acceptInbound(ctx, msg, payload)
			mu.Lock()
			count[code]++
			mu.Unlock()
		}()
	}
	close(start)
	wg.Wait()

	if count[AckOK] != 1 || count[AckDup] != workers-1 {
		t.Fatalf("并发受理结果异常: OK=%d DUP=%d", count[AckOK], count[AckDup])
	}
	if n, err := b.dao.CountMessages(ctx, convID); err != nil || n != 1 {
		t.Fatalf("并重复投递后应只有 1 条消息，实际 %d 条 (err=%v)", n, err)
	}
	conv, err := b.dao.GetConversation(ctx, convID)
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if conv.Unread != 1 {
		t.Fatalf("未读数应为 1，实际 %d", conv.Unread)
	}
}

// TestAcceptInboundOutOfOrderSorted 验证乱序到达后仍按发送时间正确排序。
func TestAcceptInboundOutOfOrderSorted(t *testing.T) {
	a := newTestNode(t, "A")
	b := newTestNode(t, "B")
	ctx := context.Background()

	base := time.Now().UnixMilli() - 10_000
	type item struct {
		msg    *nexmemv1.DirectMessage
		body   []byte
		text   string
		offset int64
	}
	items := []item{
		{text: "third", offset: 300},
		{text: "first", offset: 100},
		{text: "fourth", offset: 400},
		{text: "second", offset: 200},
	}
	for i := range items {
		items[i].msg, items[i].body = inboundMsg(t, a, b, items[i].text, base+items[i].offset)
	}
	for _, it := range items {
		if code := b.svc.acceptInbound(ctx, it.msg, it.body); code != AckOK {
			t.Fatalf("受理 %q 失败，ACK=%d", it.text, code)
		}
	}

	convID := ConversationID(a.account.Pub(), b.account.Pub())
	asc := listAscending(t, b.dao, convID)
	if len(asc) != len(items) {
		t.Fatalf("应读到 %d 条，实际 %d 条", len(items), len(asc))
	}
	want := []string{"first", "second", "third", "fourth"}
	for i, m := range asc {
		var inner nexmemv1.InnerMessage
		if err := proto.Unmarshal(m.BodyEnc, &inner); err != nil {
			t.Fatalf("第 %d 条正文解析失败: %v", i, err)
		}
		if inner.GetText() != want[i] {
			t.Fatalf("第 %d 条顺序错误：实际 %q，期望 %q", i, inner.GetText(), want[i])
		}
	}

	conv, err := b.dao.GetConversation(ctx, convID)
	if err != nil {
		t.Fatalf("读取会话: %v", err)
	}
	if conv.LastMsgAt != base+400 {
		t.Fatalf("会话最近消息时间应为 %d，实际 %d", base+400, conv.LastMsgAt)
	}
}

// TestAcceptInboundReplayAfterDelete 验证本地消息被清理后，同一帧重放仍会被内存窗口拒绝。
func TestAcceptInboundReplayAfterDelete(t *testing.T) {
	a := newTestNode(t, "A")
	b := newTestNode(t, "B")
	ctx := context.Background()

	msg, payload := inboundMsg(t, a, b, "replay", time.Now().UnixMilli())
	convID := ConversationID(a.account.Pub(), b.account.Pub())

	if code := b.svc.acceptInbound(ctx, msg, payload); code != AckOK {
		t.Fatalf("首次受理失败，ACK=%d", code)
	}
	if err := b.dao.DeleteMessage(ctx, msg.GetMsgUuid()); err != nil {
		t.Fatalf("删除消息: %v", err)
	}
	if code := b.svc.acceptInbound(ctx, msg, payload); code != AckDup {
		t.Fatalf("重放应返回 AckDup，实际 %d", code)
	}
	if n, err := b.dao.CountMessages(ctx, convID); err != nil || n != 0 {
		t.Fatalf("重放不应重新入库，实际 %d 条 (err=%v)", n, err)
	}
}

// TestReplayGuardExpiryAndCapacity 覆盖重放窗口的过期与容量淘汰。
func TestReplayGuardExpiryAndCapacity(t *testing.T) {
	g := newReplayGuard(30*time.Millisecond, 2)
	g.mark("a")
	if !g.check("a") {
		t.Fatalf("刚受理的消息应在窗口内")
	}
	time.Sleep(50 * time.Millisecond)
	if g.check("a") {
		t.Fatalf("超出 TTL 后应不再命中")
	}

	g.mark("b")
	g.mark("c")
	g.mark("d") // 容量 2，应淘汰 b
	if g.check("b") {
		t.Fatalf("超出容量后最旧条目应被淘汰")
	}
	if !g.check("c") || !g.check("d") {
		t.Fatalf("最近条目应仍在窗口内")
	}
}
