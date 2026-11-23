package netnode

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"

	"github.com/libp2p/go-libp2p/core/crypto"
)

// LoadOrCreateKey 读取磁盘上的节点私钥，不存在则生成 ed25519 密钥并落盘。
// P0 阶段用文件保存，P1 起改为 Keystore 信封加密。
func LoadOrCreateKey(path string) (crypto.PrivKey, error) {
	raw, err := os.ReadFile(path)
	if err == nil {
		priv, err := crypto.UnmarshalPrivateKey(raw)
		if err != nil {
			return nil, fmt.Errorf("解析私钥 %s: %w", path, err)
		}
		return priv, nil
	}
	if !os.IsNotExist(err) {
		return nil, err
	}

	priv, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, err
	}
	raw, err = crypto.MarshalPrivateKey(priv)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		return nil, err
	}
	return priv, nil
}
