// Package store 的 DAO 层：以显式 SQL 封装本地表读写。
package store

import (
	"database/sql"
	"errors"
)

// ErrNotFound 表示按主键查询的记录不存在。
var ErrNotFound = errors.New("记录不存在")

// DAO 是本地 SQLite 的读写入口，所有方法均为并发安全的（依赖 database/sql 连接池）。
type DAO struct {
	db *sql.DB

	// fieldCipher 对本地明文元数据字段做透明信封加密（P6-40）。
	// nil 表示未启用（历史明文兼容读取）；由内核装配时从 keystore 主密钥派生后设置。
	fieldCipher *FieldCipher
}

// NewDAO 基于已迁移的数据库创建 DAO。
func NewDAO(db *sql.DB) *DAO {
	return &DAO{db: db}
}

// SetFieldCipher 装配字段加密器。应在任何读写前调用；nil 表示禁用。
func (d *DAO) SetFieldCipher(c *FieldCipher) {
	d.fieldCipher = c
}

// FieldCipher 返回当前字段加密器（可能为 nil）。
func (d *DAO) FieldCipher() *FieldCipher {
	return d.fieldCipher
}

// sealField / openField 是字段加解密的统一入口：失败时向上返回错误，
// 避免静默写入明文或把密文当明文展示。
func (d *DAO) sealField(v string) (string, error) {
	return d.fieldCipher.Seal(v)
}

func (d *DAO) openField(v string) (string, error) {
	return d.fieldCipher.Open(v)
}

// DB 返回底层连接，供需要事务编排的调用方使用。
func (d *DAO) DB() *sql.DB {
	return d.db
}
