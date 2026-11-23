// Package identity 管理账号密钥、设备证书与公开档案的签发和校验。
//
// 账号密钥分两把：ed25519 用于签名（设备证书、消息、公开档案），
// x25519 用于离线消息的密钥封装。设备侧另有一把独立的 libp2p 私钥，
// 由账号私钥签发的 DeviceCert 绑定，从而支持同账号多设备。
package identity

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const accountFileVersion = 1

// Account 是账号的主密钥集合。私钥不离开本机。
type Account struct {
	priv      ed25519.PrivateKey
	xpriv     *ecdh.PrivateKey
	createdAt int64
}

type accountFile struct {
	Version int    `json:"version"`
	Seed    string `json:"account_ed25519_seed"`
	XPriv   string `json:"account_x25519_priv"`
	Created int64  `json:"created_at"`
}

// GenerateAccount 生成全新的账号密钥对。
func GenerateAccount() (*Account, error) {
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, fmt.Errorf("生成账号种子: %w", err)
	}
	xpriv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("生成账号 X25519 密钥: %w", err)
	}
	return &Account{
		priv:      ed25519.NewKeyFromSeed(seed),
		xpriv:     xpriv,
		createdAt: time.Now().Unix(),
	}, nil
}

// LoadOrCreateAccount 从 path 读取账号密钥，不存在则生成并落盘。
func LoadOrCreateAccount(path string) (*Account, error) {
	raw, err := os.ReadFile(path)
	if err == nil {
		return decodeAccount(raw)
	}
	if !os.IsNotExist(err) {
		return nil, fmt.Errorf("读取账号文件 %s: %w", path, err)
	}

	acc, err := GenerateAccount()
	if err != nil {
		return nil, err
	}
	if err := acc.Save(path); err != nil {
		return nil, err
	}
	return acc, nil
}

func decodeAccount(raw []byte) (*Account, error) {
	var f accountFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("解析账号文件: %w", err)
	}
	if f.Version != accountFileVersion {
		return nil, fmt.Errorf("账号文件版本不支持: %d", f.Version)
	}
	seed, err := base64.StdEncoding.DecodeString(f.Seed)
	if err != nil {
		return nil, fmt.Errorf("账号种子 base64: %w", err)
	}
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("账号种子长度错误: %d", len(seed))
	}
	xraw, err := base64.StdEncoding.DecodeString(f.XPriv)
	if err != nil {
		return nil, fmt.Errorf("账号 X25519 私钥 base64: %w", err)
	}
	xpriv, err := ecdh.X25519().NewPrivateKey(xraw)
	if err != nil {
		return nil, fmt.Errorf("账号 X25519 私钥无效: %w", err)
	}
	return &Account{
		priv:      ed25519.NewKeyFromSeed(seed),
		xpriv:     xpriv,
		createdAt: f.Created,
	}, nil
}

// Save 将账号私钥写入 path（权限 0600）。
func (a *Account) Save(path string) error {
	f := accountFile{
		Version: accountFileVersion,
		Seed:    base64.StdEncoding.EncodeToString(a.priv.Seed()),
		XPriv:   base64.StdEncoding.EncodeToString(a.xpriv.Bytes()),
		Created: a.createdAt,
	}
	raw, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建账号目录: %w", err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		return fmt.Errorf("写入账号文件 %s: %w", path, err)
	}
	return nil
}

// Export 返回账号私钥的明文编码，仅供加密备份使用。
// 调用方必须立即包装进加密容器，禁止把返回值直接落盘。
func (a *Account) Export() ([]byte, error) {
	if a == nil || len(a.priv) != ed25519.PrivateKeySize || a.xpriv == nil {
		return nil, errors.New("账号私钥不完整")
	}
	return json.Marshal(accountFile{
		Version: accountFileVersion,
		Seed:    base64.StdEncoding.EncodeToString(a.priv.Seed()),
		XPriv:   base64.StdEncoding.EncodeToString(a.xpriv.Bytes()),
		Created: a.createdAt,
	})
}

// ImportAccount 解析 Export 的产物；只做解码，不做持久化。
func ImportAccount(raw []byte) (*Account, error) {
	return decodeAccount(raw)
}

// CreatedAt 返回账号创建时间（Unix 秒）。
func (a *Account) CreatedAt() int64 { return a.createdAt }

// Pub 返回账号 ed25519 公钥副本。
func (a *Account) Pub() ed25519.PublicKey {
	pub := make(ed25519.PublicKey, len(a.priv[32:]))
	copy(pub, a.priv[32:])
	return pub
}

// XPub 返回账号 x25519 公钥副本。
func (a *Account) XPub() []byte {
	pub := a.xpriv.PublicKey().Bytes()
	out := make([]byte, len(pub))
	copy(out, pub)
	return out
}

// XPriv 返回账号 x25519 私钥副本，仅供内核解密离线消息使用。
// 调用方不得持久化或跨进程传递该字节串。
func (a *Account) XPriv() []byte {
	raw := a.xpriv.Bytes()
	out := make([]byte, len(raw))
	copy(out, raw)
	return out
}

// ID 返回账号公钥的十六进制标识，用于本地索引与日志。
func (a *Account) ID() string {
	return hex.EncodeToString(a.Pub())
}

// Sign 用账号 ed25519 私钥对调用方构造的确定性字节签名。
// 调用方必须自行做域隔离，避免签名在不同协议间被复用。
func (a *Account) Sign(data []byte) []byte {
	return ed25519.Sign(a.priv, data)
}

// VerifyAccountSignature 用账号 ed25519 公钥校验签名。
func VerifyAccountSignature(pub, data, sig []byte) error {
	if len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("账号公钥长度错误: %d", len(pub))
	}
	if len(sig) != ed25519.SignatureSize {
		return fmt.Errorf("签名长度错误: %d", len(sig))
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), data, sig) {
		return ErrInvalidSignature
	}
	return nil
}
