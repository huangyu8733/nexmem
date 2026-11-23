package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// 会话类型。
const (
	ConversationKindDM    = 0
	ConversationKindGroup = 1
)

// Conversation 是 conversations 表的一行。
// LastMsgAt 为 0 表示尚无消息；Pinned/Muted 是仅本机生效的会话标记（P6-17）。
type Conversation struct {
	ID        string
	Kind      int
	Title     string
	LastMsgAt int64
	Unread    int
	Pinned    bool
	Muted     bool
}

// UpsertConversation 写入或覆盖整条会话记录。
func (d *DAO) UpsertConversation(ctx context.Context, c Conversation) error {
	title, err := d.sealField(c.Title)
	if err != nil {
		return fmt.Errorf("加密会话标题 %s: %w", c.ID, err)
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO conversations (id, kind, title, last_msg_at, unread, pinned, muted)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			kind = excluded.kind,
			title = excluded.title,
			last_msg_at = excluded.last_msg_at,
			unread = excluded.unread,
			pinned = excluded.pinned,
			muted = excluded.muted`,
		c.ID, c.Kind, nullableText(title), nullableInt64(c.LastMsgAt), c.Unread,
		boolInt(c.Pinned), boolInt(c.Muted))
	if err != nil {
		return fmt.Errorf("写入会话 %s: %w", c.ID, err)
	}
	return nil
}

// EnsureConversation 在会话不存在时创建；已存在时保持原记录不变。
func (d *DAO) EnsureConversation(ctx context.Context, c Conversation) error {
	title, err := d.sealField(c.Title)
	if err != nil {
		return fmt.Errorf("加密会话标题 %s: %w", c.ID, err)
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO conversations (id, kind, title, last_msg_at, unread, pinned, muted)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO NOTHING`,
		c.ID, c.Kind, nullableText(title), nullableInt64(c.LastMsgAt), c.Unread,
		boolInt(c.Pinned), boolInt(c.Muted))
	if err != nil {
		return fmt.Errorf("创建会话 %s: %w", c.ID, err)
	}
	return nil
}

// conversationColumns 是会话查询的统一列顺序。
const conversationColumns = `id, kind, IFNULL(title, ''), last_msg_at, unread, pinned, muted`

func (d *DAO) scanConversation(row interface{ Scan(...any) error }) (Conversation, error) {
	var c Conversation
	var last sql.NullInt64
	if err := row.Scan(&c.ID, &c.Kind, &c.Title, &last, &c.Unread, &c.Pinned, &c.Muted); err != nil {
		return Conversation{}, err
	}
	if last.Valid {
		c.LastMsgAt = last.Int64
	}
	title, err := d.openField(c.Title)
	if err != nil {
		return Conversation{}, fmt.Errorf("解封会话标题 %s: %w", c.ID, err)
	}
	c.Title = title
	return c, nil
}

// SetConversationFlags 更新会话的置顶 / 免打扰标记（nil 表示该字段不变）。
// 两个标记都只在本机生效；会话不存在返回 ErrNotFound。
func (d *DAO) SetConversationFlags(ctx context.Context, id string, pinned, muted *bool) error {
	sets := make([]string, 0, 2)
	args := make([]any, 0, 3)
	if pinned != nil {
		sets = append(sets, "pinned = ?")
		args = append(args, boolInt(*pinned))
	}
	if muted != nil {
		sets = append(sets, "muted = ?")
		args = append(args, boolInt(*muted))
	}
	if len(sets) == 0 {
		return ErrInvalidFlags
	}
	args = append(args, id)
	res, err := d.db.ExecContext(ctx,
		`UPDATE conversations SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...)
	if err != nil {
		return fmt.Errorf("更新会话标记 %s: %w", id, err)
	}
	return requireRow(res)
}

// ErrInvalidFlags 表示调用方既没有提供 pinned 也没有提供 muted。
var ErrInvalidFlags = errors.New("会话标记未提供")

// IncrConversationUnread 原子调整未读数，不存在返回 ErrNotFound。
func (d *DAO) IncrConversationUnread(ctx context.Context, id string, delta int) error {
	res, err := d.db.ExecContext(ctx,
		`UPDATE conversations SET unread = MAX(unread + ?, 0) WHERE id = ?`, delta, id)
	if err != nil {
		return fmt.Errorf("调整会话未读 %s: %w", id, err)
	}
	return requireRow(res)
}

// GetConversation 按 id 读取会话，不存在返回 ErrNotFound。
func (d *DAO) GetConversation(ctx context.Context, id string) (*Conversation, error) {
	c, err := d.scanConversation(d.db.QueryRowContext(ctx,
		`SELECT `+conversationColumns+` FROM conversations WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取会话 %s: %w", id, err)
	}
	return &c, nil
}

