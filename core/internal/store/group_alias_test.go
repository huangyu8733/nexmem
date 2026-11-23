package store

import (
	"context"
	"errors"
	"testing"
)

// TestGroupAlias 覆盖本机群备注读写，以及 PutGroup 不得清空已有备注（P6-27）。
func TestGroupAlias(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)
	groupID := []byte("g-alias")

	if err := dao.PutGroup(ctx, Group{
		GroupID: groupID, Title: "研发群", KeyVersion: 1, GroupKeyEnc: []byte("enc"),
	}); err != nil {
		t.Fatal(err)
	}
	if alias, err := dao.GetGroupAlias(ctx, groupID); err != nil || alias != "" {
		t.Fatalf("新群备注应为空, 实际 %q (err=%v)", alias, err)
	}

	const alias = "运维值班群"
	if err := dao.SetGroupAlias(ctx, groupID, alias); err != nil {
		t.Fatal(err)
	}
	if got, err := dao.GetGroupAlias(ctx, groupID); err != nil || got != alias {
		t.Fatalf("备注读取不一致: %q (err=%v)", got, err)
	}
	if g, err := dao.GetGroup(ctx, groupID); err != nil || g.Alias != alias {
		t.Fatalf("GetGroup 应返回备注: %+v (err=%v)", g, err)
	}

	// 密钥轮换等内部写入只带部分字段，PutGroup 不得清空备注。
	if err := dao.PutGroup(ctx, Group{
		GroupID: groupID, Title: "研发群", KeyVersion: 2, GroupKeyEnc: []byte("enc2"),
	}); err != nil {
		t.Fatal(err)
	}
	if got, err := dao.GetGroupAlias(ctx, groupID); err != nil || got != alias {
		t.Fatalf("PutGroup 不应清空备注: %q (err=%v)", got, err)
	}
	list, err := dao.ListGroups(ctx)
	if err != nil || len(list) != 1 || list[0].Alias != alias {
		t.Fatalf("ListGroups 应返回备注: %+v (err=%v)", list, err)
	}

	// 显式写入空串表示清除。
	if err := dao.SetGroupAlias(ctx, groupID, ""); err != nil {
		t.Fatal(err)
	}
	if got, err := dao.GetGroupAlias(ctx, groupID); err != nil || got != "" {
		t.Fatalf("备注应已清除: %q (err=%v)", got, err)
	}

	if _, err := dao.GetGroupAlias(ctx, []byte("missing")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在的群应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.SetGroupAlias(ctx, []byte("missing"), "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("更新不存在的群应返回 ErrNotFound, 实际 %v", err)
	}
}
