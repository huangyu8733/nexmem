package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// 联系人列表的默认与最大条数，与 contract 中 contact.list 的 limit 上限一致。
const (
	defaultContactLimit = 200
	maxContactLimit     = 1000
)

// ErrBlocked 表示按账号公钥查询到的联系人处于拉黑状态。
var ErrBlocked = errors.New("联系人已被拉黑")

// Contact 是 contacts 表的一行。
//
// Alias 与 GroupName 只存在于本机数据库，不参与任何上行协议（备注仅本地可见）。
type Contact struct {
	AccountPub []byte // 32 字节 ed25519 账号公钥
	Alias      string // 本地备注名
	GroupName  string // 本地分组名
	Blocked    bool
	Profile    []byte // 目录服务返回的公开档案原文
	UpdatedAt  int64  // Unix 秒
}

// UpsertContact 写入或覆盖整条联系人记录；UpdatedAt 为 0 时取当前时间。
func (d *DAO) UpsertContact(ctx context.Context, c Contact) error {
	if len(c.AccountPub) == 0 {
		return errors.New("联系人公钥不能为空")
	}
	at := c.UpdatedAt
	if at == 0 {
		at = time.Now().Unix()
	}
	alias, err := d.sealField(c.Alias)
	if err != nil {
		return fmt.Errorf("加密联系人备注: %w", err)
	}
	groupName, err := d.sealField(c.GroupName)
	if err != nil {
		return fmt.Errorf("加密联系人分组: %w", err)
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO contacts (account_pub, alias, group_name, blocked, profile, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(account_pub) DO UPDATE SET
			alias = excluded.alias,
			group_name = excluded.group_name,
			blocked = excluded.blocked,
			profile = excluded.profile,
			updated_at = excluded.updated_at`,
		c.AccountPub, nullableText(alias), nullableText(groupName), boolInt(c.Blocked), c.Profile, at)
	if err != nil {
		return fmt.Errorf("写入联系人: %w", err)
	}
	return nil
}

// EnsureContact 在联系人不存在时创建，已存在时保持原记录不变。
func (d *DAO) EnsureContact(ctx context.Context, accountPub []byte, at int64) error {
	if len(accountPub) == 0 {
		return errors.New("联系人公钥不能为空")
	}
	if at == 0 {
		at = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO contacts (account_pub, updated_at) VALUES (?, ?)
		ON CONFLICT(account_pub) DO NOTHING`, accountPub, at)
	if err != nil {
		return fmt.Errorf("创建联系人: %w", err)
	}
	return nil
}

// GetContact 按账号公钥读取联系人，不存在返回 ErrNotFound。
func (d *DAO) GetContact(ctx context.Context, accountPub []byte) (*Contact, error) {
	return d.scanContact(d.db.QueryRowContext(ctx, `
		SELECT account_pub, IFNULL(alias, ''), IFNULL(group_name, ''), blocked, profile, updated_at
		FROM contacts WHERE account_pub = ?`, accountPub))
}

// ListContacts 按最近更新倒序返回联系人。
func (d *DAO) ListContacts(ctx context.Context, limit int) ([]Contact, error) {
	if limit <= 0 {
		limit = defaultContactLimit
	}
	if limit > maxContactLimit {
		limit = maxContactLimit
	}
	rows, err := d.db.QueryContext(ctx, `
		SELECT account_pub, IFNULL(alias, ''), IFNULL(group_name, ''), blocked, profile, updated_at
		FROM contacts
		ORDER BY updated_at DESC, account_pub
		LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("查询联系人列表: %w", err)
	}
	defer rows.Close()

	out := make([]Contact, 0, limit)
	for rows.Next() {
		c, err := d.scanContact(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历联系人: %w", err)
	}
	return out, nil
}

// SetContactBlocked 设置或取消拉黑，联系人不存在时先创建（拉黑不要求先加好友）。
func (d *DAO) SetContactBlocked(ctx context.Context, accountPub []byte, blocked bool, at int64) error {
	if at == 0 {
		at = time.Now().Unix()
	}
	_, err := d.db.ExecContext(ctx, `
		INSERT INTO contacts (account_pub, blocked, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(account_pub) DO UPDATE SET
			blocked = excluded.blocked,
			updated_at = excluded.updated_at`,
		accountPub, boolInt(blocked), at)
	if err != nil {
		return fmt.Errorf("更新联系人拉黑状态: %w", err)
	}
	return nil
}

// SetContactAlias 设置本地备注名，联系人不存在时先创建。
func (d *DAO) SetContactAlias(ctx context.Context, accountPub []byte, alias string, at int64) error {
	if at == 0 {
		at = time.Now().Unix()
	}
	sealed, err := d.sealField(alias)
	if err != nil {
		return fmt.Errorf("加密联系人备注: %w", err)
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO contacts (account_pub, alias, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(account_pub) DO UPDATE SET
			alias = excluded.alias,
			updated_at = excluded.updated_at`,
		accountPub, nullableText(sealed), at)
	if err != nil {
		return fmt.Errorf("更新联系人备注: %w", err)
	}
	return nil
}

// SetContactGroup 设置本地好友分组名，联系人不存在时先创建（空串表示清除分组）。
func (d *DAO) SetContactGroup(ctx context.Context, accountPub []byte, groupName string, at int64) error {
	if at == 0 {
		at = time.Now().Unix()
	}
	sealed, err := d.sealField(groupName)
	if err != nil {
		return fmt.Errorf("加密联系人分组: %w", err)
	}
	_, err = d.db.ExecContext(ctx, `
		INSERT INTO contacts (account_pub, group_name, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(account_pub) DO UPDATE SET
			group_name = excluded.group_name,
			updated_at = excluded.updated_at`,
		accountPub, nullableText(sealed), at)
	if err != nil {
		return fmt.Errorf("更新联系人分组: %w", err)
	}
	return nil
}

// DeleteContact 删除联系人记录，不存在返回 ErrNotFound。
func (d *DAO) DeleteContact(ctx context.Context, accountPub []byte) error {
	res, err := d.db.ExecContext(ctx, `DELETE FROM contacts WHERE account_pub = ?`, accountPub)
	if err != nil {
		return fmt.Errorf("删除联系人: %w", err)
	}
	return requireRow(res)
}

// IsContactBlocked 判断账号是否被本机拉黑；未收录的联系人视为未拉黑。
func (d *DAO) IsContactBlocked(ctx context.Context, accountPub []byte) (bool, error) {
	var blocked int
	err := d.db.QueryRowContext(ctx,
		`SELECT blocked FROM contacts WHERE account_pub = ?`, accountPub).Scan(&blocked)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("读取联系人拉黑状态: %w", err)
	}
	return blocked != 0, nil
}

// contactScanner 同时适配 *sql.Row 与 *sql.Rows。
type contactScanner interface {
	Scan(dest ...any) error
}

func (d *DAO) scanContact(row contactScanner) (*Contact, error) {
	var c Contact
	var blocked int
	var profile []byte
	err := row.Scan(&c.AccountPub, &c.Alias, &c.GroupName, &blocked, &profile, &c.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("扫描联系人: %w", err)
	}
	c.Blocked = blocked != 0
	c.Profile = profile
	alias, err := d.openField(c.Alias)
	if err != nil {
		return nil, fmt.Errorf("解封联系人备注: %w", err)
	}
	group, err := d.openField(c.GroupName)
	if err != nil {
		return nil, fmt.Errorf("解封联系人分组: %w", err)
	}
	c.Alias, c.GroupName = alias, group
	return &c, nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
