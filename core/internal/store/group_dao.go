package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// Group 是 groups 表的一行。GroupKeyEnc 由本机 Keystore 保护。
type Group struct {
	GroupID        []byte
	Title          string
	MyRole         int
	KeyVersion     int
	GroupKeyEnc    []byte
	StorageCfgEnc  []byte
	OfflineEnabled bool
	// Announcement 是群公告正文；空串表示未设置。
	Announcement string
	// Alias 是本机群备注；空串表示未设置，仅本机可见、不上行。
	Alias string
	// AllowFriendAdd 是群设置：是否允许成员互相加好友（默认关闭）。
	AllowFriendAdd bool
	// LevelsEnabled 是群等级总开关（默认关闭）。
	LevelsEnabled bool
	// LevelsJSON 是群等级配置的 JSON 数组，落库前经字段级封装加密；空串表示未配置。
	LevelsJSON string
	// AvatarB64 是 512x512 JPEG 群头像的 base64；空串表示未设置。
	AvatarB64 string
	// Description 是群介绍正文；空串表示未设置。
	Description string
}

// GroupMember 是 group_members 表的一行。
type GroupMember struct {
	GroupID    []byte
	AccountPub []byte
	Role       int
	JoinedAt   int64
	// Nickname 是群内可见的本群称呼；空串表示未设置。
	Nickname string
	// LevelID 是群等级配置中的等级 ID；空串表示未设置。
	LevelID string
}

