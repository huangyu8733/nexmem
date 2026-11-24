package store

import (
	"context"
	"path/filepath"
	"testing"
)

func TestMigrateCreatesSchema(t *testing.T) {
	ctx := context.Background()
	db, err := Open(filepath.Join(t.TempDir(), "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer db.Close()

	if err := Migrate(ctx, db); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	v, err := SchemaVersion(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	if v != 10 {
		t.Fatalf("schema 版本应为 10, 实际 %d", v)
	}

	want := []string{
		"account", "contacts", "conversations", "messages",
		"inbox_cursors", "groups", "group_members", "group_keys", "outbox", "kv",
		"message_search",
	}
	for _, table := range want {
		var name string
		err := db.QueryRowContext(ctx,
			`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name)
		if err != nil {
			t.Fatalf("表 %s 不存在: %v", table, err)
		}
	}
}

func TestMigrateIdempotent(t *testing.T) {
	ctx := context.Background()
	db, err := Open(filepath.Join(t.TempDir(), "nexmem.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := Migrate(ctx, db); err != nil {
		t.Fatalf("首次迁移失败: %v", err)
	}
	// 写入一行数据，确认重复迁移不会破坏已有数据。
	if _, err := db.ExecContext(ctx,
		`INSERT INTO kv (k, v) VALUES ('probe', x'01')`); err != nil {
		t.Fatalf("写入探测数据失败: %v", err)
	}

	if err := Migrate(ctx, db); err != nil {
		t.Fatalf("重复迁移失败: %v", err)
	}
	v, err := SchemaVersion(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	if v != 10 {
		t.Fatalf("重复迁移后版本应保持 10, 实际 %d", v)
	}

	var n int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM kv WHERE k='probe'`).Scan(&n); err != nil {
		t.Fatalf("查询探测数据失败: %v", err)
	}
	if n != 1 {
		t.Fatalf("探测数据应保留 1 行, 实际 %d", n)
	}
}

func TestMigrateAcrossReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "nexmem.db")

	db, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := Migrate(ctx, db); err != nil {
		t.Fatalf("首次迁移失败: %v", err)
	}
	db.Close()

	db, err = Open(path)
	if err != nil {
		t.Fatalf("重新打开数据库失败: %v", err)
	}
	defer db.Close()
	if err := Migrate(ctx, db); err != nil {
		t.Fatalf("重开后迁移失败: %v", err)
	}
	v, err := SchemaVersion(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	if v != 10 {
		t.Fatalf("重开后版本应为 10, 实际 %d", v)
	}
}

func TestPragmas(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	defer db.Close()

	var fk int
	if err := db.QueryRow("PRAGMA foreign_keys").Scan(&fk); err != nil {
		t.Fatal(err)
	}
	if fk != 1 {
		t.Fatalf("外键应开启, 实际 %d", fk)
	}

	var timeout int
	if err := db.QueryRow("PRAGMA busy_timeout").Scan(&timeout); err != nil {
		t.Fatal(err)
	}
	if timeout != 5000 {
		t.Fatalf("busy_timeout 应为 5000, 实际 %d", timeout)
	}
}
