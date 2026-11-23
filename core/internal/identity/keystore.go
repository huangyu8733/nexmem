package identity

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const (
	sealedAccountVersion = 1
	sealedAccountAlg     = "AES-256-GCM"
	keystoreDomain       = "nexmem/account-keystore/v1"

	masterKeySize = 32
	gcmNonceSize  = 12
)

// KeyStore 提供 32 字节主密钥（KEK）。主密钥由系统 Keystore / DPAPI /
// 文件主密钥托管，业务私钥只以密文形式落盘。
//
// MasterKey 只读取现有条目；EnsureMasterKey 在首次安装时生成条目。
// 分开两者是为了让「Keystore 条目被删除」表现为解密失败，
// 而不是静默生成新密钥导致旧密文无法再用。
type KeyStore interface {
	MasterKey() ([]byte, error)
	EnsureMasterKey() ([]byte, error)
}

var (
	// ErrKeyStoreMissing 表示 Keystore 条目缺失（被删除或从未写入）。
	ErrKeyStoreMissing = errors.New("keystore 主密钥条目缺失")
	// ErrKeyStoreUnavailable 表示当前平台未接入系统 Keystore。
	ErrKeyStoreUnavailable = errors.New("当前平台未接入系统 Keystore")
	// ErrKeyStoreLocked 表示主密钥无法读取或长度非法。
	ErrKeyStoreLocked = errors.New("keystore 主密钥不可用")
	// ErrSealedAccount 表示账号密文校验失败（密钥不符或内容被篡改）。
	ErrSealedAccount = errors.New("账号密文校验失败")
	// ErrSealedAccountFormat 表示账号密文文件格式非法。
	ErrSealedAccountFormat = errors.New("账号密文格式非法")
)

