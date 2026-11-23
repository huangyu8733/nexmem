// Package crypto 提供 Nexmem 的密码学原语。
//
// 当前实现文件分片加密（P2-04）：每个文件使用随机 AES-256 密钥，
// 分片以 AES-256-GCM 独立封装，nonce 由密钥派生的 4 字节前缀与分片序号拼接，
// 保证同一文件内 nonce 唯一且无需在每片上额外传输随机数。
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// FileKeySize 是文件加密密钥长度（AES-256）。
	FileKeySize = 32
	// ChunkOverhead 是每个分片的 GCM 认证标签长度。
	ChunkOverhead = 16

	noncePrefixSize = 4
	nonceSize       = 12
)

// ErrDecrypt 表示分片认证失败：密钥不符、密文被篡改或分片序号错位。
var ErrDecrypt = errors.New("分片解密失败")

// ChunkCipher 对单个文件的所有分片做加解密，绑定同一把随机密钥。
type ChunkCipher struct {
	aead   cipher.AEAD
	prefix [noncePrefixSize]byte
}

// NewChunkCipher 用 32 字节文件密钥构造分片加密器。
// nonce 前缀由密钥的 SHA-256 派生，因此同一密钥在任意端得到相同前缀。
func NewChunkCipher(key []byte) (*ChunkCipher, error) {
	if len(key) != FileKeySize {
		return nil, fmt.Errorf("文件密钥长度 %d，期望 %d", len(key), FileKeySize)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("初始化 AES: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化 GCM: %w", err)
	}
	sum := sha256.Sum256(append([]byte("nexmem/file-nonce/v1"), key...))
	c := &ChunkCipher{aead: aead}
	copy(c.prefix[:], sum[:noncePrefixSize])
	return c, nil
}

// GenerateFileKey 生成一把随机的文件密钥。
func GenerateFileKey() ([]byte, error) {
	key := make([]byte, FileKeySize)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("生成文件密钥: %w", err)
	}
	return key, nil
}

// Seal 加密一个分片；index 参与 nonce 与附加认证数据，防止分片重排。
func (c *ChunkCipher) Seal(index uint32, plaintext []byte) []byte {
	nonce, aad := c.params(index)
	return c.aead.Seal(nil, nonce, plaintext, aad)
}

// Open 解密一个分片，失败返回 ErrDecrypt。
func (c *ChunkCipher) Open(index uint32, ciphertext []byte) ([]byte, error) {
	nonce, aad := c.params(index)
	out, err := c.aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, ErrDecrypt
	}
	return out, nil
}

func (c *ChunkCipher) params(index uint32) (nonce, aad []byte) {
	nonce = make([]byte, nonceSize)
	copy(nonce[:noncePrefixSize], c.prefix[:])
	binary.BigEndian.PutUint64(nonce[noncePrefixSize:], uint64(index))
	aad = make([]byte, 4)
	binary.BigEndian.PutUint32(aad, index)
	return nonce, aad
}