// PutGroup 写入或更新群记录。
//
// 公告与备注字段采用「空串不清空」语义：密钥轮换、成员表同步等内部写入只带部分字段，
// 不能把管理员此前设置的公告或本机备注抹掉；需要清除时调用 SetGroupAnnouncement / SetGroupAlias。
func (d *DAO) PutGroup(ctx context.Context, g Group) error {
	title, err := d.sealField(g.Title)
	if err != nil {
		return fmt.Errorf("加密群标题: %w", err)
	}
	announcement, err := d.sealField(g.Announcement)
	if err != nil {
		return fmt.Errorf("加密群公告: %w", err)
	}
	alias, err := d.sealField(g.Alias)
	if err != nil {
		return fmt.Errorf("加密群备注: %w", err)
	}
	levelsJSON, err := d.sealField(g.LevelsJSON)
	if err != nil {
		return fmt.Errorf("加密群等级配置: %w", err)
	}
	avatarB64, err := d.sealField(g.AvatarB64)
	if err != nil {
		return fmt.Errorf("加密群头像: %w", err)
	}
	description, err := d.sealField(g.Description)
	if err != nil {
		return fmt.Errorf("加密群介绍: %w", err)
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO groups
			(group_id, title, my_role, key_version, group_key_enc, storage_cfg_enc, offline_enabled, announcement, alias,
			 levels_enabled, levels_json, avatar_b64, description)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(group_id) DO UPDATE SET
			title = excluded.title,
			my_role = excluded.my_role,
			key_version = excluded.key_version,
			group_key_enc = excluded.group_key_enc,
			storage_cfg_enc = excluded.storage_cfg_enc,
			offline_enabled = excluded.offline_enabled,
			announcement = CASE
				WHEN excluded.announcement <> '' THEN excluded.announcement
				ELSE groups.announcement
			END,
			alias = CASE
				WHEN excluded.alias <> '' THEN excluded.alias
				ELSE groups.alias
			END,
			levels_enabled = CASE
				WHEN excluded.levels_json <> '' THEN excluded.levels_enabled
				ELSE groups.levels_enabled
			END,
			levels_json = CASE
				WHEN excluded.levels_json <> '' THEN excluded.levels_json
				ELSE groups.levels_json
			END,
			avatar_b64 = CASE
				WHEN excluded.avatar_b64 <> '' THEN excluded.avatar_b64
				ELSE groups.avatar_b64
			END,
			description = CASE
				WHEN excluded.description <> '' THEN excluded.description
				ELSE groups.description
			END`,
		g.GroupID, nullableText(title), g.MyRole, g.KeyVersion,
		g.GroupKeyEnc, nullableBytes(g.StorageCfgEnc), boolToInt(g.OfflineEnabled),
		announcement, alias, boolToInt(g.LevelsEnabled), levelsJSON,
		avatarB64, description)
	if err != nil {
		return fmt.Errorf("写入群 %x: %w", g.GroupID, err)
	}
	return nil
}

// GetGroupAnnouncement 读取本机群公告；群不存在返回 ErrNotFound。
func (d *DAO) GetGroupAnnouncement(ctx context.Context, groupID []byte) (string, error) {
	var text string
	err := d.db.QueryRowContext(ctx,
		`SELECT announcement FROM groups WHERE group_id = ?`, groupID).Scan(&text)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("读取群公告 %x: %w", groupID, err)
	}
	plain, err := d.openField(text)
	if err != nil {
		return "", fmt.Errorf("解封群公告 %x: %w", groupID, err)
	}
	return plain, nil
}

// SetGroupAnnouncement 覆盖本机群公告，空串表示清除；群不存在返回 ErrNotFound。
func (d *DAO) SetGroupAnnouncement(ctx context.Context, groupID []byte, text string) error {
	sealed, err := d.sealField(text)
	if err != nil {
		return fmt.Errorf("加密群公告: %w", err)
	}
	res, err := d.db.ExecContext(ctx,
		`UPDATE groups SET announcement = ? WHERE group_id = ?`, sealed, groupID)
	if err != nil {
		return fmt.Errorf("写入群公告 %x: %w", groupID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// getGroupTextField 读取一个经字段级封装加密的群文本字段。
func (d *DAO) getGroupTextField(ctx context.Context, groupID []byte, column string) (string, error) {
	var text string
	err := d.db.QueryRowContext(ctx,
		`SELECT `+column+` FROM groups WHERE group_id = ?`, groupID).Scan(&text)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("读取群字段 %s %x: %w", column, groupID, err)
	}
	plain, err := d.openField(text)
	if err != nil {
		return "", fmt.Errorf("解封群字段 %s %x: %w", column, groupID, err)
	}
	return plain, nil
}

// setGroupTextField 覆盖一个经字段级封装加密的群文本字段；空串表示清除。
func (d *DAO) setGroupTextField(ctx context.Context, groupID []byte, column, text string) error {
	sealed, err := d.sealField(text)
	if err != nil {
		return fmt.Errorf("加密群字段 %s: %w", column, err)
	}
	res, err := d.db.ExecContext(ctx,
		`UPDATE groups SET `+column+` = ? WHERE group_id = ?`, sealed, groupID)
	if err != nil {
		return fmt.Errorf("写入群字段 %s %x: %w", column, groupID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// GetGroupAvatar 读取本机群头像 base64；群不存在返回 ErrNotFound。
func (d *DAO) GetGroupAvatar(ctx context.Context, groupID []byte) (string, error) {
	return d.getGroupTextField(ctx, groupID, "avatar_b64")
}

// SetGroupAvatar 覆盖本机群头像；空串表示清除；群不存在返回 ErrNotFound。
func (d *DAO) SetGroupAvatar(ctx context.Context, groupID []byte, avatarB64 string) error {
	return d.setGroupTextField(ctx, groupID, "avatar_b64", avatarB64)
}

// GetGroupDescription 读取本机群介绍；群不存在返回 ErrNotFound。
func (d *DAO) GetGroupDescription(ctx context.Context, groupID []byte) (string, error) {
	return d.getGroupTextField(ctx, groupID, "description")
}

// SetGroupDescription 覆盖本机群介绍；空串表示清除；群不存在返回 ErrNotFound。
func (d *DAO) SetGroupDescription(ctx context.Context, groupID []byte, text string) error {
	return d.setGroupTextField(ctx, groupID, "description", text)
}

// GetGroupAllowFriendAdd 读取群设置：是否允许成员互相添加好友；群不存在返回 ErrNotFound。
func (d *DAO) GetGroupAllowFriendAdd(ctx context.Context, groupID []byte) (bool, error) {
	var enabled int
	err := d.db.QueryRowContext(ctx,
		`SELECT allow_friend_add FROM groups WHERE group_id = ?`, groupID).Scan(&enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, fmt.Errorf("读取群加好友设置 %x: %w", groupID, err)
	}
	return enabled != 0, nil
}

// SetGroupAllowFriendAdd 覆盖群加好友设置；群不存在返回 ErrNotFound。
func (d *DAO) SetGroupAllowFriendAdd(ctx context.Context, groupID []byte, enabled bool) error {
	value := 0
	if enabled {
		value = 1
	}
	res, err := d.db.ExecContext(ctx,
		`UPDATE groups SET allow_friend_add = ? WHERE group_id = ?`, value, groupID)
	if err != nil {
		return fmt.Errorf("写入群加好友设置 %x: %w", groupID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ClearGroupStorage 清空本机群盘配置（C-05 移除群盘 / 收到移除控制帧）。
// 同时关闭离线开关；群不存在返回 ErrNotFound。
func (d *DAO) ClearGroupStorage(ctx context.Context, groupID []byte) error {
	res, err := d.db.ExecContext(ctx,
		`UPDATE groups SET storage_cfg_enc = NULL, offline_enabled = 0 WHERE group_id = ?`, groupID)
	if err != nil {
		return fmt.Errorf("清除群盘配置 %x: %w", groupID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// GetGroupAlias 读取本机群备注；群不存在返回 ErrNotFound。
func (d *DAO) GetGroupAlias(ctx context.Context, groupID []byte) (string, error) {
	var alias string
	err := d.db.QueryRowContext(ctx,
		`SELECT IFNULL(alias, '') FROM groups WHERE group_id = ?`, groupID).Scan(&alias)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("读取群备注 %x: %w", groupID, err)
	}
	plain, err := d.openField(alias)
	if err != nil {
		return "", fmt.Errorf("解封群备注 %x: %w", groupID, err)
	}
	return plain, nil
}

// SetGroupAlias 覆盖本机群备注，空串表示清除；群不存在返回 ErrNotFound。
func (d *DAO) SetGroupAlias(ctx context.Context, groupID []byte, alias string) error {
	sealed, err := d.sealField(alias)
	if err != nil {
		return fmt.Errorf("加密群备注: %w", err)
	}
	res, err := d.db.ExecContext(ctx,
		`UPDATE groups SET alias = ? WHERE group_id = ?`, sealed, groupID)
	if err != nil {
		return fmt.Errorf("写入群备注 %x: %w", groupID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetGroupLevels 覆盖群等级配置（enabled 为总开关，levelsJSON 为等级数组 JSON；空串表示未配置）。
// 群不存在返回 ErrNotFound。
func (d *DAO) SetGroupLevels(ctx context.Context, groupID []byte, enabled bool, levelsJSON string) error {
	sealed, err := d.sealField(levelsJSON)
	if err != nil {
		return fmt.Errorf("加密群等级配置: %w", err)
	}
	res, err := d.db.ExecContext(ctx,
		`UPDATE groups SET levels_enabled = ?, levels_json = ? WHERE group_id = ?`,
		boolToInt(enabled), sealed, groupID)
	if err != nil {
		return fmt.Errorf("写入群等级配置 %x: %w", groupID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetMemberProfile 覆盖成员的本群称呼与等级 ID（空串表示清除）；成员不存在返回 ErrNotFound。
func (d *DAO) SetMemberProfile(ctx context.Context, groupID, account []byte, nickname, levelID string) error {
	res, err := d.db.ExecContext(ctx, `
		UPDATE group_members SET nickname = ?, level_id = ?
		WHERE group_id = ? AND account_pub = ?`, nickname, levelID, groupID, account)
	if err != nil {
		return fmt.Errorf("写入成员本群资料 %x: %w", account, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// GetGroupMemberProfile 读取成员的本群称呼与等级 ID；成员不存在返回 ErrNotFound。
func (d *DAO) GetGroupMemberProfile(ctx context.Context, groupID, account []byte) (nickname, levelID string, err error) {
	err = d.db.QueryRowContext(ctx, `
		SELECT IFNULL(nickname, ''), IFNULL(level_id, '')
		FROM group_members WHERE group_id = ? AND account_pub = ?`, groupID, account).
		Scan(&nickname, &levelID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrNotFound
	}
	if err != nil {
		return "", "", fmt.Errorf("读取成员本群资料 %x: %w", account, err)
	}
	return nickname, levelID, nil
}

// ClearMemberLevels 清空群内全部成员的等级 ID；用于关闭群等级总开关。
func (d *DAO) ClearMemberLevels(ctx context.Context, groupID []byte) error {
	if _, err := d.db.ExecContext(ctx,
		`UPDATE group_members SET level_id = '' WHERE group_id = ?`, groupID); err != nil {
		return fmt.Errorf("清空成员等级 %x: %w", groupID, err)
	}
	return nil
}

// GetGroup 按 group_id 读取群，不存在返回 ErrNotFound。
func (d *DAO) GetGroup(ctx context.Context, groupID []byte) (*Group, error) {
	var g Group
	var offline, allowFriend, levelsEnabled int
	err := d.db.QueryRowContext(ctx, `
		SELECT group_id, IFNULL(title, ''), my_role, key_version,
		       group_key_enc, storage_cfg_enc, offline_enabled, IFNULL(announcement, ''),
		       IFNULL(alias, ''), allow_friend_add, levels_enabled, IFNULL(levels_json, ''),
		       IFNULL(avatar_b64, ''), IFNULL(description, '')
		FROM groups WHERE group_id = ?`, groupID).
		Scan(&g.GroupID, &g.Title, &g.MyRole, &g.KeyVersion,
			&g.GroupKeyEnc, &g.StorageCfgEnc, &offline, &g.Announcement, &g.Alias,
			&allowFriend, &levelsEnabled, &g.LevelsJSON, &g.AvatarB64, &g.Description)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取群 %x: %w", groupID, err)
	}
	g.OfflineEnabled = offline != 0
	g.AllowFriendAdd = allowFriend != 0
	g.LevelsEnabled = levelsEnabled != 0
	if err := d.decryptGroupFields(&g); err != nil {
		return nil, err
	}
	return &g, nil
}

// decryptGroupFields 解封群的明文元数据字段（标题/公告/本机备注/等级配置 JSON）。
func (d *DAO) decryptGroupFields(g *Group) error {
	title, err := d.openField(g.Title)
	if err != nil {
		return fmt.Errorf("解封群标题: %w", err)
	}
	announcement, err := d.openField(g.Announcement)
	if err != nil {
		return fmt.Errorf("解封群公告: %w", err)
	}
	alias, err := d.openField(g.Alias)
	if err != nil {
		return fmt.Errorf("解封群备注: %w", err)
	}
	levelsJSON, err := d.openField(g.LevelsJSON)
	if err != nil {
		return fmt.Errorf("解封群等级配置: %w", err)
	}
	avatarB64, err := d.openField(g.AvatarB64)
	if err != nil {
		return fmt.Errorf("解封群头像: %w", err)
	}
	description, err := d.openField(g.Description)
	if err != nil {
		return fmt.Errorf("解封群介绍: %w", err)
	}
	g.Title, g.Announcement, g.Alias, g.LevelsJSON = title, announcement, alias, levelsJSON
	g.AvatarB64, g.Description = avatarB64, description
	return nil
}

// ListGroups 返回全部群，按标题排序。
func (d *DAO) ListGroups(ctx context.Context) ([]Group, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT group_id, IFNULL(title, ''), my_role, key_version,
		       group_key_enc, storage_cfg_enc, offline_enabled, IFNULL(announcement, ''),
		       IFNULL(alias, ''), allow_friend_add, levels_enabled, IFNULL(levels_json, ''),
		       IFNULL(avatar_b64, ''), IFNULL(description, '')
		FROM groups ORDER BY title, group_id`)
	if err != nil {
		return nil, fmt.Errorf("查询群列表: %w", err)
	}
	defer rows.Close()

	var out []Group
	for rows.Next() {
		var g Group
		var offline, allowFriend, levelsEnabled int
		if err := rows.Scan(&g.GroupID, &g.Title, &g.MyRole, &g.KeyVersion,
			&g.GroupKeyEnc, &g.StorageCfgEnc, &offline, &g.Announcement, &g.Alias,
			&allowFriend, &levelsEnabled, &g.LevelsJSON, &g.AvatarB64, &g.Description); err != nil {
			return nil, fmt.Errorf("扫描群: %w", err)
		}
		g.OfflineEnabled = offline != 0
		g.AllowFriendAdd = allowFriend != 0
		g.LevelsEnabled = levelsEnabled != 0
		if err := d.decryptGroupFields(&g); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历群: %w", err)
	}
	return out, nil
}

