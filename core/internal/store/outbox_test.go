package store

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

func TestOutboxCRUD(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	entry := OutboxEntry{
		MsgUUID:     "m-1",
		PeerAccount: []byte("bob"),
		NextRetryAt: 1700000000,
		Payload:     []byte("frame"),
	}
	if err := dao.EnqueueOutbox(ctx, entry); err != nil {
		t.Fatalf("入队: %v", err)
	}

	got, err := dao.GetOutbox(ctx, "m-1")
	if err != nil {
		t.Fatalf("读取: %v", err)
	}
	if got.Attempts != 0 || got.NextRetryAt != entry.NextRetryAt || !bytes.Equal(got.Payload, entry.Payload) {
		t.Fatalf("条目内容不符: %+v", got)
	}

	// 同一条消息重复入队应更新载荷且不新增行。
	entry.Payload = []byte("frame-2")
	entry.NextRetryAt = 1700000100
	if err := dao.EnqueueOutbox(ctx, entry); err != nil {
		t.Fatalf("重复入队: %v", err)
	}
	if n, err := dao.CountOutbox(ctx); err != nil || n != 1 {
		t.Fatalf("重复入队后条数应为 1，实际 %d (err=%v)", n, err)
	}
	got, err = dao.GetOutbox(ctx, "m-1")
	if err != nil || !bytes.Equal(got.Payload, []byte("frame-2")) {
		t.Fatalf("重复入队应覆盖载荷: %+v (err=%v)", got, err)
	}

	if err := dao.DeleteOutbox(ctx, "m-1"); err != nil {
		t.Fatalf("删除: %v", err)
	}
	if _, err := dao.GetOutbox(ctx, "m-1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("删除后应返回 ErrNotFound，实际 %v", err)
	}
	if err := dao.DeleteOutbox(ctx, "m-1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound，实际 %v", err)
	}
}

// TestOutboxDueAndRetry 覆盖 P2-03 依赖的到期扫描与失败退避。
func TestOutboxDueAndRetry(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	entries := []OutboxEntry{
		{MsgUUID: "m-3", PeerAccount: []byte("bob"), NextRetryAt: 300, Payload: []byte("f3")},
		{MsgUUID: "m-1", PeerAccount: []byte("bob"), NextRetryAt: 100, Payload: []byte("f1")},
		{MsgUUID: "m-2", PeerAccount: []byte("bob"), NextRetryAt: 200, Payload: []byte("f2")},
	}
	for _, e := range entries {
		if err := dao.EnqueueOutbox(ctx, e); err != nil {
			t.Fatalf("入队 %s: %v", e.MsgUUID, err)
		}
	}

	due, err := dao.ListOutboxDue(ctx, 200, 10)
	if err != nil {
		t.Fatalf("到期扫描: %v", err)
	}
	if len(due) != 2 || due[0].MsgUUID != "m-1" || due[1].MsgUUID != "m-2" {
		t.Fatalf("到期条目应按时间升序且只含到期项: %+v", due)
	}

	if err := dao.UpdateOutboxRetry(ctx, "m-1", 500); err != nil {
		t.Fatalf("更新重试: %v", err)
	}
	got, err := dao.GetOutbox(ctx, "m-1")
	if err != nil {
		t.Fatalf("读取重试条目: %v", err)
	}
	if got.Attempts != 1 || got.NextRetryAt != 500 {
		t.Fatalf("重试次数与下次时间不符: %+v", got)
	}
	if err := dao.UpdateOutboxRetry(ctx, "m-1", 600); err != nil {
		t.Fatalf("二次更新重试: %v", err)
	}
	if got, err = dao.GetOutbox(ctx, "m-1"); err != nil || got.Attempts != 2 {
		t.Fatalf("重试次数应累加，实际 %+v (err=%v)", got, err)
	}

	due, err = dao.ListOutboxDue(ctx, 250, 10)
	if err != nil {
		t.Fatalf("退避后扫描: %v", err)
	}
	// m-1 已退避到 500/600，m-3 尚未到期，只剩 m-2 到期。
	if len(due) != 1 || due[0].MsgUUID != "m-2" {
		t.Fatalf("已退避的 m-1 与未到期的 m-3 都不应出现: %+v", due)
	}

	if err := dao.UpdateOutboxRetry(ctx, "missing", 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("更新不存在条目应返回 ErrNotFound，实际 %v", err)
	}
}
