// Package migrations 内嵌 SQLite 迁移脚本。
//
// 文件名格式为 NNNN_name.sql，数字即 schema 版本号（写入 PRAGMA user_version）。
package migrations

import "embed"

// FS 包含全部迁移脚本，按文件名升序执行。
//
//go:embed *.sql
var FS embed.FS
