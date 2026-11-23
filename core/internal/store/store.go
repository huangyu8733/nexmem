// Package store 提供 SQLite 连接、迁移与数据访问。
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	// 纯 Go SQLite 驱动，便于 gomobile / c-shared 交叉编译。
	_ "modernc.org/sqlite"
)

const driverName = "sqlite"

// Open 打开（不存在则创建）SQLite 数据库，并设置 busy_timeout / WAL / 外键。
func Open(path string) (*sql.DB, error) {
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("数据库路径为空")
	}
	dsn := buildDSN(path)
	db, err := sql.Open(driverName, dsn)
	if err != nil {
		return nil, fmt.Errorf("打开数据库 %s: %w", path, err)
	}
	if isMemory(path) {
		// 内存库按连接隔离，必须限制为单连接，否则迁移与查询会落在不同库上。
		db.SetMaxOpenConns(1)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("连接数据库 %s: %w", path, err)
	}
	return db, nil
}

func buildDSN(path string) string {
	var dsn string
	switch {
	case path == ":memory:":
		dsn = "file::memory:"
	case strings.HasPrefix(path, "file:"):
		dsn = path
	default:
		dsn = "file:" + filepath.ToSlash(path)
	}
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	return dsn + sep + "_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)"
}

func isMemory(path string) bool {
	return path == ":memory:" || strings.Contains(path, "mode=memory")
}
