//go:build android || ios

package mobile

import "github.com/nexmem/core/internal/identity"

// SetMasterKey 注入平台 Keystore（Android）/ Keychain（iOS）取出的 32 字节
// 主密钥。必须在 Call("core.start") 之前调用，否则 core.start 会以
// ErrKeyStoreMissing 失败，内核不会在移动端落盘明文私钥。
func SetMasterKey(key []byte) error {
	return identity.SetInjectedMasterKey(key)
}
