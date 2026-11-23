package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// SetKV 写入或更新配置项。
func (d *DAO) SetKV(ctx context.Context, key string, value []byte) error {
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO kv (k, v) VALUES (?, ?)
		ON CONFLICT(k) DO UPDATE SET v = excluded.v`, key, value)
	if err != nil {
		return fmt.Errorf("写入配置 %s: %w", key, err)
	}
	return nil
}

// GetKV 读取配置项，不存在返回 ErrNotFound。
func (d *DAO) GetKV(ctx context.Context, key string) ([]byte, error) {
	var v []byte
	err := d.db.QueryRowContext(ctx, `SELECT v FROM kv WHERE k = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取配置 %s: %w", key, err)
	}
	return v, nil
}

// KVPair 是一个配置项（供多设备设置同步导出，P6-41）。
type KVPair struct {
	Key   string
	Value []byte
}

// ListKV 按 key 升序返回全部配置项，供设置快照导出使用。
func (d *DAO) ListKV(ctx context.Context) ([]KVPair, error) {
	rows, err := d.db.QueryContext(ctx, `SELECT k, v FROM kv ORDER BY k`)
	if err != nil {
		return nil, fmt.Errorf("遍历配置项: %w", err)
	}
	defer rows.Close()
	out := make([]KVPair, 0)
	for rows.Next() {
		var p KVPair
		if err := rows.Scan(&p.Key, &p.Value); err != nil {
			return nil, fmt.Errorf("扫描配置项: %w", err)
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历配置项: %w", err)
	}
	return out, nil
}

// DeleteKV 删除配置项，不存在返回 ErrNotFound。
func (d *DAO) DeleteKV(ctx context.Context, key string) error {
	res, err := d.db.ExecContext(ctx, `DELETE FROM kv WHERE k = ?`, key)
	if err != nil {
		return fmt.Errorf("删除配置 %s: %w", key, err)
	}
	return requireRow(res)
}
