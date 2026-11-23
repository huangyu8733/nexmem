//go:build !windows && !android && !ios

package identity

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
)

// FileKeyStore 用本地文件托管主密钥（权限 0600）。
// Linux 桌面在 libsecret 不可用时按 P1-14 约定降级为该形态；
// macOS 的 Keychain 托管由平台层后续接入替换。
type FileKeyStore struct {
	// Path 是主密钥文件路径。
	Path string
}

// MasterKey 只读取现有条目，条目缺失返回 ErrKeyStoreMissing。
func (s *FileKeyStore) MasterKey() ([]byte, error) {
	if s == nil || s.Path == "" {
		return nil, fmt.Errorf("%w: 未配置主密钥文件路径", ErrKeyStoreLocked)
	}
	key, err := os.ReadFile(s.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrKeyStoreMissing, s.Path)
		}
		return nil, fmt.Errorf("%w: %v", ErrKeyStoreLocked, err)
	}
	if len(key) != masterKeySize {
		return nil, fmt.Errorf("%w: 主密钥长度 %d", ErrKeyStoreLocked, len(key))
	}
	return key, nil
}

// EnsureMasterKey 读取条目；不存在时生成 32 字节随机主密钥落盘。
func (s *FileKeyStore) EnsureMasterKey() ([]byte, error) {
	key, err := s.MasterKey()
	if err == nil {
		return key, nil
	}
	if !errors.Is(err, ErrKeyStoreMissing) {
		return nil, err
	}
	key = make([]byte, masterKeySize)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("生成主密钥: %w", err)
	}
	if err := writeKeyFile(s.Path, key); err != nil {
		return nil, err
	}
	return key, nil
}

// Delete 删除主密钥条目；条目已不存在视为成功。
func (s *FileKeyStore) Delete() error {
	if s == nil || s.Path == "" {
		return nil
	}
	if err := os.Remove(s.Path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
