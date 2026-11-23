// Package dirsig 定义索引服务的请求签名规范（P3-05）。
//
// 客户端与服务端共用同一份规范化逻辑，避免两边各自拼接导致签名漂移。
// 待签内容覆盖协议版本、HTTP 方法、请求路径（含查询串）、Unix 秒级时间戳
// 与请求体 SHA-256，并带版本域前缀做协议隔离，防止签名被复用到其他接口。
package dirsig

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	// Version 是签名规范的协议版本，参与待签字符串。
	Version = "nexmem-directory-v1"
	// HeaderPub 携带无填充 base64url 的账号 ed25519 公钥（32 字节）。
	HeaderPub = "X-Nexmem-Pub"
	// HeaderSig 携带无填充 base64url 的 ed25519 签名（64 字节）。
	HeaderSig = "X-Nexmem-Sig"
	// HeaderTimestamp 携带 Unix 秒级时间戳。
	HeaderTimestamp = "X-Nexmem-Ts"
	// DefaultMaxSkew 是默认允许的时间戳偏移。
	DefaultMaxSkew = 5 * time.Minute
)

// 签名错误分类，服务端据此返回 401。
var (
	// ErrMissingCredentials 表示请求未携带签名头部。
	ErrMissingCredentials = errors.New("缺少请求签名")
	// ErrMalformedCredentials 表示签名头部编码或长度非法。
	ErrMalformedCredentials = errors.New("请求签名格式非法")
	// ErrClockSkew 表示时间戳超出允许偏移，可能是重放或本机时钟错误。
	ErrClockSkew = errors.New("请求时间戳超出允许范围")
	// ErrBadSignature 表示签名与待签内容不匹配。
	ErrBadSignature = errors.New("请求签名校验失败")
)

// Signer 是签名所需的账号密钥能力，*identity.Account 满足该接口。
type Signer interface {
	Pub() ed25519.PublicKey
	Sign(data []byte) []byte
}

// Canonical 构造待签字节：版本、方法、路径（含查询）、时间戳与请求体摘要逐行拼接。
func Canonical(method, requestURI string, ts int64, body []byte) []byte {
	sum := sha256.Sum256(body)
	var b strings.Builder
	b.Grow(len(Version) + len(method) + len(requestURI) + 128)
	b.WriteString(Version)
	b.WriteByte('\n')
	b.WriteString(strings.ToUpper(strings.TrimSpace(method)))
	b.WriteByte('\n')
	b.WriteString(requestURI)
	b.WriteByte('\n')
	b.WriteString(strconv.FormatInt(ts, 10))
	b.WriteByte('\n')
	b.WriteString(hex.EncodeToString(sum[:]))
	return []byte(b.String())
}

// Sign 用账号私钥对规范化内容签名，返回原始 ed25519 签名。
func Sign(s Signer, method, requestURI string, ts int64, body []byte) []byte {
	return s.Sign(Canonical(method, requestURI, ts, body))
}

// Headers 返回请求必须携带的三个签名头部（公钥与签名均为无填充 base64url）。
func Headers(s Signer, method, requestURI string, ts int64, body []byte) map[string]string {
	return map[string]string{
		HeaderPub:       AccountID(s.Pub()),
		HeaderSig:       base64.RawURLEncoding.EncodeToString(Sign(s, method, requestURI, ts, body)),
		HeaderTimestamp: strconv.FormatInt(ts, 10),
	}
}

// AccountID 返回公钥的路径编码（无填充 base64url）。
func AccountID(pub []byte) string {
	return base64.RawURLEncoding.EncodeToString(pub)
}

// Credentials 是解析后的请求凭据。
type Credentials struct {
	Pub       ed25519.PublicKey
	Signature []byte
	Timestamp int64
}

// Parse 解析签名头部并校验编码与长度，不验签。
func Parse(pubRaw, sigRaw, tsRaw string) (Credentials, error) {
	if pubRaw == "" || sigRaw == "" || tsRaw == "" {
		return Credentials{}, ErrMissingCredentials
	}
	pub, err := base64.RawURLEncoding.DecodeString(pubRaw)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return Credentials{}, fmt.Errorf("%w: 账号公钥非法", ErrMalformedCredentials)
	}
	sig, err := base64.RawURLEncoding.DecodeString(sigRaw)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return Credentials{}, fmt.Errorf("%w: 签名非法", ErrMalformedCredentials)
	}
	ts, err := strconv.ParseInt(tsRaw, 10, 64)
	if err != nil {
		return Credentials{}, fmt.Errorf("%w: 时间戳非法", ErrMalformedCredentials)
	}
	return Credentials{Pub: ed25519.PublicKey(pub), Signature: sig, Timestamp: ts}, nil
}

// Verify 先校验时间戳偏移，再校验签名；maxSkew <= 0 时使用 DefaultMaxSkew。
func Verify(c Credentials, method, requestURI string, now time.Time, maxSkew time.Duration, body []byte) error {
	if maxSkew <= 0 {
		maxSkew = DefaultMaxSkew
	}
	skew := now.Sub(time.Unix(c.Timestamp, 0))
	if skew > maxSkew || skew < -maxSkew {
		return ErrClockSkew
	}
	want := Canonical(method, requestURI, c.Timestamp, body)
	if !ed25519.Verify(c.Pub, want, c.Signature) {
		return ErrBadSignature
	}
	return nil
}
