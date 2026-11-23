package identity

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// memKeyStore 是内存主密钥实现，用于确定性测试密钥不符等场景。
type memKeyStore struct {
	key []byte
}

func newMemKeyStore(t *testing.T) *memKeyStore {
	t.Helper()
	key := make([]byte, masterKeySize)
	if _, err := rand.Read(key); err != nil {
		t.Fatal(err)
	}
	return &memKeyStore{key: key}
}

func (s *memKeyStore) MasterKey() ([]byte, error) {
	if len(s.key) != masterKeySize {
		return nil, ErrKeyStoreMissing
	}
	return append([]byte(nil), s.key...), nil
}

func (s *memKeyStore) EnsureMasterKey() ([]byte, error) {
	if len(s.key) != masterKeySize {
		return nil, ErrKeyStoreMissing
	}
	return append([]byte(nil), s.key...), nil
}

func (s *memKeyStore) Delete() {
	s.key = nil
}

func TestSealedAccountRoundTrip(t *testing.T) {
	dir := t.TempDir()
	ks := NewKeyStore(filepath.Join(dir, "master.key"))
	path := filepath.Join(dir, "account.enc")

	acc, err := LoadOrCreateSealedAccount(path, ks)
	if err != nil {
		t.Fatalf("首次创建密文账号失败: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	seedB64 := base64.StdEncoding.EncodeToString(acc.priv.Seed())
	xprivB64 := base64.StdEncoding.EncodeToString(acc.xpriv.Bytes())
	if bytes.Contains(raw, []byte(seedB64)) || bytes.Contains(raw, []byte(xprivB64)) {
		t.Fatal("账号密文文件中出现明文私钥")
	}
	if bytes.Contains(raw, []byte("account_ed25519_seed")) || bytes.Contains(raw, []byte("account_x25519_priv")) {
		t.Fatal("账号密文文件中出现明文字段名")
	}

	var blob sealedBlob
	if err := json.Unmarshal(raw, &blob); err != nil {
		t.Fatalf("密文信封不是合法 JSON: %v", err)
	}
	if blob.Alg != sealedAccountAlg || blob.Ciphertext == "" || blob.Nonce == "" {
		t.Fatalf("密文信封字段异常: %+v", blob)
	}

	loaded, err := LoadSealedAccount(path, ks)
	if err != nil {
		t.Fatalf("重新加载密文账号失败: %v", err)
	}
	if !bytes.Equal(acc.Pub(), loaded.Pub()) || !bytes.Equal(acc.XPub(), loaded.XPub()) {
		t.Fatal("解封后的账号公钥不一致")
	}
	if acc.ID() != loaded.ID() {
		t.Fatal("解封后的账号 ID 不一致")
	}

	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Fatalf("密文账号权限应为 0600，实际 %o", perm)
		}
	}
}

func TestSealedAccountKeyEntryDeleted(t *testing.T) {
	dir := t.TempDir()
	ks := NewKeyStore(filepath.Join(dir, "master.key"))
	path := filepath.Join(dir, "account.enc")

	if _, err := LoadOrCreateSealedAccount(path, ks); err != nil {
		t.Fatalf("创建密文账号失败: %v", err)
	}

	deleter, ok := ks.(interface{ Delete() error })
	if !ok {
		t.Fatal("桌面 KeyStore 应支持 Delete")
	}
	if err := deleter.Delete(); err != nil {
		t.Fatalf("删除 Keystore 条目失败: %v", err)
	}

	if _, err := LoadSealedAccount(path, ks); !errors.Is(err, ErrKeyStoreMissing) {
		t.Fatalf("删除条目后应返回 ErrKeyStoreMissing，实际 %v", err)
	}
}

func TestSealedAccountWrongKeyStore(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "account.enc")

	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	if err := SaveSealedAccount(path, acc, newMemKeyStore(t)); err != nil {
		t.Fatalf("保存密文账号失败: %v", err)
	}
	if _, err := LoadSealedAccount(path, newMemKeyStore(t)); !errors.Is(err, ErrSealedAccount) {
		t.Fatalf("错误主密钥应返回 ErrSealedAccount，实际 %v", err)
	}
}

func TestSealedAccountTampered(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "account.enc")
	ks := newMemKeyStore(t)

	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	if err := SaveSealedAccount(path, acc, ks); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var blob sealedBlob
	if err := json.Unmarshal(raw, &blob); err != nil {
		t.Fatal(err)
	}
	ct, err := base64.StdEncoding.DecodeString(blob.Ciphertext)
	if err != nil {
		t.Fatal(err)
	}
	ct[len(ct)/2] ^= 0xff
	blob.Ciphertext = base64.StdEncoding.EncodeToString(ct)
	tampered, err := json.Marshal(blob)
	if err != nil {
		t.Fatal(err)
	}

	if _, err := OpenAccount(tampered, ks); !errors.Is(err, ErrSealedAccount) {
		t.Fatalf("篡改密文应返回 ErrSealedAccount，实际 %v", err)
	}
}

func TestOpenAccountRejectsBadFormat(t *testing.T) {
	ks := newMemKeyStore(t)
	valid := sealedBlob{
		Version:    sealedAccountVersion,
		Alg:        sealedAccountAlg,
		Nonce:      base64.StdEncoding.EncodeToString(make([]byte, gcmNonceSize)),
		Ciphertext: base64.StdEncoding.EncodeToString([]byte("0123456789abcdef")),
	}
	cases := map[string]sealedBlob{
		"版本不支持":  {Version: 9, Alg: valid.Alg, Nonce: valid.Nonce, Ciphertext: valid.Ciphertext},
		"算法不支持":  {Version: valid.Version, Alg: "XCHACHA", Nonce: valid.Nonce, Ciphertext: valid.Ciphertext},
		"nonce 过短": {Version: valid.Version, Alg: valid.Alg, Nonce: "AAAA", Ciphertext: valid.Ciphertext},
		"密文为空":   {Version: valid.Version, Alg: valid.Alg, Nonce: valid.Nonce, Ciphertext: ""},
	}
	for name, blob := range cases {
		raw, err := json.Marshal(blob)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := OpenAccount(raw, ks); !errors.Is(err, ErrSealedAccountFormat) {
			t.Fatalf("%s: 应返回 ErrSealedAccountFormat，实际 %v", name, err)
		}
	}

	if _, err := OpenAccount([]byte("not-json"), ks); !errors.Is(err, ErrSealedAccountFormat) {
		t.Fatalf("非 JSON 应返回 ErrSealedAccountFormat，实际 %v", err)
	}
}

func TestOpenAccountWithoutKeyStore(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := SealAccount(acc, nil); !errors.Is(err, ErrKeyStoreLocked) {
		t.Fatalf("未配置 KeyStore 应返回 ErrKeyStoreLocked，实际 %v", err)
	}
}
