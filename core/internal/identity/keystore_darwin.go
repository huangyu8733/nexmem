//go:build darwin

package identity

// NewKeyStore 返回 macOS 桌面主密钥存储；Keychain 托管由平台层后续接入替换。
func NewKeyStore(path string) KeyStore {
	return &FileKeyStore{Path: path}
}
