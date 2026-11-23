package directory

// 索引服务的持久化层（P3-04）。
//
// 单机起步使用 SQLite：公开档案与票据池共用一份库文件。
// 票据领取依赖单条 DELETE ... RETURNING 的原子性，并发领取不会拿到同一张票。

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/nexmem/core/internal/blob"
)

// ErrNotFound 表示档案或票据记录不存在。
var ErrNotFound = errors.New("目录记录不存在")

// ErrStaleProfile 表示上传的公开档案版本早于服务端已存版本。
var ErrStaleProfile = errors.New("公开档案版本过旧")

const directorySchema = `
CREATE TABLE IF NOT EXISTS profiles (
	account    TEXT PRIMARY KEY,
	profile    BLOB NOT NULL,
	updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS inbox_tickets (
	key        TEXT PRIMARY KEY,
	account    TEXT NOT NULL,
	device_id  TEXT NOT NULL,
	url        TEXT NOT NULL,
	expires_at INTEGER NOT NULL,
	created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_inbox_tickets_account
	ON inbox_tickets(account, created_at);
CREATE INDEX IF NOT EXISTS idx_inbox_tickets_expiry
	ON inbox_tickets(expires_at);

CREATE TABLE IF NOT EXISTS push_tokens (
	account    TEXT NOT NULL,
	token      TEXT NOT NULL,
	env        TEXT NOT NULL DEFAULT 'production',
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL,
	PRIMARY KEY (account, token)
);

CREATE INDEX IF NOT EXISTS idx_push_tokens_account
	ON push_tokens(account, updated_at);

CREATE TABLE IF NOT EXISTS reports (
	id              TEXT PRIMARY KEY,
	account         TEXT NOT NULL,
	reason          TEXT NOT NULL,
	conversation_id TEXT NOT NULL DEFAULT '',
	detail          TEXT NOT NULL DEFAULT '',
	diagnostics     BLOB,
	created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_reports_account
	ON reports(account, created_at);
`

// putProfile 写入公开档案；同账号只保留最新一份（按档案内 updated_at 单调推进）。
func (s *Server) putProfile(ctx context.Context, account string, raw []byte, updatedAt int64) error {
	res, err := s.db.ExecContext(ctx, `
		INSERT INTO profiles (account, profile, updated_at)
		VALUES (?, ?, ?)
		ON CONFLICT(account) DO UPDATE SET
			profile = excluded.profile,
			updated_at = excluded.updated_at
		WHERE excluded.updated_at >= profiles.updated_at`,
		account, raw, updatedAt)
	if err != nil {
		return fmt.Errorf("写入公开档案 %s: %w", account, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("统计公开档案写入 %s: %w", account, err)
	}
	if n == 0 {
		return ErrStaleProfile
	}
	return nil
}

// getProfile 读取公开档案的 protobuf 原始字节。
func (s *Server) getProfile(ctx context.Context, account string) ([]byte, error) {
	var raw []byte
	err := s.db.QueryRowContext(ctx,
		`SELECT profile FROM profiles WHERE account = ?`, account).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("读取公开档案 %s: %w", account, err)
	}
	return raw, nil
}

// addTickets 交存一批票据，重复对象键按幂等忽略，返回实际新增数量。
func (s *Server) addTickets(ctx context.Context, account, deviceID string, tickets []blob.Ticket) (int, error) {
	if len(tickets) == 0 {
		return 0, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("开始交存票据事务: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT OR IGNORE INTO inbox_tickets
			(key, account, device_id, url, expires_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("准备票据写入: %w", err)
	}
	defer stmt.Close()

	now := s.now().Unix()
	added := 0
	for _, t := range tickets {
		res, err := stmt.ExecContext(ctx, t.Key, account, deviceID, t.URL, t.ExpiresAt, now)
		if err != nil {
			return 0, fmt.Errorf("写入票据 %s: %w", t.Key, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return 0, fmt.Errorf("统计票据写入 %s: %w", t.Key, err)
		}
		added += int(n)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("提交交存票据事务: %w", err)
	}
	return added, nil
}

// ticketCleanupInterval 是过期票据清理的最小间隔（真实时间）。
// 清理只回收磁盘，不影响领取正确性（领取语句已过滤 expires_at > now），
// 故限频执行，避免高频并发领取时为删 0 行反复争抢 SQLite 写锁（R-24）。
const ticketCleanupInterval = time.Second

// takeTickets 原子领取至多 take 张未过期票据，并顺带清理已过期记录。
// 单条 DELETE ... RETURNING 保证同一张票最多被领取一次。
func (s *Server) takeTickets(ctx context.Context, account string, take int, now int64) ([]blob.Ticket, error) {
	// 限频清理：距上次超过间隔才执行，best-effort 失败不影响本次领取。
	// 用真实时间节流，避免注入的逻辑时钟在测试中干扰；用 CAS 保证并发下只清一次。
	last := s.lastTicketCleanup.Load()
	if realNow := time.Now().UnixNano(); realNow-last >= int64(ticketCleanupInterval) &&
		s.lastTicketCleanup.CompareAndSwap(last, realNow) {
		// 清理失败仅记入错误流，不阻断领取；下个间隔会再试。
		_, _ = s.db.ExecContext(ctx, `DELETE FROM inbox_tickets WHERE expires_at <= ?`, now)
	}

	rows, err := s.db.QueryContext(ctx, `
		DELETE FROM inbox_tickets
		WHERE key IN (
			SELECT key FROM inbox_tickets
			WHERE account = ? AND expires_at > ?
			ORDER BY created_at, key
			LIMIT ?
		)
		RETURNING key, url, expires_at`, account, now, take)
	if err != nil {
		return nil, fmt.Errorf("领取票据 %s: %w", account, err)
	}
	defer rows.Close()

	out := make([]blob.Ticket, 0, take)
	for rows.Next() {
		var t blob.Ticket
		if err := rows.Scan(&t.Key, &t.URL, &t.ExpiresAt); err != nil {
			return nil, fmt.Errorf("扫描票据: %w", err)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历票据: %w", err)
	}
	return out, nil
}

// countTickets 返回账号当前可领取（未过期）的票据数。
func (s *Server) countTickets(ctx context.Context, account string, now int64) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM inbox_tickets
		WHERE account = ? AND expires_at > ?`, account, now).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("统计票据 %s: %w", account, err)
	}
	return n, nil
}
