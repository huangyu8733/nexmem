package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// InboxCursor 是离线收件箱的拉取位点（每个 scope 一条）。
type InboxCursor struct {
	Scope     string
	ObjectKey string
	ETag      string
	SeenAt    int64
}

// PutCursor 写入或更新游标。
func (d *DAO) PutCursor(ctx context.Context, c InboxCursor) error {
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO inbox_cursors (scope, object_key, etag, seen_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(scope) DO UPDATE SET
			object_key = excluded.object_key,
			etag = excluded.etag,
			seen_at = excluded.seen_at`,
		c.Scope, c.ObjectKey, nullableText(c.ETag), c.SeenAt)
	if err != nil {
		return fmt.Errorf("写入游标 %s: %w", c.Scope, err)
	}
	return nil
}

// GetCursor 读取游标，不存在返回 ErrNotFound。
func (d *DAO) GetCursor(ctx context.Context, scope string) (*InboxCursor, error) {
	var c InboxCursor
	err := d.db.QueryRowContext(ctx, `
		SELECT scope, object_key, IFNULL(etag, ''), seen_at
		FROM inbox_cursors WHERE scope = ?`, scope).
		Scan(&c.Scope, &c.ObjectKey, &c.ETag, &c.SeenAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取游标 %s: %w", scope, err)
	}
	return &c, nil
}

// ListCursors 返回全部游标。
func (d *DAO) ListCursors(ctx context.Context) ([]InboxCursor, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT scope, object_key, IFNULL(etag, ''), seen_at
		FROM inbox_cursors ORDER BY scope`)
	if err != nil {
		return nil, fmt.Errorf("查询游标列表: %w", err)
	}
	defer rows.Close()

	var out []InboxCursor
	for rows.Next() {
		var c InboxCursor
		if err := rows.Scan(&c.Scope, &c.ObjectKey, &c.ETag, &c.SeenAt); err != nil {
			return nil, fmt.Errorf("扫描游标: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历游标: %w", err)
	}
	return out, nil
}

// DeleteCursor 删除游标，不存在返回 ErrNotFound。
func (d *DAO) DeleteCursor(ctx context.Context, scope string) error {
	res, err := d.db.ExecContext(ctx, `DELETE FROM inbox_cursors WHERE scope = ?`, scope)
	if err != nil {
		return fmt.Errorf("删除游标 %s: %w", scope, err)
	}
	return requireRow(res)
}
