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
}

// GroupMember 是 group_members 表的一行。
type GroupMember struct {
	GroupID    []byte
	AccountPub []byte
	Role       int
	JoinedAt   int64
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
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO groups
			(group_id, title, my_role, key_version, group_key_enc, storage_cfg_enc, offline_enabled, announcement, alias)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
			END`,
		g.GroupID, nullableText(title), g.MyRole, g.KeyVersion,
		g.GroupKeyEnc, nullableBytes(g.StorageCfgEnc), boolToInt(g.OfflineEnabled),
		announcement, alias)
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

// GetGroup 按 group_id 读取群，不存在返回 ErrNotFound。
func (d *DAO) GetGroup(ctx context.Context, groupID []byte) (*Group, error) {
	var g Group
	var offline int
	err := d.db.QueryRowContext(ctx, `
		SELECT group_id, IFNULL(title, ''), my_role, key_version,
		       group_key_enc, storage_cfg_enc, offline_enabled, IFNULL(announcement, ''),
		       IFNULL(alias, '')
		FROM groups WHERE group_id = ?`, groupID).
		Scan(&g.GroupID, &g.Title, &g.MyRole, &g.KeyVersion,
			&g.GroupKeyEnc, &g.StorageCfgEnc, &offline, &g.Announcement, &g.Alias)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取群 %x: %w", groupID, err)
	}
	g.OfflineEnabled = offline != 0
	if err := d.decryptGroupFields(&g); err != nil {
		return nil, err
	}
	return &g, nil
}

// decryptGroupFields 解封群的三个明文元数据字段（标题/公告/本机备注）。
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
	g.Title, g.Announcement, g.Alias = title, announcement, alias
	return nil
}

// ListGroups 返回全部群，按标题排序。
func (d *DAO) ListGroups(ctx context.Context) ([]Group, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT group_id, IFNULL(title, ''), my_role, key_version,
		       group_key_enc, storage_cfg_enc, offline_enabled, IFNULL(announcement, ''),
		       IFNULL(alias, '')
		FROM groups ORDER BY title, group_id`)
	if err != nil {
		return nil, fmt.Errorf("查询群列表: %w", err)
	}
	defer rows.Close()

	var out []Group
	for rows.Next() {
		var g Group
		var offline int
		if err := rows.Scan(&g.GroupID, &g.Title, &g.MyRole, &g.KeyVersion,
			&g.GroupKeyEnc, &g.StorageCfgEnc, &offline, &g.Announcement, &g.Alias); err != nil {
			return nil, fmt.Errorf("扫描群: %w", err)
		}
		g.OfflineEnabled = offline != 0
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
func (d *DAO) ReplaceMembers(ctx context.Context, groupID []byte, members []GroupMember) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `DELETE FROM group_members WHERE group_id = ?`, groupID); err != nil {
		return fmt.Errorf("清空群成员 %x: %w", groupID, err)
	}
	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO group_members (group_id, account_pub, role, joined_at)
		VALUES (?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, m := range members {
		if _, err := stmt.ExecContext(ctx, groupID, m.AccountPub, m.Role, m.JoinedAt); err != nil {
			return fmt.Errorf("写入群成员 %x: %w", m.AccountPub, err)
		}
	}
	return tx.Commit()
}

// ListMembers 返回群成员，按加入时间排序。
func (d *DAO) ListMembers(ctx context.Context, groupID []byte) ([]GroupMember, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT group_id, account_pub, role, joined_at
		FROM group_members WHERE group_id = ? ORDER BY joined_at, account_pub`, groupID)
	if err != nil {
		return nil, fmt.Errorf("查询群成员 %x: %w", groupID, err)
	}
	defer rows.Close()

	var out []GroupMember
	for rows.Next() {
		var m GroupMember
		if err := rows.Scan(&m.GroupID, &m.AccountPub, &m.Role, &m.JoinedAt); err != nil {
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
