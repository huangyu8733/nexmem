package store

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

// TestGroupProfileStorage 覆盖群等级配置与成员本群资料的存储语义：
// levels_json 字段级加密、PutGroup 部分写入不清空、ReplaceMembers 按 account
// 保留称呼与等级、关闭等级清空等级 ID。
func TestGroupProfileStorage(t *testing.T) {
	ctx := context.Background()
	dao := newTestDAO(t)
	cipher, err := NewFieldCipher(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	dao.SetFieldCipher(cipher)
	groupID := []byte("g-profile")
	alice := []byte("alice-account")
	bob := []byte("bob-account")
	const levelsJSON = `[{"id":"vip1","name":"贵宾","icon_b64":""}]`

	if err := dao.PutGroup(ctx, Group{
		GroupID: groupID, Title: "资料群", KeyVersion: 1, GroupKeyEnc: []byte("enc"),
		LevelsEnabled: true, LevelsJSON: levelsJSON,
	}); err != nil {
		t.Fatalf("写入群: %v", err)
	}
	g, err := dao.GetGroup(ctx, groupID)
	if err != nil || !g.LevelsEnabled || g.LevelsJSON != levelsJSON {
		t.Fatalf("GetGroup 等级配置不一致: %+v (err=%v)", g, err)
	}
	list, err := dao.ListGroups(ctx)
	if err != nil || len(list) != 1 || !list[0].LevelsEnabled || list[0].LevelsJSON != levelsJSON {
		t.Fatalf("ListGroups 等级配置不一致: %+v (err=%v)", list, err)
	}
	var stored string
	if err := dao.db.QueryRowContext(ctx,
		`SELECT levels_json FROM groups WHERE group_id = ?`, groupID).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if !IsEncrypted(stored) || stored == levelsJSON {
		t.Fatalf("levels_json 应字段级加密存储, 实际 %q", stored)
	}

	// 密钥轮换等内部 PutGroup 只带部分字段，不得清空等级配置。
	if err := dao.PutGroup(ctx, Group{
		GroupID: groupID, Title: "改名群", KeyVersion: 2, GroupKeyEnc: []byte("enc2"),
	}); err != nil {
		t.Fatal(err)
	}
	if g, err = dao.GetGroup(ctx, groupID); err != nil || g.Title != "改名群" ||
		!g.LevelsEnabled || g.LevelsJSON != levelsJSON {
		t.Fatalf("PutGroup 不应清空等级配置: %+v (err=%v)", g, err)
	}

	if err := dao.SetGroupLevels(ctx, groupID, false, ""); err != nil {
		t.Fatalf("关闭等级: %v", err)
	}
	if g, err = dao.GetGroup(ctx, groupID); err != nil || g.LevelsEnabled || g.LevelsJSON != "" {
		t.Fatalf("关闭等级后配置不一致: %+v (err=%v)", g, err)
	}
	if err := dao.SetGroupLevels(ctx, groupID, true, levelsJSON); err != nil {
		t.Fatalf("重新开启等级: %v", err)
	}

	if err := dao.ReplaceMembers(ctx, groupID, []GroupMember{
		{GroupID: groupID, AccountPub: alice, Role: 1, JoinedAt: 1},
		{GroupID: groupID, AccountPub: bob, Role: 0, JoinedAt: 2},
	}); err != nil {
		t.Fatalf("写入成员: %v", err)
	}
	if err := dao.SetMemberProfile(ctx, groupID, alice, "队长", "vip1"); err != nil {
		t.Fatalf("设置成员资料: %v", err)
	}
	nickname, levelID, err := dao.GetGroupMemberProfile(ctx, groupID, alice)
	if err != nil || nickname != "队长" || levelID != "vip1" {
		t.Fatalf("读取成员资料不一致: %q/%q (err=%v)", nickname, levelID, err)
	}
	members, err := dao.ListMembers(ctx, groupID)
	if err != nil || len(members) != 2 || members[0].Nickname != "队长" || members[0].LevelID != "vip1" {
		t.Fatalf("ListMembers 缺少成员资料: %+v (err=%v)", members, err)
	}

	// 密钥轮换整体替换成员表时只传角色，必须按 account 保留资料。
	if err := dao.ReplaceMembers(ctx, groupID, []GroupMember{
		{GroupID: groupID, AccountPub: alice, Role: 1, JoinedAt: 5},
		{GroupID: groupID, AccountPub: bob, Role: 0, JoinedAt: 6},
	}); err != nil {
		t.Fatal(err)
	}
	if nickname, levelID, err = dao.GetGroupMemberProfile(ctx, groupID, alice); err != nil ||
		nickname != "队长" || levelID != "vip1" {
		t.Fatalf("ReplaceMembers 不应清空资料: %q/%q (err=%v)", nickname, levelID, err)
	}
	if nickname, levelID, err = dao.GetGroupMemberProfile(ctx, groupID, bob); err != nil ||
		nickname != "" || levelID != "" {
		t.Fatalf("新成员资料应为空: %q/%q (err=%v)", nickname, levelID, err)
	}

	if err := dao.ClearMemberLevels(ctx, groupID); err != nil {
		t.Fatalf("清空成员等级: %v", err)
	}
	members, err = dao.ListMembers(ctx, groupID)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range members {
		if m.LevelID != "" {
			t.Fatalf("成员等级 ID 应已清空: %+v", m)
		}
	}
	if nickname, _, err = dao.GetGroupMemberProfile(ctx, groupID, alice); err != nil || nickname != "队长" {
		t.Fatalf("清空等级不应影响称呼: %q (err=%v)", nickname, err)
	}

	if err := dao.SetMemberProfile(ctx, groupID, []byte("missing"), "x", ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在的成员应返回 ErrNotFound, 实际 %v", err)
	}
	if _, _, err := dao.GetGroupMemberProfile(ctx, groupID, []byte("missing")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在的成员应返回 ErrNotFound, 实际 %v", err)
	}
	if err := dao.SetGroupLevels(ctx, []byte("missing-group"), false, ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在的群应返回 ErrNotFound, 实际 %v", err)
	}
}