// DeleteGroup 删除群记录（及其成员），不存在返回 ErrNotFound。
func (d *DAO) DeleteGroup(ctx context.Context, groupID []byte) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `DELETE FROM groups WHERE group_id = ?`, groupID)
	if err != nil {
		return fmt.Errorf("删除群 %x: %w", groupID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM group_members WHERE group_id = ?`, groupID); err != nil {
		return fmt.Errorf("删除群成员 %x: %w", groupID, err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM group_keys WHERE group_id = ?`, groupID); err != nil {
		return fmt.Errorf("删除群密钥 %x: %w", groupID, err)
	}
	return tx.Commit()
}

// ReplaceMembers 整体替换群成员列表（事务内先删后插）。
// 密钥轮换、成员表同步等内部调用只带角色信息，必须按 account 保留已有的
// 本群称呼与等级 ID，否则一次轮换就会清空管理员设置的成员资料。
func (d *DAO) ReplaceMembers(ctx context.Context, groupID []byte, members []GroupMember) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	type profile struct {
		nickname string
		levelID  string
	}
	profiles := make(map[string]profile)
	rows, err := tx.QueryContext(ctx, `
		SELECT account_pub, IFNULL(nickname, ''), IFNULL(level_id, '')
		FROM group_members WHERE group_id = ?`, groupID)
	if err != nil {
		return fmt.Errorf("读取群成员资料 %x: %w", groupID, err)
	}
	for rows.Next() {
		var pub []byte
		var p profile
		if err := rows.Scan(&pub, &p.nickname, &p.levelID); err != nil {
			rows.Close()
			return fmt.Errorf("扫描群成员资料: %w", err)
		}
		profiles[string(pub)] = p
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return fmt.Errorf("遍历群成员资料: %w", err)
	}
	rows.Close()

	if _, err := tx.ExecContext(ctx, `DELETE FROM group_members WHERE group_id = ?`, groupID); err != nil {
		return fmt.Errorf("清空群成员 %x: %w", groupID, err)
	}
	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO group_members (group_id, account_pub, role, joined_at, nickname, level_id)
		VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, m := range members {
		nickname, levelID := m.Nickname, m.LevelID
		if p, ok := profiles[string(m.AccountPub)]; ok {
			nickname, levelID = p.nickname, p.levelID
		}
		if _, err := stmt.ExecContext(ctx, groupID, m.AccountPub, m.Role, m.JoinedAt, nickname, levelID); err != nil {
			return fmt.Errorf("写入群成员 %x: %w", m.AccountPub, err)
		}
	}
	return tx.Commit()
}

// ListMembers 返回群成员，按加入时间排序。
func (d *DAO) ListMembers(ctx context.Context, groupID []byte) ([]GroupMember, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT group_id, account_pub, role, joined_at, IFNULL(nickname, ''), IFNULL(level_id, '')
		FROM group_members WHERE group_id = ? ORDER BY joined_at, account_pub`, groupID)
	if err != nil {
		return nil, fmt.Errorf("查询群成员 %x: %w", groupID, err)
	}
	defer rows.Close()

	var out []GroupMember
	for rows.Next() {
		var m GroupMember
		if err := rows.Scan(&m.GroupID, &m.AccountPub, &m.Role, &m.JoinedAt, &m.Nickname, &m.LevelID); err != nil {
			return nil, fmt.Errorf("扫描群成员: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历群成员: %w", err)
	}
	return out, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
