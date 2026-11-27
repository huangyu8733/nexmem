package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
)

// 混合加密（P3-01）：临时 X25519 -> HKDF-SHA256 -> AES-256-GCM。
//
// 离线消息与群密钥信封统一使用该封装：
//   - 每次加密生成一把随机内容密钥（AES-256），用 AES-256-GCM 加密正文；
//   - 内容密钥通过临时 X25519 与接收方 account_x_pub 做 ECDH，
//     经 HKDF-SHA256 派生 KEK 后用 AES-256-GCM 封装；
//   - 只有持有接收方 account_x_priv 的设备能解出内容密钥。
const (
	// EnvelopeKeyAlg 对应 OfflineMessage.key_alg（1 = X25519-HKDF-SHA256-AES256GCM）。
	EnvelopeKeyAlg uint32 = 1
	// ContentKeySize 是内容密钥长度（AES-256）。
	ContentKeySize = 32

	envelopeVersion   byte = 1
	ephemeralKeySize  int  = 32
	envelopeNonceSize int  = 12

	wrapDomain    = "nexmem/key-wrap/v1"
	contentDomain = "nexmem/offline-message/v1"
	kekInfoDomain = "nexmem/x25519-hkdf-sha256/v1|"
)

// ErrSealedOpen 表示信封解密失败：私钥不匹配、密文/封装被篡改或附加数据不一致。
var ErrSealedOpen = errors.New("信封解密失败")

// SealedMessage 是混合加密的完整产物，字段与 OfflineMessage 一一对应。
type SealedMessage struct {
	KeyAlg       uint32
	EncryptedKey []byte // 被接收方 X25519 公钥封装的内容密钥
	Nonce        []byte // 正文 AES-GCM nonce（12B）
	Ciphertext   []byte // 正文密文（含 GCM 认证标签）
}

// SealMessage 用接收方 X25519 公钥加密 plaintext。
// aad 为调用方附加数据（如 msg_uuid/会话 ID），会与域隔离前缀一起参与认证。
func SealMessage(recipientXPub, plaintext, aad []byte) (*SealedMessage, error) {
	contentKey := make([]byte, ContentKeySize)
	if _, err := rand.Read(contentKey); err != nil {
		return nil, fmt.Errorf("生成内容密钥: %w", err)
	}

	encryptedKey, err := WrapContentKey(recipientXPub, contentKey)
	if err != nil {
		return nil, err
	}

	block, err := aes.NewCipher(contentKey)
	if err != nil {
		return nil, fmt.Errorf("初始化内容 AES: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化内容 GCM: %w", err)
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("生成内容 nonce: %w", err)
	}

	return &SealedMessage{
		KeyAlg:       EnvelopeKeyAlg,
		EncryptedKey: encryptedKey,
		Nonce:        nonce,
		Ciphertext:   aead.Seal(nil, nonce, plaintext, contentAAD(aad)),
	}, nil
}

// OpenMessage 用接收方 X25519 私钥解密信封。
// 私钥不符、密文被篡改或 aad 不一致统一返回 ErrSealedOpen。
func OpenMessage(recipientXPriv []byte, msg *SealedMessage, aad []byte) ([]byte, error) {
	if msg == nil {
		return nil, errors.New("信封为空")
	}
	if msg.KeyAlg != EnvelopeKeyAlg {
		return nil, fmt.Errorf("不支持的信封算法: %d", msg.KeyAlg)
	}
	contentKey, err := UnwrapContentKey(recipientXPriv, msg.EncryptedKey)
	if err != nil {
		return nil, err
	}
	if len(msg.Nonce) != envelopeNonceSize {
		return nil, fmt.Errorf("%w: nonce 长度 %d", ErrSealedOpen, len(msg.Nonce))
	}
	block, err := aes.NewCipher(contentKey)
	if err != nil {
		return nil, fmt.Errorf("初始化内容 AES: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化内容 GCM: %w", err)
	}
	plaintext, err := aead.Open(nil, msg.Nonce, msg.Ciphertext, contentAAD(aad))
	if err != nil {
		return nil, ErrSealedOpen
	}
	return plaintext, nil
}