// ListConversations 按置顶优先、最近消息时间倒序返回会话。
func (d *DAO) ListConversations(ctx context.Context, limit int) ([]Conversation, error) {
	limit = normalizeLimit(limit)
	rows, err := d.db.QueryContext(ctx, `
		SELECT `+conversationColumns+`
		FROM conversations
		ORDER BY pinned DESC, last_msg_at IS NULL, last_msg_at DESC, id
		LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("查询会话列表: %w", err)
	}
	defer rows.Close()

	out := make([]Conversation, 0, limit)
	for rows.Next() {
		c, err := d.scanConversation(rows)
		if err != nil {
			return nil, fmt.Errorf("扫描会话: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历会话: %w", err)
	}
	return out, nil
}

// maxConversationProbeLimit 是会话列表探测上限：调用方常用 limit+1 判断
// 是否还有下一页，因此这里允许超过单页上限 200。
const maxConversationProbeLimit = 1000

// ListConversationsLimit 按调用方给出的条数原样返回会话（不做 200 上限截断），
// 供 conversation.list 以 limit+1 探测 has_more。
func (d *DAO) ListConversationsLimit(ctx context.Context, limit int) ([]Conversation, error) {
	if limit <= 0 {
		limit = 1
	}
	if limit > maxConversationProbeLimit {
		limit = maxConversationProbeLimit
	}
	rows, err := d.db.QueryContext(ctx, `
		SELECT `+conversationColumns+`
		FROM conversations
		ORDER BY pinned DESC, last_msg_at IS NULL, last_msg_at DESC, id
		LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("查询会话列表: %w", err)
	}
	defer rows.Close()

	out := make([]Conversation, 0, limit)
	for rows.Next() {
		c, err := d.scanConversation(rows)
		if err != nil {
			return nil, fmt.Errorf("扫描会话: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历会话: %w", err)
	}
	return out, nil
}

// TouchConversation 把最近消息时间推进到 at（只增不减）。
func (d *DAO) TouchConversation(ctx context.Context, id string, at int64) error {
	res, err := d.db.ExecContext(ctx, `
		UPDATE conversations SET last_msg_at = MAX(IFNULL(last_msg_at, 0), ?)
		WHERE id = ?`, at, id)
	if err != nil {
		return fmt.Errorf("更新会话时间 %s: %w", id, err)
	}
	return requireRow(res)
}

// SetConversationUnread 设置未读数。
func (d *DAO) SetConversationUnread(ctx context.Context, id string, unread int) error {
	res, err := d.db.ExecContext(ctx,
		`UPDATE conversations SET unread = ? WHERE id = ?`, unread, id)
	if err != nil {
		return fmt.Errorf("更新会话未读 %s: %w", id, err)
	}
	return requireRow(res)
}

// DeleteConversation 删除会话，不存在返回 ErrNotFound。
func (d *DAO) DeleteConversation(ctx context.Context, id string) error {
	res, err := d.db.ExecContext(ctx, `DELETE FROM conversations WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("删除会话 %s: %w", id, err)
	}
	return requireRow(res)
}

func requireRow(res sql.Result) error {
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func nullableText(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullableInt64(v int64) any {
	if v == 0 {
		return nil
	}
	return v
}
