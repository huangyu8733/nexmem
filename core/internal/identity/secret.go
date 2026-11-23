package identity

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// ErrSealedSecret 表示敏感配置密文校验失败（主密钥不符或内容被篡改）。
var ErrSealedSecret = errors.New("敏感配置密文校验失败")

// ErrSealedSecretFormat 表示敏感配置密文格式非法。
var ErrSealedSecretFormat = errors.New("敏感配置密文格式非法")

// SealSecret 用 Keystore 主密钥封装一段敏感配置（如离线存储 AK/SK）。
//
// purpose 参与 AAD，保证同一主密钥下不同用途的密文不可互换。
func SealSecret(ks KeyStore, purpose string, plaintext []byte) ([]byte, error) {
	if strings.TrimSpace(purpose) == "" {
		return nil, errors.New("封装敏感配置缺少用途标识")
	}
	if len(plaintext) == 0 {
		return nil, errors.New("封装敏感配置的明文为空")
	}
	nonce, ct, err := sealWithKeyStore(ks, purpose, plaintext)
	if err != nil {
		return nil, err
	}
	raw, err := json.Marshal(sealedBlob{
		Version:    sealedAccountVersion,
		Alg:        sealedAccountAlg,
		Nonce:      base64.StdEncoding.EncodeToString(nonce),
		Ciphertext: base64.StdEncoding.EncodeToString(ct),
	})
	if err != nil {
		return nil, fmt.Errorf("序列化敏感配置密文: %w", err)
	}
	return raw, nil
}

// OpenSecret 解封 SealSecret 产出的敏感配置密文。
func OpenSecret(ks KeyStore, purpose string, raw []byte) ([]byte, error) {
	var b sealedBlob
	if err := json.Unmarshal(raw, &b); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrSealedSecretFormat, err)
	}
	if b.Version != sealedAccountVersion {
		return nil, fmt.Errorf("%w: 版本 %d 不支持", ErrSealedSecretFormat, b.Version)
	}
	if b.Alg != sealedAccountAlg {
		return nil, fmt.Errorf("%w: 算法 %q 不支持", ErrSealedSecretFormat, b.Alg)
	}
	nonce, err := base64.StdEncoding.DecodeString(b.Nonce)
	if err != nil || len(nonce) != gcmNonceSize {
		return nil, fmt.Errorf("%w: nonce 非法", ErrSealedSecretFormat)
	}
	ct, err := base64.StdEncoding.DecodeString(b.Ciphertext)
	if err != nil || len(ct) == 0 {
		return nil, fmt.Errorf("%w: 密文非法", ErrSealedSecretFormat)
	}
	plain, err := openWithKeyStore(ks, purpose, nonce, ct)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrSealedSecret, err)
	}
	return plain, nil
}
