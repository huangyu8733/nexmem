package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

const (
	// defaultSearchLimit 是未指定 limit 时返回的最大命中数。
	defaultSearchLimit = 20
	// maxSearchLimit 限制单次检索返回条数，避免一次拉取过多消息。
	maxSearchLimit = 100
	// minTrigramRunes 是 trigram 分词可命中的最小字符数；更短的词退回 LIKE 扫描。
	minTrigramRunes = 3
	// snippetRadius 是命中片段在关键词两侧保留的字符数。
	snippetRadius = 24
)

// ErrEmptySearchQuery 表示检索关键词为空。
var ErrEmptySearchQuery = errors.New("搜索关键词为空")

// MessageSearchQuery 描述一次本地消息检索。
type MessageSearchQuery struct {
	// Query 是检索关键词（子串匹配）。
	Query string
	// ConversationID 非空时只在该会话内检索。
	ConversationID string
	// Limit 为返回条数上限，<=0 用默认值 20，超过 100 会被截断。
	Limit int
}

// MessageSearchHit 是一条命中的消息及其高亮片段。
type MessageSearchHit struct {
	MsgUUID        string
	ConversationID string
	SentAt         int64
	Direction      int
	SenderAccount  []byte
	Snippet        string
}

// SearchMessages 在本地全文索引中按子串检索消息，按发送时间倒序返回。
//
// 关键词达到 3 个字符时走 FTS5 trigram MATCH，更短的词（如两字中文）退回
// LIKE 子串扫描，保证短词也能命中。先取出 Top-N 命中，再按 rowid 回读正文
// 生成片段，避免对全部命中行计算 snippet 拖慢 1 万条消息下的响应。
func (d *DAO) SearchMessages(ctx context.Context, q MessageSearchQuery) ([]MessageSearchHit, error) {
	query := strings.TrimSpace(q.Query)
	if query == "" {
		return nil, ErrEmptySearchQuery
	}
	limit := normalizeSearchLimit(q.Limit)

	var (
		sb   strings.Builder
		args []any
	)
	if len([]rune(query)) >= minTrigramRunes {
		// FTS5 短语查询：整串作为子串，双引号按 FTS5 规则转义为两个双引号。
		sb.WriteString(`
			SELECT message_search.rowid, message_search.msg_uuid, message_search.conversation_id,
			       m.sent_at, m.direction, m.sender_account
			FROM message_search
			JOIN messages m ON m.msg_uuid = message_search.msg_uuid
			WHERE message_search MATCH ?`)
		args = append(args, `"`+strings.ReplaceAll(query, `"`, `""`)+`"`)
	} else {
		sb.WriteString(`
			SELECT message_search.rowid, message_search.msg_uuid, message_search.conversation_id,
			       m.sent_at, m.direction, m.sender_account
			FROM message_search
			JOIN messages m ON m.msg_uuid = message_search.msg_uuid
			WHERE message_search.body LIKE ? ESCAPE '\'`)
		args = append(args, "%"+escapeLike(query)+"%")
	}
	if q.ConversationID != "" {
		sb.WriteString(` AND message_search.conversation_id = ?`)
		args = append(args, q.ConversationID)
	}
	sb.WriteString(` ORDER BY m.sent_at DESC, message_search.msg_uuid DESC LIMIT ?`)
	args = append(args, limit)

	rows, err := d.db.QueryContext(ctx, sb.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("检索消息 %q: %w", query, err)
	}
	out := make([]MessageSearchHit, 0, limit)
	rowids := make([]int64, 0, limit)
	for rows.Next() {
		var (
			rowid int64
			h     MessageSearchHit
		)
		if err := rows.Scan(&rowid, &h.MsgUUID, &h.ConversationID, &h.SentAt,
			&h.Direction, &h.SenderAccount); err != nil {
			rows.Close()
			return nil, fmt.Errorf("扫描检索结果: %w", err)
		}
		rowids = append(rowids, rowid)
		out = append(out, h)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("遍历检索结果: %w", err)
	}
	rows.Close()

	for i, rowid := range rowids {
		body, err := searchBodyByRowid(ctx, d.db, rowid)
		if err != nil {
			return nil, err
		}
		out[i].Snippet = makeSnippet(body, query)
	}
	return out, nil
}

func searchBodyByRowid(ctx context.Context, db *sql.DB, rowid int64) (string, error) {
	var body string
	if err := db.QueryRowContext(ctx,
		`SELECT body FROM message_search WHERE rowid = ?`, rowid).Scan(&body); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("读取索引正文 %d: %w", rowid, err)
	}
	return body, nil
}

// makeSnippet 截取关键词前后各 snippetRadius 个字符作为命中片段。
func makeSnippet(body, query string) string {
	runes := []rune(body)
	if len(runes) == 0 {
		return ""
	}
	idx := indexFold(body, query)
	if idx < 0 {
		if len(runes) > 2*snippetRadius {
			return string(runes[:2*snippetRadius]) + "…"
		}
		return body
	}
	start := idx - snippetRadius
	if start < 0 {
		start = 0
	}
	end := idx + len([]rune(query)) + snippetRadius
	if end > len(runes) {
		end = len(runes)
	}
	prefix, suffix := "", ""
	if start > 0 {
		prefix = "…"
	}
	if end < len(runes) {
		suffix = "…"
	}
	return prefix + string(runes[start:idx]) + "[" + string(runes[idx:idx+len([]rune(query))]) + "]" +
		string(runes[idx+len([]rune(query)):end]) + suffix
}

// indexFold 返回 query 在 body 中首次出现的字符下标（ASCII 不区分大小写），未找到返回 -1。
func indexFold(body, query string) int {
	if query == "" {
		return -1
	}
	if idx := strings.Index(strings.ToLower(body), strings.ToLower(query)); idx >= 0 {
		// strings.Index 返回字节下标，转换为字符下标。
		return len([]rune(body[:idx]))
	}
	return -1
}

// CountSearchIndex 返回全文索引当前收录的消息条数，供诊断与验收使用。
func (d *DAO) CountSearchIndex(ctx context.Context) (int, error) {
	var n int
	if err := d.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM message_search`).Scan(&n); err != nil {
		return 0, fmt.Errorf("统计全文索引: %w", err)
	}
	return n, nil
}

// indexMessageTx 在同一事务内同步一条消息的全文索引。
//
// Body 为空表示本次写入不涉及可检索文本（例如仅更新消息状态），保留已有索引；
// 非空时先删除同 msg_uuid 的旧行再写入，保证重复写入或正文更新后不残留旧内容。
func indexMessageTx(ctx context.Context, tx *sql.Tx, m Message) error {
	body := strings.TrimSpace(m.Body)
	if body == "" {
		return nil
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM message_search WHERE msg_uuid = ?`, m.MsgUUID); err != nil {
		return fmt.Errorf("清理消息索引 %s: %w", m.MsgUUID, err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO message_search (msg_uuid, conversation_id, body) VALUES (?, ?, ?)`,
		m.MsgUUID, m.ConversationID, body); err != nil {
		return fmt.Errorf("写入消息索引 %s: %w", m.MsgUUID, err)
	}
	return nil
}

func normalizeSearchLimit(limit int) int {
	switch {
	case limit <= 0:
		return defaultSearchLimit
	case limit > maxSearchLimit:
		return maxSearchLimit
	default:
		return limit
	}
}

// escapeLike 转义 LIKE 模式中的通配符，配合 ESCAPE '\' 使用。
func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}