// WrapContentKey 用接收方 X25519 公钥封装 32 字节内容密钥。
// 输出格式：version(1B) | 临时公钥(32B) | nonce(12B) | 密文(48B)。
func WrapContentKey(recipientXPub, contentKey []byte) ([]byte, error) {
	if len(contentKey) != ContentKeySize {
		return nil, fmt.Errorf("内容密钥长度 %d，期望 %d", len(contentKey), ContentKeySize)
	}
	rpub, err := ecdh.X25519().NewPublicKey(recipientXPub)
	if err != nil {
		return nil, fmt.Errorf("接收方 X25519 公钥无效: %w", err)
	}
	eph, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("生成临时 X25519 密钥: %w", err)
	}
	kek, err := deriveKEK(eph, rpub, recipientXPub)
	if err != nil {
		return nil, err
	}
	aead, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("生成封装 nonce: %w", err)
	}
	ephPub := eph.PublicKey().Bytes()
	sealed := aead.Seal(nil, nonce, contentKey, wrapAAD(recipientXPub, ephPub))

	out := make([]byte, 0, 1+ephemeralKeySize+envelopeNonceSize+len(sealed))
	out = append(out, envelopeVersion)
	out = append(out, ephPub...)
	out = append(out, nonce...)
	out = append(out, sealed...)
	return out, nil
}

// UnwrapContentKey 用接收方 X25519 私钥解出内容密钥。
func UnwrapContentKey(recipientXPriv, wrapped []byte) ([]byte, error) {
	const minLen = 1 + ephemeralKeySize + envelopeNonceSize + ContentKeySize + 16
	if len(wrapped) < minLen {
		return nil, fmt.Errorf("%w: 封装长度 %d", ErrSealedOpen, len(wrapped))
	}
	if wrapped[0] != envelopeVersion {
		return nil, fmt.Errorf("%w: 版本 %d", ErrSealedOpen, wrapped[0])
	}
	rpriv, err := ecdh.X25519().NewPrivateKey(recipientXPriv)
	if err != nil {
		return nil, fmt.Errorf("接收方 X25519 私钥无效: %w", err)
	}
	ephPub := wrapped[1 : 1+ephemeralKeySize]
	nonce := wrapped[1+ephemeralKeySize : 1+ephemeralKeySize+envelopeNonceSize]
	sealed := wrapped[1+ephemeralKeySize+envelopeNonceSize:]

	eph, err := ecdh.X25519().NewPublicKey(ephPub)
	if err != nil {
		return nil, fmt.Errorf("%w: 临时公钥无效", ErrSealedOpen)
	}
	kek, err := deriveKEK(rpriv, eph, rpriv.PublicKey().Bytes())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrSealedOpen, err)
	}
	aead, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	contentKey, err := aead.Open(nil, nonce, sealed, wrapAAD(rpriv.PublicKey().Bytes(), ephPub))
	if err != nil {
		return nil, ErrSealedOpen
	}
	return contentKey, nil
}

// deriveKEK 做 ECDH 并用 HKDF-SHA256 派生 32 字节 KEK。
// info 绑定接收方公钥，保证收发两侧派生同一 KEK，同时避免跨接收方上下文复用。
func deriveKEK(priv *ecdh.PrivateKey, peer *ecdh.PublicKey, boundPub []byte) ([]byte, error) {
	shared, err := priv.ECDH(peer)
	if err != nil {
		return nil, fmt.Errorf("X25519 密钥协商失败: %w", err)
	}
	info := append([]byte(kekInfoDomain), boundPub...)
	return hkdfSHA256(shared, nil, info, ContentKeySize)
}

// hkdfSHA256 按 RFC 5869 做 extract + expand。
func hkdfSHA256(secret, salt, info []byte, length int) ([]byte, error) {
	out, err := hkdf.Key(sha256.New, secret, salt, string(info), length)
	if err != nil {
		return nil, fmt.Errorf("HKDF 派生: %w", err)
	}
	return out, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("初始化 AES: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化 GCM: %w", err)
	}
	return aead, nil
}

func wrapAAD(recipientXPub, ephPub []byte) []byte {
	out := make([]byte, 0, len(wrapDomain)+len(recipientXPub)+len(ephPub))
	out = append(out, wrapDomain...)
	out = append(out, recipientXPub...)
	out = append(out, ephPub...)
	return out
}

func contentAAD(aad []byte) []byte {
	out := make([]byte, 0, len(contentDomain)+len(aad))
	out = append(out, contentDomain...)
	out = append(out, aad...)
	return out
}
