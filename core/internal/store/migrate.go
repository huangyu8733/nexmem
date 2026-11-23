package store

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strconv"

	"github.com/nexmem/core/migrations"
)

var migrationName = regexp.MustCompile(`^(\d{4})_[a-z0-9_]+\.sql$`)

type migration struct {
	version int
	name    string
	body    string
}

// Migrate 按版本号顺序执行未应用的迁移，幂等可重复调用。
// 版本号写入 PRAGMA user_version，且必须是连续的整数序列。
func Migrate(ctx context.Context, db *sql.DB) error {
	current, err := schemaVersion(ctx, db)
	if err != nil {
		return err
	}

	list, err := loadMigrations()
	if err != nil {
		return err
	}

	for _, m := range list {
		if m.version <= current {
			continue
		}
		if m.version != current+1 {
			return fmt.Errorf("迁移版本不连续: 当前 %d, 下一份 %s", current, m.name)
		}
		if err := applyMigration(ctx, db, m); err != nil {
			return err
		}
		current = m.version
	}
	return nil
}

// SchemaVersion 返回当前 schema 版本。
func SchemaVersion(ctx context.Context, db *sql.DB) (int, error) {
	return schemaVersion(ctx, db)
}

func schemaVersion(ctx context.Context, db *sql.DB) (int, error) {
	var v int
	if err := db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&v); err != nil {
		return 0, fmt.Errorf("读取 schema 版本: %w", err)
	}
	return v, nil
}

func applyMigration(ctx context.Context, db *sql.DB, m migration) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开始迁移 %s: %w", m.name, err)
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, m.body); err != nil {
		return fmt.Errorf("执行迁移 %s: %w", m.name, err)
	}
	// PRAGMA 不支持参数绑定，版本号来自文件名中的数字，已限定为四位。
	if _, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", m.version)); err != nil {
		return fmt.Errorf("写入迁移版本 %s: %w", m.name, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交迁移 %s: %w", m.name, err)
	}
	return nil
}

func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		return nil, fmt.Errorf("读取迁移目录: %w", err)
	}

	var out []migration
	seen := make(map[int]string)
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := migrationName.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		version, err := strconv.Atoi(m[1])
		if err != nil || version == 0 {
			return nil, fmt.Errorf("迁移文件名版本号非法: %s", e.Name())
		}
		if prev, ok := seen[version]; ok {
			return nil, fmt.Errorf("迁移版本 %d 重复: %s 与 %s", version, prev, e.Name())
		}
		body, err := fs.ReadFile(migrations.FS, e.Name())
		if err != nil {
			return nil, fmt.Errorf("读取迁移 %s: %w", e.Name(), err)
		}
		seen[version] = e.Name()
		out = append(out, migration{version: version, name: e.Name(), body: string(body)})
	}

	sort.Slice(out, func(i, j int) bool { return out[i].version < out[j].version })
	return out, nil
}
