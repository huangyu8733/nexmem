package store

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

func testPub(fill byte) []byte {
	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = fill
	}
	return pub
}

func TestContactCRUD(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)
	peer := testPub(0x11)

	if _, err := dao.GetContact(ctx, peer); !errors.Is(err, ErrNotFound) {
		t.Fatalf("未收录联系人应返回 ErrNotFound，实际 %v", err)
	}

	if err := dao.EnsureContact(ctx, peer, 100); err != nil {
		t.Fatalf("创建联系人: %v", err)
	}
	if err := dao.EnsureContact(ctx, peer, 200); err != nil {
		t.Fatalf("重复创建联系人: %v", err)
	}
	c, err := dao.GetContact(ctx, peer)
	if err != nil {
		t.Fatalf("读取联系人: %v", err)
	}
	if c.UpdatedAt != 100 {
		t.Fatalf("EnsureContact 不应覆盖已有记录，updated_at=%d", c.UpdatedAt)
	}
	if c.Blocked || c.Alias != "" {
		t.Fatalf("新联系人应为未拉黑且无备注: %+v", c)
	}

	if err := dao.SetContactAlias(ctx, peer, "老同学", 300); err != nil {
		t.Fatalf("设置备注: %v", err)
	}
	if err := dao.SetContactBlocked(ctx, peer, true, 400); err != nil {
		t.Fatalf("拉黑: %v", err)
	}
	c, err = dao.GetContact(ctx, peer)
	if err != nil {
		t.Fatalf("读取联系人: %v", err)
	}
	if c.Alias != "老同学" || !c.Blocked || c.UpdatedAt != 400 {
		t.Fatalf("备注与拉黑状态错误: %+v", c)
	}
	if blocked, err := dao.IsContactBlocked(ctx, peer); err != nil || !blocked {
		t.Fatalf("IsContactBlocked 应为 true，实际 %v/%v", blocked, err)
	}

	// 再次 Ensure 不得清除备注与拉黑。
	if err := dao.EnsureContact(ctx, peer, 500); err != nil {
		t.Fatalf("EnsureContact: %v", err)
	}
	c, _ = dao.GetContact(ctx, peer)
	if c.Alias != "老同学" || !c.Blocked {
		t.Fatalf("EnsureContact 不应清除备注或拉黑: %+v", c)
	}

	if err := dao.DeleteContact(ctx, peer); err != nil {
		t.Fatalf("删除联系人: %v", err)
	}
	if err := dao.DeleteContact(ctx, peer); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound，实际 %v", err)
	}
	if blocked, err := dao.IsContactBlocked(ctx, peer); err != nil || blocked {
		t.Fatalf("删除后应视为未拉黑，实际 %v/%v", blocked, err)
	}
}

func TestContactListOrderAndLimit(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)

	peers := [][]byte{testPub(0x01), testPub(0x02), testPub(0x03)}
	for i, p := range peers {
		if err := dao.UpsertContact(ctx, Contact{
			AccountPub: p,
			Alias:      "alias",
			UpdatedAt:  int64(100 + i),
		}); err != nil {
			t.Fatalf("写入联系人: %v", err)
		}
	}
	got, err := dao.ListContacts(ctx, 0)
	if err != nil {
		t.Fatalf("列出联系人: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("应返回 3 个联系人，实际 %d", len(got))
	}
	for i := 0; i < len(got); i++ {
		if want := peers[len(peers)-1-i]; !bytes.Equal(got[i].AccountPub, want) {
			t.Fatalf("第 %d 个联系人应为最近更新的 %x，实际 %x", i, want, got[i].AccountPub)
		}
	}

	limited, err := dao.ListContacts(ctx, 2)
	if err != nil {
		t.Fatalf("限制条数: %v", err)
	}
	if len(limited) != 2 {
		t.Fatalf("limit=2 应返回 2 条，实际 %d", len(limited))
	}

	clamped, err := dao.ListContacts(ctx, 5000)
	if err != nil {
		t.Fatalf("上限截断: %v", err)
	}
	if len(clamped) != 3 {
		t.Fatalf("超大 limit 应截断到上限但仍返回全部数据，实际 %d", len(clamped))
	}
}

func TestSetContactBlockedCreatesRow(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)
	peer := testPub(0x22)

	if err := dao.SetContactBlocked(ctx, peer, true, 10); err != nil {
		t.Fatalf("直接拉黑未收录账号: %v", err)
	}
	c, err := dao.GetContact(ctx, peer)
	if err != nil {
		t.Fatalf("读取联系人: %v", err)
	}
	if !c.Blocked {
		t.Fatalf("拉黑应落库")
	}

	if err := dao.SetContactBlocked(ctx, peer, false, 20); err != nil {
		t.Fatalf("取消拉黑: %v", err)
	}
	c, _ = dao.GetContact(ctx, peer)
	if c.Blocked {
		t.Fatalf("取消拉黑应落库")
	}
}