// sealedBlob 是落盘的密文信封。明文只以 AES-256-GCM 密文存在。
type sealedBlob struct {
	Version    int    `json:"version"`
	Alg        string `json:"alg"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
}

// SealAccount 用 KeyStore 主密钥把账号私钥封装为密文信封。
func SealAccount(acc *Account, ks KeyStore) ([]byte, error) {
	if acc == nil {
		return nil, errors.New("账号为空")
	}
	if len(acc.priv) != ed25519.PrivateKeySize || acc.xpriv == nil {
		return nil, errors.New("账号私钥不完整")
	}
	plain, err := json.Marshal(accountFile{
		Version: accountFileVersion,
		Seed:    base64.StdEncoding.EncodeToString(acc.priv.Seed()),
		XPriv:   base64.StdEncoding.EncodeToString(acc.xpriv.Bytes()),
		Created: acc.createdAt,
	})
	if err != nil {
		return nil, fmt.Errorf("序列化账号: %w", err)
	}
	nonce, ct, err := sealWithKeyStore(ks, "account", plain)
	if err != nil {
		return nil, err
	}
	raw, err := json.MarshalIndent(sealedBlob{
		Version:    sealedAccountVersion,
		Alg:        sealedAccountAlg,
		Nonce:      base64.StdEncoding.EncodeToString(nonce),
		Ciphertext: base64.StdEncoding.EncodeToString(ct),
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("序列化密文信封: %w", err)
	}
	return raw, nil
}

// OpenAccount 用 KeyStore 主密钥解封账号信封。
func OpenAccount(raw []byte, ks KeyStore) (*Account, error) {
	var b sealedBlob
	if err := json.Unmarshal(raw, &b); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrSealedAccountFormat, err)
	}
	if b.Version != sealedAccountVersion {
		return nil, fmt.Errorf("%w: 版本 %d 不支持", ErrSealedAccountFormat, b.Version)
	}
	if b.Alg != sealedAccountAlg {
		return nil, fmt.Errorf("%w: 算法 %q 不支持", ErrSealedAccountFormat, b.Alg)
	}
	nonce, err := base64.StdEncoding.DecodeString(b.Nonce)
	if err != nil || len(nonce) != gcmNonceSize {
		return nil, fmt.Errorf("%w: nonce 非法", ErrSealedAccountFormat)
	}
	ct, err := base64.StdEncoding.DecodeString(b.Ciphertext)
	if err != nil || len(ct) == 0 {
		return nil, fmt.Errorf("%w: 密文非法", ErrSealedAccountFormat)
	}
	plain, err := openWithKeyStore(ks, "account", nonce, ct)
	if err != nil {
		return nil, err
	}
	acc, err := decodeAccount(plain)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrSealedAccount, err)
	}
	return acc, nil
}

// SaveSealedAccount 把账号私钥加密后写入 path（权限 0600）。
func SaveSealedAccount(path string, acc *Account, ks KeyStore) error {
	raw, err := SealAccount(acc, ks)
	if err != nil {
		return err
	}
	return writeSealedFile(path, raw)
}

// LoadSealedAccount 从 path 读取并解封账号私钥。
func LoadSealedAccount(path string, ks KeyStore) (*Account, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取账号密文 %s: %w", path, err)
	}
	return OpenAccount(raw, ks)
}

// LoadOrCreateSealedAccount 读取密文账号；不存在则生成新账号并加密落盘。
func LoadOrCreateSealedAccount(path string, ks KeyStore) (*Account, error) {
	acc, err := LoadSealedAccount(path, ks)
	if err == nil {
		return acc, nil
	}
	if !os.IsNotExist(unwrapPathErr(err)) {
		return nil, err
	}
	acc, err = GenerateAccount()
	if err != nil {
		return nil, err
	}
	if err := SaveSealedAccount(path, acc, ks); err != nil {
		return nil, err
	}
	return acc, nil
}

// unwrapPathErr 取出读取文件时的底层 *PathError，供 os.IsNotExist 判断。
func unwrapPathErr(err error) error {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return pe
	}
	return err
}

func sealWithKeyStore(ks KeyStore, purpose string, plaintext []byte) ([]byte, []byte, error) {
	gcm, err := gcmFor(ks, true)
	if err != nil {
		return nil, nil, err
	}
	nonce := make([]byte, gcmNonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, nil, fmt.Errorf("生成 nonce: %w", err)
	}
	return nonce, gcm.Seal(nil, nonce, plaintext, aadFor(purpose)), nil
}

func openWithKeyStore(ks KeyStore, purpose string, nonce, ciphertext []byte) ([]byte, error) {
	gcm, err := gcmFor(ks, false)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, nonce, ciphertext, aadFor(purpose))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrSealedAccount, err)
	}
	return plain, nil
}

func gcmFor(ks KeyStore, create bool) (cipher.AEAD, error) {
	if ks == nil {
		return nil, fmt.Errorf("%w: 未配置 KeyStore", ErrKeyStoreLocked)
	}
	var kek []byte
	var err error
	if create {
		kek, err = ks.EnsureMasterKey()
	} else {
		kek, err = ks.MasterKey()
	}
	if err != nil {
		return nil, err
	}
	if len(kek) != masterKeySize {
		return nil, fmt.Errorf("%w: 主密钥长度 %d", ErrKeyStoreLocked, len(kek))
	}
	block, err := aes.NewCipher(kek)
	if err != nil {
		return nil, fmt.Errorf("初始化 AES: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化 GCM: %w", err)
	}
	return gcm, nil
}

func aadFor(purpose string) []byte {
	return []byte(keystoreDomain + "\x00" + purpose)
}

// writeKeyFile 原子写入主密钥条目（权限 0600）。
func writeKeyFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("创建 Keystore 目录: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".master-key-*.tmp")
	if err != nil {
		return fmt.Errorf("创建临时文件: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("设置临时文件权限: %w", err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("写入主密钥条目: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("关闭主密钥条目: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("替换主密钥条目: %w", err)
	}
	return nil
}

func writeSealedFile(path string, raw []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("创建账号目录: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".account-*.tmp")
	if err != nil {
		return fmt.Errorf("创建临时文件: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("设置临时文件权限: %w", err)
	}
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return fmt.Errorf("写入账号密文: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("同步账号密文: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("关闭账号密文: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("替换账号密文: %w", err)
	}
	return nil
}
