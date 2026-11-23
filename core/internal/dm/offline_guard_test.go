package dm

import (
	"context"
	"sort"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/diag"
	"github.com/nexmem/core/internal/identity"
)

// TestOfflineFetchRejectReasons 校验超限、串号、过期与篡改对象各自产生明确的丢弃原因，
// 并写入结构化诊断日志。
func TestOfflineFetchRejectReasons(t *testing.T) {
	senderAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成发送方账号: %v", err)
	}
	recvAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}
	otherAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成第三方账号: %v", err)
	}

	inbox := newFakeInbox()
	prefix := blob.InboxPrefix(recvAcc.Pub())
	now := time.Now()

	// 1. 密文被篡改 → 签名校验失败。
	tampered := buildOfflinePayload(t, senderAcc, recvAcc, "m-tampered", "x", now, 24)
	off := &nexmemv1.OfflineMessage{}
	if err := proto.Unmarshal(tampered, off); err != nil {
		t.Fatalf("解析离线消息: %v", err)
	}
	off.Ciphertext[0] ^= 0xff
	tampered, _ = proto.Marshal(off)
	inbox.Put(prefix+"r1.msg", tampered, now)

	// 2. 接收方不是本账号 → not_owner。
	misdirected := buildOfflinePayload(t, senderAcc, recvAcc, "m-misdirected", "x", now, 24)
	off = &nexmemv1.OfflineMessage{}
	_ = proto.Unmarshal(misdirected, off)
	off.ReceiverAccount = otherAcc.Pub()
	misdirected, _ = proto.Marshal(off)
	inbox.Put(prefix+"r2.msg", misdirected, now)

	// 3. TTL 已过期 → expired（重新签名以保证只命中过期分支）。
	expired := buildOfflinePayload(t, senderAcc, recvAcc, "m-expired", "x", now.Add(-48*time.Hour), 24)
	inbox.Put(prefix+"r3.msg", expired, now)

	// 4. 超出单对象上限 → oversize（不拉取正文）。
	oversize := make([]byte, MaxOfflineObjectSize+1)
	inbox.Put(prefix+"r4.msg", oversize, now)

	logger := diag.New(diag.WithBufferSize(64))
	var mu sync.Mutex
	var events []OfflineRejectEvent
	recv := newTestNode(t, "R", func(o *Options) {
		o.Account = recvAcc
		o.Inbox = inbox
		o.DisableAutoFetch = true
		o.Diag = logger
		o.OnOfflineReject = func(ev OfflineRejectEvent) {
			mu.Lock()
			events = append(events, ev)
			mu.Unlock()
		}
	})

	rep, err := recv.svc.FetchOffline(context.Background())
	if err != nil {
		t.Fatalf("拉取离线消息: %v", err)
	}
	if rep.Imported != 0 || rep.Skipped != 4 || rep.Failed != 0 {
		t.Fatalf("应全部丢弃（导入 0、跳过 4、失败 0），实际 %+v", rep)
	}

	mu.Lock()
	got := append([]OfflineRejectEvent(nil), events...)
	mu.Unlock()
	if len(got) != 4 {
		t.Fatalf("应记录 4 条丢弃事件，实际 %d: %+v", len(got), got)
	}
	reasons := make([]string, 0, len(got))
	for _, ev := range got {
		if ev.ObjectKey == "" || ev.Size <= 0 {
			t.Fatalf("事件缺少对象定位信息: %+v", ev)
		}
		reasons = append(reasons, string(ev.Reason))
	}
	sort.Strings(reasons)
	want := []string{"expired", "not_owner", "oversize", "signature"}
	for i := range want {
		if reasons[i] != want[i] {
			t.Fatalf("丢弃原因 %v，期望 %v", reasons, want)
		}
	}

	logs := logger.Recent(0)
	if len(logs) != 4 {
		t.Fatalf("应写入 4 条诊断日志，实际 %d", len(logs))
	}
	for _, rec := range logs {
		if rec.Module != OfflineRejectModule || rec.Level != "warn" {
			t.Fatalf("诊断日志字段不符: %+v", rec)
		}
		if _, ok := rec.Fields["reason"]; !ok {
			t.Fatalf("诊断日志缺少 reason 字段: %+v", rec)
		}
	}

	// 丢弃对象不得入库，游标仍需推进。
	convID := ConversationID(recvAcc.Pub(), senderAcc.Pub())
	if n, _ := recv.dao.CountMessages(context.Background(), convID); n != 0 {
		t.Fatalf("非法对象不应入库，实际 %d", n)
	}
	if cur, err := recv.dao.GetCursor(context.Background(), OfflineScope(recvAcc.Pub())); err != nil || cur.SeenAt == 0 {
		t.Fatalf("游标未推进: %+v err=%v", cur, err)
	}
}

// TestOfflineGuardSelfAndConversation 校验自发自收与错误会话 ID 被分别归类。
func TestOfflineGuardSelfAndConversation(t *testing.T) {
	senderAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成发送方账号: %v", err)
	}
	recvAcc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成接收方账号: %v", err)
	}

	inbox := newFakeInbox()
	prefix := blob.InboxPrefix(recvAcc.Pub())
	now := time.Now()

	// 自收自发：本机既是发送方也是接收方。
	self := buildOfflinePayload(t, recvAcc, recvAcc, "m-self", "x", now, 24)
	inbox.Put(prefix+"s1.msg", self, now)

	// 会话 ID 与双方账号不符，需要重新签名使签名仍然有效。
	mismatch := buildOfflinePayload(t, senderAcc, recvAcc, "m-conv", "x", now, 24)
	off := &nexmemv1.OfflineMessage{}
	if err := proto.Unmarshal(mismatch, off); err != nil {
		t.Fatalf("解析离线消息: %v", err)
	}
	off.ConversationId = []byte("conv-other")
	if err := senderAcc.SignOfflineMessage(off); err != nil {
		t.Fatalf("重新签名: %v", err)
	}
	mismatch, _ = proto.Marshal(off)
	inbox.Put(prefix+"s2.msg", mismatch, now)

	var reasons []OfflineRejectReason
	recv := newTestNode(t, "R", func(o *Options) {
		o.Account = recvAcc
		o.Inbox = inbox
		o.DisableAutoFetch = true
		o.OnOfflineReject = func(ev OfflineRejectEvent) {
			reasons = append(reasons, ev.Reason)
		}
	})

	if _, err := recv.svc.FetchOffline(context.Background()); err != nil {
		t.Fatalf("拉取离线消息: %v", err)
	}
	sort.Slice(reasons, func(i, j int) bool { return reasons[i] < reasons[j] })
	want := []OfflineRejectReason{ReasonConversation, ReasonSelfSend}
	if len(reasons) != len(want) || reasons[0] != want[0] || reasons[1] != want[1] {
		t.Fatalf("丢弃原因 %v，期望 %v", reasons, want)
	}
}
