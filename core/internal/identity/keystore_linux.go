//go:build linux && !android

package identity

import (
	"log"
	"sync"
)

var linuxKeyStoreWarn sync.Once

// NewKeyStore 返回 Linux 桌面主密钥存储。
// libsecret 需要额外的 CGO 依赖，当前桌面构建统一降级为 0600 文件主密钥，
// 并在首次创建时输出一次告警（P1-14 验收要求）。
func NewKeyStore(path string) KeyStore {
	linuxKeyStoreWarn.Do(func() {
		log.Printf("[WARN] identity: libsecret 不可用，已降级为文件主密钥存储: %s", path)
	})
	return &FileKeyStore{Path: path}
}
