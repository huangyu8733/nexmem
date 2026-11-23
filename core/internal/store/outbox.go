package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// OutboxEntry 是 outbox 表的一行：直连投递失败后待离线投递的消息。
// NextRetryAt 为 Unix 秒。
type OutboxEntry struct {
	MsgUUID     string
	PeerAccount []byte
	Attempts    int
	NextRetryAt int64
	Payload     []byte
}

// EnqueueOutbox 写入一条待投递消息（以 msg_uuid 为幂等键）。
// 同一条消息重复入队时更新对端、下次重试时间与载荷，保留已有重试次数。
func (d *DAO) EnqueueOutbox(ctx context.Context, e OutboxEntry) error {
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO outbox (msg_uuid, peer_account, attempts, next_retry_at, payload)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(msg_uuid) DO UPDATE SET
			peer_account = excluded.peer_account,
			next_retry_at = excluded.next_retry_at,
			payload = excluded.payload`,
		e.MsgUUID, nullableBytes(e.PeerAccount), e.Attempts, e.NextRetryAt, e.Payload)
	if err != nil {
		return fmt.Errorf("写入离线队列 %s: %w", e.MsgUUID, err)
	}
	return nil
}

// GetOutbox 按 msg_uuid 读取离线队列条目，不存在返回 ErrNotFound。
func (d *DAO) GetOutbox(ctx context.Context, msgUUID string) (*OutboxEntry, error) {
	var e OutboxEntry
	err := d.db.QueryRowContext(ctx, `
		SELECT msg_uuid, peer_account, attempts, next_retry_at, payload
		FROM outbox WHERE msg_uuid = ?`, msgUUID).
		Scan(&e.MsgUUID, &e.PeerAccount, &e.Attempts, &e.NextRetryAt, &e.Payload)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取离线队列 %s: %w", msgUUID, err)
	}
	return &e, nil
}

// DeleteOutbox 删除离线队列条目，不存在返回 ErrNotFound。
func (d *DAO) DeleteOutbox(ctx context.Context, msgUUID string) error {
	res, err := d.db.ExecContext(ctx, `DELETE FROM outbox WHERE msg_uuid = ?`, msgUUID)
	if err != nil {
		return fmt.Errorf("删除离线队列 %s: %w", msgUUID, err)
	}
	return requireRow(res)
}

// CountOutbox 返回离线队列条目数。
func (d *DAO) CountOutbox(ctx context.Context) (int, error) {
	var n int
	if err := d.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM outbox`).Scan(&n); err != nil {
		return 0, fmt.Errorf("统计离线队列: %w", err)
	}
	return n, nil
}

// ListOutboxDue 按下次重试时间升序返回 next_retry_at <= now 的条目。
// now 为 Unix 秒；limit <= 0 用默认值，超过上限会被截断。
func (d *DAO) ListOutboxDue(ctx context.Context, now int64, limit int) ([]OutboxEntry, error) {
	limit = normalizeLimit(limit)
	rows, err := d.db.QueryContext(ctx, `
		SELECT msg_uuid, peer_account, attempts, next_retry_at, payload
		FROM outbox WHERE next_retry_at <= ?
		ORDER BY next_retry_at, msg_uuid
		LIMIT ?`, now, limit)
	if err != nil {
		return nil, fmt.Errorf("查询离线队列: %w", err)
	}
	defer rows.Close()

	out := make([]OutboxEntry, 0, limit)
	for rows.Next() {
		var e OutboxEntry
		if err := rows.Scan(&e.MsgUUID, &e.PeerAccount, &e.Attempts, &e.NextRetryAt, &e.Payload); err != nil {
			return nil, fmt.Errorf("扫描离线队列: %w", err)
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历离线队列: %w", err)
	}
	return out, nil
}

// UpdateOutboxRetry 记录一次补发失败：重试次数 +1 并推迟下次重试时间。
// 不存在返回 ErrNotFound。
func (d *DAO) UpdateOutboxRetry(ctx context.Context, msgUUID string, nextRetryAt int64) error {
	res, err := d.db.ExecContext(ctx, `
		UPDATE outbox SET attempts = attempts + 1, next_retry_at = ?
		WHERE msg_uuid = ?`, nextRetryAt, msgUUID)
	if err != nil {
		return fmt.Errorf("更新离线队列重试 %s: %w", msgUUID, err)
	}
	return requireRow(res)
}
