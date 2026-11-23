package backup

import (
	"archive/tar"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nexmem/core/internal/identity"
	_ "modernc.org/sqlite"
)

const (
	entryManifest = "manifest.json"
	entryAccount  = "account.json"
	entryDB       = "data/nexmem.db"
)

// Manifest 是备份包的明文清单，用于导入前后核对内容。
type Manifest struct {
	Version       int    `json:"version"`
	CreatedAt     int64  `json:"created_at"`
	AccountID     string `json:"account_id"`
	Messages      int64  `json:"messages"`
	Conversations int64  `json:"conversations"`
	Contacts      int64  `json:"contacts"`
	Groups        int64  `json:"groups"`
}

// ExportOptions 描述一次备份导出。
type ExportOptions struct {
	// DB 是当前打开的本地库；导出期间会执行 VACUUM INTO 生成一致性快照。
	DB *sql.DB
	// Account 是当前账号，私钥会以明文写入加密容器内部。
	Account *identity.Account
	// Path 是备份文件目标路径。
	Path string
	// Passphrase 用于派生备份密钥；调用方负责使用后清零。
	Passphrase []byte
	// Now 可注入时钟，便于测试。
	Now func() time.Time
}

// ImportOptions 描述一次备份导入。
type ImportOptions struct {
	// DB 是已迁移的目标库；导入按主键幂等合并，不做覆盖删除。
	DB *sql.DB
	// Path 是备份文件路径。
	Path string
	// Passphrase 必须与导出时一致。
	Passphrase []byte
}

// ImportResult 是导入结果。
type ImportResult struct {
	Manifest *Manifest
	Account  *identity.Account
}

// Export 把账号与本地库导出为单个加密备份文件。
func Export(ctx context.Context, opts ExportOptions) (*Manifest, error) {
	if opts.DB == nil {
		return nil, errors.New("备份导出缺少数据库")
	}
	if opts.Account == nil {
		return nil, errors.New("备份导出缺少账号")
	}
	if strings.TrimSpace(opts.Path) == "" {
		return nil, errors.New("备份导出缺少目标路径")
	}
	if len(opts.Passphrase) == 0 {
		return nil, ErrPassphraseRequired
	}

	dir := filepath.Dir(opts.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("创建备份目录: %w", err)
	}

	snapPath, err := vacuumInto(ctx, opts.DB, dir)
	if err != nil {
		return nil, err
	}
	defer os.Remove(snapPath)

	now := time.Now()
	if opts.Now != nil {
		now = opts.Now()
	}
	manifest, err := readManifest(ctx, snapPath, opts.Account.ID(), now)
	if err != nil {
		return nil, err
	}
	accountRaw, err := opts.Account.Export()
	if err != nil {
		return nil, err
	}

	if err := writeArchive(opts.Path, opts.Passphrase, manifest, accountRaw, snapPath); err != nil {
		return nil, err
	}
	return manifest, nil
}

// vacuumInto 在目标目录生成 SQLite 一致性快照，返回快照路径。
func vacuumInto(ctx context.Context, db *sql.DB, dir string) (string, error) {
	f, err := os.CreateTemp(dir, ".nexmem-snapshot-*.db")
	if err != nil {
		return "", fmt.Errorf("创建快照文件: %w", err)
	}
	path := f.Name()
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", fmt.Errorf("关闭快照文件: %w", err)
	}
	// VACUUM INTO 要求目标文件不存在。
	if err := os.Remove(path); err != nil {
		return "", fmt.Errorf("准备快照文件: %w", err)
	}
	if _, err := db.ExecContext(ctx, "VACUUM INTO ?", path); err != nil {
		os.Remove(path)
		return "", fmt.Errorf("生成数据库快照: %w", err)
	}
	if err := normalizeSnapshot(path); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}

// normalizeSnapshot 把快照切回 rollback journal，避免导入端在只读/ATTACH
// 场景下因缺少 -wal/-shm 无法打开 WAL 库。
func normalizeSnapshot(path string) error {
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path))
	if err != nil {
		return fmt.Errorf("打开快照: %w", err)
	}
	defer db.Close()
	if _, err := db.ExecContext(context.Background(), "PRAGMA journal_mode=DELETE"); err != nil {
		return fmt.Errorf("规范化快照日志模式: %w", err)
	}
	return nil
}

func readManifest(ctx context.Context, snapPath, accountID string, now time.Time) (*Manifest, error) {
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(snapPath)+"?mode=ro")
	if err != nil {
		return nil, fmt.Errorf("打开快照: %w", err)
	}
	defer db.Close()

	m := &Manifest{
		Version:   formatVersion,
		CreatedAt: now.Unix(),
		AccountID: accountID,
	}
	counts := []struct {
		table string
		dest  *int64
	}{
		{"messages", &m.Messages},
		{"conversations", &m.Conversations},
		{"contacts", &m.Contacts},
		{"groups", &m.Groups},
	}
	for _, c := range counts {
		if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+c.table).Scan(c.dest); err != nil {
			return nil, fmt.Errorf("统计 %s: %w", c.table, err)
		}
	}
	return m, nil
}

