package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// 消息方向。
const (
	DirectionIn  = 0 // 接收
	DirectionOut = 1 // 发送
)

// 消息状态。
const (
	MessageStatePending  = 0
	MessageStateSent     = 1
	MessageStateAcked    = 2
	MessageStateFailed   = 3
	MessageStateReceived = 4
	// MessageStateRead 表示对端已通过已读回执确认（P6-07 单聊已读）。
	MessageStateRead = 5
)

const (
	defaultPageSize = 50
	maxPageSize     = 200
)

// Message 是 messages 表的一行。
type Message struct {
	// Seq 是本机消息事件序号，单调递增，用于 msg.listSince 增量拉取。
	Seq            int64
	MsgUUID        string
	ConversationID string
	SenderAccount  []byte
	SentAt         int64
	Direction      int
	ContentType    int
	BodyEnc        []byte
	State          int
	Raw            []byte
	// ExpiresAt 是定时消息的本机销毁时间（Unix 毫秒）；0 表示永不过期。
	// 由双方各自按正文 InnerMessage.ttl_hours 计算，仅本机使用，不上行。
	ExpiresAt int64
	// Body 是供本地全文索引使用的可检索纯文本（文本正文或文件名），
	// 只写入 message_search，不落 messages 表。
	Body string
}

// MessageCursor 是按键集分页的游标（上一页最后一条消息）。
type MessageCursor struct {
	SentAt  int64
	MsgUUID string
}

// PutMessage 写入或更新一条消息（以 msg_uuid 为幂等键），并同步全文索引。
func (d *DAO) PutMessage(ctx context.Context, m Message) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开启消息事务: %w", err)
	}
	defer func() {
		// 已提交时 Rollback 返回 ErrTxDone，可安全忽略。
		_ = tx.Rollback()
	}()

	if err := putMessageTx(ctx, tx, m); err != nil {
		return err
	}
	if err := indexMessageTx(ctx, tx, m); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交消息 %s: %w", m.MsgUUID, err)
	}
	return nil
}

// PutMessages 在同一事务内批量写入消息并同步全文索引。
func (d *DAO) PutMessages(ctx context.Context, msgs []Message) error {
	if len(msgs) == 0 {
		return nil
	}
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开启批量消息事务: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	for _, m := range msgs {
		if err := putMessageTx(ctx, tx, m); err != nil {
			return err
		}
		if err := indexMessageTx(ctx, tx, m); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交批量消息: %w", err)
	}
	return nil
}

