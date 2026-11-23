package store

import (
	"context"
	"fmt"
)

// GroupKeyRecord 是 group_keys 表的一行，保存某个群在某个版本的加密密钥。
type GroupKeyRecord struct {
	GroupID []byte
	Version uint32
	KeyEnc  []byte
}

// PutGroupKey 写入或覆盖某个群某个版本的密钥；同一版本重复写入幂等。
func (d *DAO) PutGroupKey(ctx context.Context, groupID []byte, version uint32, keyEnc []byte) error {
	if len(groupID) == 0 {
		return fmt.Errorf("写入群密钥: 群 ID 为空")
	}
	if version == 0 {
		return fmt.Errorf("写入群密钥: 版本为 0")
	}
	if len(keyEnc) == 0 {
		return fmt.Errorf("写入群密钥: 密文为空")
	}
	if _, err := d.db.ExecContext(ctx, `
		INSERT INTO group_keys (group_id, key_version, key_enc, created_at)
		VALUES (?, ?, ?, unixepoch())
		ON CONFLICT(group_id, key_version) DO UPDATE SET key_enc = excluded.key_enc`,
		groupID, version, keyEnc); err != nil {
		return fmt.Errorf("写入群 %x v%d 密钥: %w", groupID, version, err)
	}
	return nil
}

// ListGroupKeys 返回某个群的全部密钥版本，按版本升序。
func (d *DAO) ListGroupKeys(ctx context.Context, groupID []byte) ([]GroupKeyRecord, error) {
	rows, err := d.db.QueryContext(ctx, `
		SELECT group_id, key_version, key_enc
		FROM group_keys WHERE group_id = ? ORDER BY key_version`, groupID)
	if err != nil {
		return nil, fmt.Errorf("查询群 %x 密钥: %w", groupID, err)
	}
	defer rows.Close()

	var out []GroupKeyRecord
	for rows.Next() {
		var r GroupKeyRecord
		if err := rows.Scan(&r.GroupID, &r.Version, &r.KeyEnc); err != nil {
			return nil, fmt.Errorf("扫描群密钥: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历群密钥: %w", err)
	}
	return out, nil
}

// DeleteGroupKeys 删除某个群的全部历史密钥；不存在时为空操作。
func (d *DAO) DeleteGroupKeys(ctx context.Context, groupID []byte) error {
	if _, err := d.db.ExecContext(ctx, `DELETE FROM group_keys WHERE group_id = ?`, groupID); err != nil {
		return fmt.Errorf("删除群 %x 密钥: %w", groupID, err)
	}
	return nil
}
