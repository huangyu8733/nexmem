//go:build android || ios

package identity

import (
	"fmt"
	"sync"
)

// InjectedKeyStore 使用宿主插件注入的 KEK。
// Android Keystore / iOS Keychain 由 P1-07 / P1-08 平台层读取条目后，
// 通过 gomobile 把 32 字节主密钥交入内核；Go 侧不直接持有平台 API。
type InjectedKeyStore struct {
	key []byte
}

// NewInjectedKeyStore 用平台层注入的 32 字节主密钥构造存储。
func NewInjectedKeyStore(masterKey []byte) (*InjectedKeyStore, error) {
	s := &InjectedKeyStore{}
	if err := s.SetMasterKey(masterKey); err != nil {
		return nil, err
	}
	return s, nil
}

// SetMasterKey 更新注入的主密钥（首次安装或 Keystore 重建后调用）。
func (s *InjectedKeyStore) SetMasterKey(masterKey []byte) error {
	if len(masterKey) != masterKeySize {
		return fmt.Errorf("%w: 主密钥长度 %d", ErrKeyStoreLocked, len(masterKey))
	}
	s.key = append([]byte(nil), masterKey...)
	return nil
}

// MasterKey 返回注入的主密钥副本；未注入时视为条目缺失。
func (s *InjectedKeyStore) MasterKey() ([]byte, error) {
	if s == nil || len(s.key) == 0 {
		return nil, fmt.Errorf("%w: 平台层未注入主密钥", ErrKeyStoreMissing)
	}
	return append([]byte(nil), s.key...), nil
}

// EnsureMasterKey 与 MasterKey 相同：移动端主密钥由平台 Keystore 生成，
// 内核不自行创建。
func (s *InjectedKeyStore) EnsureMasterKey() ([]byte, error) {
	return s.MasterKey()
}

// Delete 清空内存中的主密钥；平台条目由宿主插件负责删除。
func (s *InjectedKeyStore) Delete() error {
	if s != nil {
		for i := range s.key {
			s.key[i] = 0
		}
		s.key = nil
	}
	return nil
}

var (
	injectedMu    sync.RWMutex
	injectedStore *InjectedKeyStore
)

// SetInjectedMasterKey 由 gomobile 导出层在 core.start 之前调用，
// 注册平台 Keystore / Keychain 取出的 32 字节主密钥。
func SetInjectedMasterKey(masterKey []byte) error {
	s, err := NewInjectedKeyStore(masterKey)
	if err != nil {
		return err
	}
	injectedMu.Lock()
	injectedStore = s
	injectedMu.Unlock()
	return nil
}

// NewKeyStore 返回移动端注入式 KeyStore。未注入主密钥时返回的实例
// 所有读方法都会以 ErrKeyStoreMissing 失败，core.start 会明确报错，
// 避免内核在移动端静默落盘明文密钥。
func NewKeyStore(path string) KeyStore {
	injectedMu.RLock()
	defer injectedMu.RUnlock()
	return injectedStore
}