func putMessageTx(ctx context.Context, tx *sql.Tx, m Message) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO messages
			(msg_uuid, conversation_id, sender_account, sent_at, direction, content_type, body_enc, state, raw, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(msg_uuid) DO UPDATE SET
			state = excluded.state,
			body_enc = excluded.body_enc,
			raw = excluded.raw,
			expires_at = excluded.expires_at`,
		m.MsgUUID, m.ConversationID, m.SenderAccount, m.SentAt, m.Direction,
		m.ContentType, m.BodyEnc, m.State, nullableBytes(m.Raw), m.ExpiresAt)
	if err != nil {
		return fmt.Errorf("写入消息 %s: %w", m.MsgUUID, err)
	}
	return nil
}

// AcceptInboundMessage 以 msg_uuid 为幂等键原子受理一条入站消息。
//
// 首次写入时在同一事务内创建会话、推进会话时间并累加未读；重复投递返回
// inserted=false 且不改动任何会话状态。这样并发重复帧也不会重复计数。
func (d *DAO) AcceptInboundMessage(ctx context.Context, kind int, m Message) (inserted bool, err error) {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("开启入站消息事务: %w", err)
	}
	defer func() {
		// 已提交时 Rollback 返回 ErrTxDone，可安全忽略；未提交则在此释放事务。
		_ = tx.Rollback()
	}()

	res, err := tx.ExecContext(ctx, `
		INSERT INTO messages
			(msg_uuid, conversation_id, sender_account, sent_at, direction, content_type, body_enc, state, raw, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(msg_uuid) DO NOTHING`,
		m.MsgUUID, m.ConversationID, m.SenderAccount, m.SentAt, m.Direction,
		m.ContentType, m.BodyEnc, m.State, nullableBytes(m.Raw), m.ExpiresAt)
	if err != nil {
		return false, fmt.Errorf("写入入站消息 %s: %w", m.MsgUUID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if n == 0 {
		return false, nil
	}

	if err := indexMessageTx(ctx, tx, m); err != nil {
		return false, err
	}

	if _, err = tx.ExecContext(ctx, `
		INSERT INTO conversations (id, kind, title, last_msg_at, unread)
		VALUES (?, ?, NULL, ?, 1)
		ON CONFLICT(id) DO UPDATE SET
			last_msg_at = MAX(IFNULL(last_msg_at, 0), excluded.last_msg_at),
			unread = unread + 1`,
		m.ConversationID, kind, m.SentAt); err != nil {
		return false, fmt.Errorf("更新会话 %s: %w", m.ConversationID, err)
	}

	if err = tx.Commit(); err != nil {
		return false, fmt.Errorf("提交入站消息 %s: %w", m.MsgUUID, err)
	}
	return true, nil
}

// GetMessage 按 msg_uuid 读取消息，不存在返回 ErrNotFound。
func (d *DAO) GetMessage(ctx context.Context, msgUUID string) (*Message, error) {
	row := d.db.QueryRowContext(ctx, `
		SELECT seq, msg_uuid, conversation_id, sender_account, sent_at, direction,
		       content_type, body_enc, state, raw, expires_at
		FROM messages WHERE msg_uuid = ?`, msgUUID)
	m, err := scanMessage(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取消息 %s: %w", msgUUID, err)
	}
	return m, nil
}

// UpdateMessageState 只更新消息状态，返回 ErrNotFound 表示消息不存在。
func (d *DAO) UpdateMessageState(ctx context.Context, msgUUID string, state int) error {
	res, err := d.db.ExecContext(ctx, `UPDATE messages SET state = ? WHERE msg_uuid = ?`, state, msgUUID)
	if err != nil {
		return fmt.Errorf("更新消息状态 %s: %w", msgUUID, err)
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

// UpdateMessageBody 更新一条消息的正文密文（InnerMessage 序列化字节）与全文索引，
// 用于消息编辑（七-2）。非文本可检索正文由 Body 提供；raw 保留原始发送帧不动。
// 返回 ErrNotFound 表示消息不存在。
func (d *DAO) UpdateMessageBody(ctx context.Context, msgUUID, body string, bodyEnc []byte) error {
	old, err := d.GetMessage(ctx, msgUUID)
	if err != nil {
		return err
	}
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开启编辑消息事务: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.ExecContext(ctx, `UPDATE messages SET body_enc = ? WHERE msg_uuid = ?`, bodyEnc, msgUUID)
	if err != nil {
		return fmt.Errorf("更新消息正文 %s: %w", msgUUID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	m := Message{MsgUUID: msgUUID, ConversationID: old.ConversationID, Body: body}
	if err := indexMessageTx(ctx, tx, m); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交编辑消息 %s: %w", msgUUID, err)
	}
	return nil
}

// MarkConversationRead 把会话内 sent_at <= upTo 的已发送/已送达消息置为已读，
// 返回本次状态变化的 msg_uuid，供上层补发 message.updated 事件（P6-07）。
func (d *DAO) MarkConversationRead(ctx context.Context, conversationID string, upTo int64) ([]string, error) {
	rows, err := d.db.QueryContext(ctx, `
		UPDATE messages SET state = ?
		WHERE conversation_id = ? AND direction = ? AND sent_at <= ?
		  AND state IN (?, ?)
		RETURNING msg_uuid`,
		MessageStateRead, conversationID, DirectionOut, upTo,
		MessageStateSent, MessageStateAcked)
	if err != nil {
		return nil, fmt.Errorf("推进会话 %s 已读: %w", conversationID, err)
	}
	defer rows.Close()

	var changed []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("扫描已读消息: %w", err)
		}
		changed = append(changed, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历已读消息: %w", err)
	}
	return changed, nil
}

// LatestInboundAt 返回会话内入站消息的最大时间戳；notAfter > 0 时只统计
// 时间戳不超过该值的入站消息。没有入站消息返回 0。已读回执以该水位告知对端（P6-07）。
func (d *DAO) LatestInboundAt(ctx context.Context, conversationID string, notAfter int64) (int64, error) {
	query := `SELECT IFNULL(MAX(sent_at), 0) FROM messages WHERE conversation_id = ? AND direction = ?`
	args := []any{conversationID, DirectionIn}
	if notAfter > 0 {
		query += ` AND sent_at <= ?`
		args = append(args, notAfter)
	}
	var at int64
	if err := d.db.QueryRowContext(ctx, query, args...).Scan(&at); err != nil {
		return 0, fmt.Errorf("查询会话 %s 入站水位: %w", conversationID, err)
	}
	return at, nil
}

// ListMessages 按 sent_at 倒序分页读取会话消息。
// cursor 为 nil 表示从最新一页开始；limit <= 0 用默认值，超过上限会被截断。
func (d *DAO) ListMessages(ctx context.Context, conversationID string, cursor *MessageCursor, limit int) ([]Message, error) {
	limit = normalizeLimit(limit)

	var (
		sb   strings.Builder
		args []any
	)
	sb.WriteString(`
		SELECT seq, msg_uuid, conversation_id, sender_account, sent_at, direction,
		       content_type, body_enc, state, raw, expires_at
		FROM messages WHERE conversation_id = ?`)
	args = append(args, conversationID)
	if cursor != nil {
		sb.WriteString(` AND (sent_at < ? OR (sent_at = ? AND msg_uuid < ?))`)
		args = append(args, cursor.SentAt, cursor.SentAt, cursor.MsgUUID)
	}
	sb.WriteString(` ORDER BY sent_at DESC, msg_uuid DESC LIMIT ?`)
	args = append(args, limit)

	rows, err := d.db.QueryContext(ctx, sb.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("查询会话 %s 消息: %w", conversationID, err)
	}
	defer rows.Close()

	out := make([]Message, 0, limit)
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, fmt.Errorf("扫描消息: %w", err)
		}
		out = append(out, *m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历消息: %w", err)
	}
	return out, nil
}

// ListMessagesSince 按本机单调 seq 升序读取会话内 seq > afterSeq 的消息（P1-21）。
// limit <= 0 用默认值，超过上限会被截断；调用方以末条 seq 作为下一次的 afterSeq。
func (d *DAO) ListMessagesSince(ctx context.Context, conversationID string, afterSeq int64, limit int) ([]Message, error) {
	limit = normalizeLimit(limit)

	rows, err := d.db.QueryContext(ctx, `
		SELECT seq, msg_uuid, conversation_id, sender_account, sent_at, direction,
		       content_type, body_enc, state, raw, expires_at
		FROM messages
		WHERE conversation_id = ? AND seq > ?
		ORDER BY seq ASC LIMIT ?`, conversationID, afterSeq, limit)
	if err != nil {
		return nil, fmt.Errorf("增量查询会话 %s 消息: %w", conversationID, err)
	}
	defer rows.Close()

	out := make([]Message, 0, limit)
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, fmt.Errorf("扫描消息: %w", err)
		}
		out = append(out, *m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历消息: %w", err)
	}
	return out, nil
}

// DeleteMessage 删除消息及其全文索引，不存在返回 ErrNotFound。
func (d *DAO) DeleteMessage(ctx context.Context, msgUUID string) error {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开启删除消息事务: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	res, err := tx.ExecContext(ctx, `DELETE FROM messages WHERE msg_uuid = ?`, msgUUID)
	if err != nil {
		return fmt.Errorf("删除消息 %s: %w", msgUUID, err)
	}
	if err := requireRow(res); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM message_search WHERE msg_uuid = ?`, msgUUID); err != nil {
		return fmt.Errorf("删除消息索引 %s: %w", msgUUID, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交删除消息 %s: %w", msgUUID, err)
	}
	return nil
}

// ExpiredMessage 是被定时清理的一条消息标识，供上层发出 message.expired 事件。
type ExpiredMessage struct {
	MsgUUID        string
	ConversationID string
}

// DeleteExpiredMessages 物理删除所有到期（expires_at > 0 且 <= now）的定时消息
// 及其全文索引，返回被删除消息标识。now 为 Unix 毫秒；在同一事务内先查后删，
// 保证返回的事件与删除结果一致，不依赖 SQLite DELETE RETURNING 支持。
func (d *DAO) DeleteExpiredMessages(ctx context.Context, now int64) ([]ExpiredMessage, error) {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("开启定时清理事务: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	rows, err := tx.QueryContext(ctx, `
		SELECT msg_uuid, conversation_id FROM messages
		WHERE expires_at > 0 AND expires_at <= ?`, now)
	if err != nil {
		return nil, fmt.Errorf("查询到期消息: %w", err)
	}
	var expired []ExpiredMessage
	for rows.Next() {
		var e ExpiredMessage
		if err := rows.Scan(&e.MsgUUID, &e.ConversationID); err != nil {
			_ = rows.Close()
			return nil, err
		}
		expired = append(expired, e)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if len(expired) == 0 {
		return nil, nil
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM message_search
		WHERE msg_uuid IN (SELECT msg_uuid FROM messages WHERE expires_at > 0 AND expires_at <= ?)`,
		now); err != nil {
		return nil, fmt.Errorf("清理到期消息索引: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM messages WHERE expires_at > 0 AND expires_at <= ?`, now); err != nil {
		return nil, fmt.Errorf("清理到期消息: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("提交定时清理: %w", err)
	}
	return expired, nil
}

// ClearConversationMessages 清空会话内全部消息及其全文索引，并把未读清零。
// 会话行保留（「清空聊天记录」语义：会话仍在列表，只是没有历史），返回删除条数。
func (d *DAO) ClearConversationMessages(ctx context.Context, conversationID string) (int, error) {
	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("开启清空会话事务: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	if _, err := tx.ExecContext(ctx, `
		DELETE FROM message_search
		WHERE msg_uuid IN (SELECT msg_uuid FROM messages WHERE conversation_id = ?)`,
		conversationID); err != nil {
		return 0, fmt.Errorf("清空会话 %s 搜索索引: %w", conversationID, err)
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM messages WHERE conversation_id = ?`, conversationID)
	if err != nil {
		return 0, fmt.Errorf("清空会话 %s 消息: %w", conversationID, err)
	}
	deleted, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("统计会话 %s 删除条数: %w", conversationID, err)
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE conversations SET unread = 0 WHERE id = ?`, conversationID); err != nil {
		return 0, fmt.Errorf("重置会话 %s 未读: %w", conversationID, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("提交清空会话 %s: %w", conversationID, err)
	}
	return int(deleted), nil
}

// CountMessages 返回会话内消息条数。
func (d *DAO) CountMessages(ctx context.Context, conversationID string) (int, error) {
	var n int
	if err := d.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM messages WHERE conversation_id = ?`, conversationID).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

type scanner interface {
	Scan(dest ...any) error
}

func scanMessage(s scanner) (*Message, error) {
	var m Message
	var raw []byte
	if err := s.Scan(
		&m.Seq, &m.MsgUUID, &m.ConversationID, &m.SenderAccount, &m.SentAt, &m.Direction,
		&m.ContentType, &m.BodyEnc, &m.State, &raw, &m.ExpiresAt,
	); err != nil {
		return nil, err
	}
	m.Raw = raw
	return &m, nil
}

func normalizeLimit(limit int) int {
	switch {
	case limit <= 0:
		return defaultPageSize
	case limit > maxPageSize:
		return maxPageSize
	default:
		return limit
	}
}

func nullableBytes(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	return b
}