func writeArchive(path string, passphrase []byte, manifest *Manifest, accountRaw []byte, snapPath string) error {
	header, salt, err := newHeader(defaultChunk)
	if err != nil {
		return err
	}
	key, err := deriveKey(passphrase, salt)
	if err != nil {
		return err
	}

	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".nexmem-backup-*.tmp")
	if err != nil {
		return fmt.Errorf("创建备份文件: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("设置备份文件权限: %w", err)
	}
	if _, err := tmp.Write(header); err != nil {
		tmp.Close()
		return fmt.Errorf("写入备份文件头: %w", err)
	}

	sealer, err := newSealWriter(tmp, key, header, defaultChunk)
	if err != nil {
		tmp.Close()
		return err
	}
	tw := tar.NewWriter(sealer)
	manifestRaw, err := json.Marshal(manifest)
	if err != nil {
		tmp.Close()
		return fmt.Errorf("序列化清单: %w", err)
	}
	if err := writeTarEntry(tw, entryManifest, manifestRaw, 0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := writeTarEntry(tw, entryAccount, accountRaw, 0o600); err != nil {
		tmp.Close()
		return err
	}
	snap, err := os.Open(snapPath)
	if err != nil {
		tmp.Close()
		return fmt.Errorf("读取数据库快照: %w", err)
	}
	info, err := snap.Stat()
	if err != nil {
		snap.Close()
		tmp.Close()
		return fmt.Errorf("读取数据库快照大小: %w", err)
	}
	if err := tw.WriteHeader(&tar.Header{
		Name:     entryDB,
		Mode:     0o600,
		Size:     info.Size(),
		Typeflag: tar.TypeReg,
	}); err != nil {
		snap.Close()
		tmp.Close()
		return fmt.Errorf("写入快照条目: %w", err)
	}
	if _, err := io.Copy(tw, snap); err != nil {
		snap.Close()
		tmp.Close()
		return fmt.Errorf("写入数据库快照: %w", err)
	}
	if err := snap.Close(); err != nil {
		tmp.Close()
		return fmt.Errorf("关闭数据库快照: %w", err)
	}
	if err := tw.Close(); err != nil {
		tmp.Close()
		return fmt.Errorf("结束备份归档: %w", err)
	}
	if err := sealer.Close(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("同步备份文件: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("关闭备份文件: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("写入备份文件 %s: %w", path, err)
	}
	return nil
}

func writeTarEntry(tw *tar.Writer, name string, data []byte, mode int64) error {
	if err := tw.WriteHeader(&tar.Header{
		Name:     name,
		Mode:     mode,
		Size:     int64(len(data)),
		Typeflag: tar.TypeReg,
	}); err != nil {
		return fmt.Errorf("写入条目 %s: %w", name, err)
	}
	if _, err := tw.Write(data); err != nil {
		return fmt.Errorf("写入条目内容 %s: %w", name, err)
	}
	return nil
}

// Import 解密备份并把账号、好友与历史消息合并进目标库。
func Import(ctx context.Context, opts ImportOptions) (*ImportResult, error) {
	if opts.DB == nil {
		return nil, errors.New("备份导入缺少数据库")
	}
	if strings.TrimSpace(opts.Path) == "" {
		return nil, errors.New("备份导入缺少来源路径")
	}
	if len(opts.Passphrase) == 0 {
		return nil, ErrPassphraseRequired
	}

	f, err := os.Open(opts.Path)
	if err != nil {
		return nil, fmt.Errorf("打开备份文件 %s: %w", opts.Path, err)
	}
	defer f.Close()

	plain, err := openBackup(f, opts.Passphrase)
	if err != nil {
		return nil, err
	}

	dir, err := os.MkdirTemp("", "nexmem-import-*")
	if err != nil {
		return nil, fmt.Errorf("创建导入临时目录: %w", err)
	}
	defer os.RemoveAll(dir)

	var manifest *Manifest
	var account *identity.Account
	snapPath := filepath.Join(dir, "nexmem.db")
	haveSnap := false

	tr := tar.NewReader(plain)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, archiveError(err)
		}
		switch hdr.Name {
		case entryManifest:
			raw, err := readEntry(tr, hdr)
			if err != nil {
				return nil, err
			}
			var m Manifest
			if err := json.Unmarshal(raw, &m); err != nil {
				return nil, fmt.Errorf("%w: 清单解析失败: %v", ErrFormat, err)
			}
			manifest = &m
		case entryAccount:
			raw, err := readEntry(tr, hdr)
			if err != nil {
				return nil, err
			}
			acc, err := identity.ImportAccount(raw)
			if err != nil {
				return nil, fmt.Errorf("%w: 账号解析失败: %v", ErrFormat, err)
			}
			account = acc
		case entryDB:
			out, err := os.OpenFile(snapPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
			if err != nil {
				return nil, fmt.Errorf("准备导入快照: %w", err)
			}
			if _, err := io.Copy(out, tr); err != nil {
				out.Close()
				return nil, archiveError(err)
			}
			if err := out.Close(); err != nil {
				return nil, fmt.Errorf("关闭导入快照: %w", err)
			}
			haveSnap = true
		default:
			if _, err := io.Copy(io.Discard, tr); err != nil {
				return nil, archiveError(err)
			}
		}
	}

	if manifest == nil {
		return nil, fmt.Errorf("%w: 缺少清单", ErrFormat)
	}
	if manifest.Version != formatVersion {
		return nil, fmt.Errorf("%w: 备份版本 %d 不支持", ErrFormat, manifest.Version)
	}
	if account == nil {
		return nil, fmt.Errorf("%w: 缺少账号", ErrFormat)
	}
	if !haveSnap {
		return nil, fmt.Errorf("%w: 缺少数据库快照", ErrFormat)
	}
	if manifest.AccountID != account.ID() {
		return nil, fmt.Errorf("%w: 清单账号与账号密钥不一致", ErrFormat)
	}

	if err := mergeSnapshot(ctx, opts.DB, snapPath); err != nil {
		return nil, err
	}
	return &ImportResult{Manifest: manifest, Account: account}, nil
}

func readEntry(r io.Reader, hdr *tar.Header) ([]byte, error) {
	if hdr.Size < 0 || hdr.Size > maxChunkSize*64 {
		return nil, fmt.Errorf("%w: 条目 %s 过大", ErrFormat, hdr.Name)
	}
	raw, err := io.ReadAll(io.LimitReader(r, hdr.Size))
	if err != nil {
		return nil, archiveError(err)
	}
	return raw, nil
}

// archiveError 保留解密错误语义，其余归档错误统一归为格式错误。
func archiveError(err error) error {
	if errors.Is(err, ErrDecrypt) {
		return ErrDecrypt
	}
	if errors.Is(err, ErrFormat) {
		return err
	}
	return fmt.Errorf("%w: 归档解析失败: %v", ErrFormat, err)
}

// mergeStatements 按主键幂等合并。message_search 是 FTS5 虚表，
// 没有唯一约束，按 msg_uuid 显式判重。
var mergeStatements = []string{
	`INSERT OR IGNORE INTO contacts (account_pub, alias, group_name, blocked, profile, updated_at)
	 SELECT account_pub, alias, group_name, blocked, profile, updated_at FROM backup_src.contacts`,
	`INSERT OR IGNORE INTO conversations (id, kind, title, last_msg_at, unread)
	 SELECT id, kind, title, last_msg_at, unread FROM backup_src.conversations`,
	`INSERT OR IGNORE INTO messages (msg_uuid, conversation_id, sender_account, sent_at, direction, content_type, body_enc, state, raw)
	 SELECT msg_uuid, conversation_id, sender_account, sent_at, direction, content_type, body_enc, state, raw FROM backup_src.messages`,
	`INSERT OR IGNORE INTO inbox_cursors (scope, object_key, etag, seen_at)
	 SELECT scope, object_key, etag, seen_at FROM backup_src.inbox_cursors`,
	`INSERT OR IGNORE INTO groups (group_id, title, my_role, key_version, group_key_enc, storage_cfg_enc, offline_enabled)
	 SELECT group_id, title, my_role, key_version, group_key_enc, storage_cfg_enc, offline_enabled FROM backup_src.groups`,
	`INSERT OR IGNORE INTO group_members (group_id, account_pub, role, joined_at)
	 SELECT group_id, account_pub, role, joined_at FROM backup_src.group_members`,
	`INSERT OR IGNORE INTO group_keys (group_id, key_version, key_enc, created_at)
	 SELECT group_id, key_version, key_enc, created_at FROM backup_src.group_keys`,
	`INSERT OR IGNORE INTO outbox (msg_uuid, peer_account, attempts, next_retry_at, payload)
	 SELECT msg_uuid, peer_account, attempts, next_retry_at, payload FROM backup_src.outbox`,
	`INSERT OR IGNORE INTO kv (k, v) SELECT k, v FROM backup_src.kv`,
	`INSERT INTO message_search (msg_uuid, conversation_id, body)
	 SELECT s.msg_uuid, s.conversation_id, s.body FROM backup_src.message_search s
	 WHERE NOT EXISTS (SELECT 1 FROM message_search m WHERE m.msg_uuid = s.msg_uuid)`,
}

// mergeSnapshot 把快照库 ATTACH 进目标库并在单事务内合并。
// ATTACH 必须在固定连接上执行，否则连接池会切换到没有挂载快照的连接。
func mergeSnapshot(ctx context.Context, db *sql.DB, snapPath string) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("获取数据库连接: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "ATTACH DATABASE ? AS backup_src", snapPath); err != nil {
		return fmt.Errorf("挂载备份快照: %w", err)
	}
	defer func() {
		_, _ = conn.ExecContext(context.Background(), "DETACH DATABASE backup_src")
	}()

	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开启导入事务: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	for _, stmt := range mergeStatements {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("合并备份数据: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交导入事务: %w", err)
	}
	return nil
}
