// SQLite 字段级加密（P6-40）：对本地库中「可检索正文之外的明文元数据」做
// 透明信封加密。密钥由账号 x25519 私钥经域隔离派生，AES-256-GCM 封装。
// 选用账号私钥（而非设备 keystore 主密钥）作为密钥源，是为了让字段密文随
// 账号备份/恢复迁移到新设备后仍可解封（P6-05 / P6-41）；x25519 私钥的
// 离线消息 ECDH 用途与本字段用途通过 AAD 域隔离，互不兼容。
//
// 设计边界（诚实口径）：
//   - messages.body_enc 已是端到端密文，不重复加密。
//   - message_search.body 是 FTS5 trigram 索引，必须保留可检索明文才能 MATCH；
//     对它的「静态加密」会破坏检索，故本层不覆盖，改由操作系统/磁盘层保护，
//     并在文档中登记为已知边界。
//   - 本包提供封装修复/检验能力，供联系人备注、会话标题、群标题等元数据字段
//     在读写边界透明加解密；旧库明文在读取时原样返回（迁移兼容），新写入一律
//     使用带标记的信封，重启后凭主密钥解封。
package store

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

const (
	// FieldEncPrefix 是密文字段的固定前缀，用于与历史明文区分。
	FieldEncPrefix = "enc:v1:"
	fieldEncDomain = "nexmem/sqlite-field-enc/v1"
	fieldNonceSize = 12
)

var (
	// ErrFieldCipherKey 表示派生字段密钥失败（密钥材料长度非法）。
	ErrFieldCipherKey = errors.New("字段加密密钥材料非法")
	// ErrFieldDecrypt 表示密文字段解封失败（密钥不符或被篡改）。
	ErrFieldDecrypt = errors.New("字段密文解封失败")
)

// FieldCipher 对单个字符串字段做信封加密。并发安全（AES-GCM 实例只读）。
type FieldCipher struct {
	gcm cipher.AEAD
}

// NewFieldCipher 从账号私钥材料派生独立的字段加密密钥（要求 32 字节，
// 与 identity.Account.XPriv() 的 x25519 私钥长度一致）。
func NewFieldCipher(keyMaterial []byte) (*FieldCipher, error) {
	if len(keyMaterial) != 32 {
		return nil, fmt.Errorf("%w: 需要 32 字节，实际 %d", ErrFieldCipherKey, len(keyMaterial))
	}
	// 域隔离派生：sha256(domain || keyMaterial)，与离线消息 ECDH 用途分开。
	sum := sha256.New()
	sum.Write([]byte(fieldEncDomain))
	sum.Write(keyMaterial)
	key := sum.Sum(nil)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("初始化字段 AES: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化字段 GCM: %w", err)
	}
	return &FieldCipher{gcm: gcm}, nil
}

// Seal 加密一个明文字符串，返回带前缀的 base64url 信封。空串原样返回。
func (c *FieldCipher) Seal(plain string) (string, error) {
	if c == nil || plain == "" {
		return plain, nil
	}
	nonce := make([]byte, fieldNonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("生成字段 nonce: %w", err)
	}
	ct := c.gcm.Seal(nil, nonce, []byte(plain), []byte(fieldEncDomain))
	return FieldEncPrefix + base64.RawURLEncoding.EncodeToString(append(nonce, ct...)), nil
}

// Open 解封一个字段：带前缀的按密文处理，其它（历史明文）原样返回。
func (c *FieldCipher) Open(stored string) (string, error) {
	if c == nil || stored == "" || !strings.HasPrefix(stored, FieldEncPrefix) {
		return stored, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(stored, FieldEncPrefix))
	if err != nil || len(raw) <= fieldNonceSize {
		return "", fmt.Errorf("%w: 信封格式非法", ErrFieldDecrypt)
	}
	nonce, ct := raw[:fieldNonceSize], raw[fieldNonceSize:]
	plain, err := c.gcm.Open(nil, nonce, ct, []byte(fieldEncDomain))
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrFieldDecrypt, err)
	}
	return string(plain), nil
}

// IsEncrypted 判断一个已存储值是否为密文字段（供迁移统计与测试）。
func IsEncrypted(stored string) bool {
	return strings.HasPrefix(stored, FieldEncPrefix)
}
