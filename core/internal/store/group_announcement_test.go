package store

import (
	"context"
	"errors"
	"testing"
)

// TestGroupAnnouncement 覆盖群公告读写，以及 PutGroup 不得清空已有公告（P6-26）。
func TestGroupAnnouncement(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)
	groupID := []byte("g-announcement")

	if err := dao.PutGroup(ctx, Group{
		GroupID: groupID, Title: "研发群", KeyVersion: 1, GroupKeyEnc: []byte("enc"),
	}); err != nil {
		t.Fatal(err)
	}
	if text, err := dao.GetGroupAnnouncement(ctx, groupID); err != nil || text != "" {
		t.Fatalf("新群公告应为空, 实际 %q (err=%v)", text, err)
	}

	const announcement = "本周六上午十点全员会议，请准时参加。"
	if err := dao.SetGroupAnnouncement(ctx, groupID, announcement); err != nil {
		t.Fatal(err)
	}
	if text, err := dao.GetGroupAnnouncement(ctx, groupID); err != nil || text != announcement {
		t.Fatalf("公告读取不一致: %q (err=%v)", text, err)
	}
	if got, err := dao.GetGroup(ctx, groupID); err != nil || got.Announcement != announcement {
		t.Fatalf("GetGroup 应返回公告: %+v (err=%v)", got, err)
	}

	// 密钥轮换等内部写入只带部分字段，PutGroup 不得清空公告。
	if err := dao.PutGroup(ctx, Group{
		GroupID: groupID, Title: "研发群", KeyVersion: 2, GroupKeyEnc: []byte("enc2"),
	}); err != nil {
		t.Fatal(err)
	}
	if text, err := dao.GetGroupAnnouncement(ctx, groupID); err != nil || text != announcement {
		t.Fatalf("PutGroup 不应清空公告: %q (err=%v)", text, err)
	}
	list, err := dao.ListGroups(ctx)
	if err != nil || len(list) != 1 || list[0].Announcement != announcement {
		t.Fatalf("ListGroups 应返回公告: %+v (err=%v)", list, err)
	}

	// 显式写入空串表示清除。
	if err := dao.SetGroupAnnouncement(ctx, groupID, ""); err != nil {
		t.Fatal(err)
	}
	if text, err := dao.GetGroupAnnouncement(ctx, groupID); err != nil || text != "" {
		t.Fatalf("公告应已清除: %q (err=%v)", text, err)
	}

	if _, err := dao.GetGroupAnnouncement(ctx, []byte("missing")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在的群应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.SetGroupAnnouncement(ctx, []byte("missing"), "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("更新不存在的群应返回 ErrNotFound, 实际 %v", err)
	}
}
