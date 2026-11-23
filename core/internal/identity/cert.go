package identity

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

const (
	certDomain    = "nexmem/device-cert/v1"
	profileDomain = "nexmem/public-profile/v1"

	// DefaultDeviceCertTTL 设备证书默认有效期。
	DefaultDeviceCertTTL = 365 * 24 * time.Hour
)

// ErrInvalidSignature 表示签名校验失败（含证书被篡改）。
var ErrInvalidSignature = errors.New("签名校验失败")

// IssueDeviceCert 用账号私钥为设备公钥签发 DeviceCert。
// devicePub 是设备 libp2p 公钥的序列化字节。
func (a *Account) IssueDeviceCert(devicePub []byte, deviceName string, ttl time.Duration) (*nexmemv1.DeviceCert, error) {
	if len(devicePub) == 0 {
		return nil, errors.New("设备公钥为空")
	}
	if ttl <= 0 {
		ttl = DefaultDeviceCertTTL
	}
	now := time.Now()
	cert := &nexmemv1.DeviceCert{
		AccountPub:  a.Pub(),
		AccountXPub: a.XPub(),
		DevicePub:   append([]byte(nil), devicePub...),
		DeviceName:  deviceName,
		IssuedAt:    now.Unix(),
		NotAfter:    now.Add(ttl).Unix(),
	}
	cert.Signature = ed25519.Sign(a.priv, canonicalCert(cert))
	return cert, nil
}

// VerifyDeviceCert 校验设备证书的签名、字段与有效期。
func VerifyDeviceCert(cert *nexmemv1.DeviceCert, now time.Time) error {
	if cert == nil {
		return errors.New("设备证书为空")
	}
	if len(cert.AccountPub) != ed25519.PublicKeySize {
		return fmt.Errorf("账号公钥长度错误: %d", len(cert.AccountPub))
	}
	if len(cert.AccountXPub) != 32 {
		return fmt.Errorf("账号 X25519 公钥长度错误: %d", len(cert.AccountXPub))
	}
	if len(cert.DevicePub) == 0 {
		return errors.New("设备公钥为空")
	}
	if cert.NotAfter <= cert.IssuedAt {
		return errors.New("设备证书有效期非法")
	}
	if now.After(time.Unix(cert.NotAfter, 0)) {
		return errors.New("设备证书已过期")
	}
	if len(cert.Signature) != ed25519.SignatureSize {
		return fmt.Errorf("签名长度错误: %d", len(cert.Signature))
	}
	if !ed25519.Verify(ed25519.PublicKey(cert.AccountPub), canonicalCert(cert), cert.Signature) {
		return ErrInvalidSignature
	}
	return nil
}

// SignProfile 用账号私钥为公开档案签名，写入 p.Signature。
func (a *Account) SignProfile(p *nexmemv1.PublicProfile) error {
	if p == nil {
		return errors.New("公开档案为空")
	}
	p.AccountPub = a.Pub()
	p.AccountXPub = a.XPub()
	p.Signature = ed25519.Sign(a.priv, canonicalProfile(p))
	return nil
}

// VerifyPublicProfile 校验公开档案签名，并确认其下每张设备证书都属于该账号。
func VerifyPublicProfile(p *nexmemv1.PublicProfile, now time.Time) error {
	if p == nil {
		return errors.New("公开档案为空")
	}
	if len(p.AccountPub) != ed25519.PublicKeySize {
		return fmt.Errorf("账号公钥长度错误: %d", len(p.AccountPub))
	}
	if len(p.Signature) != ed25519.SignatureSize {
		return fmt.Errorf("签名长度错误: %d", len(p.Signature))
	}
	if !ed25519.Verify(ed25519.PublicKey(p.AccountPub), canonicalProfile(p), p.Signature) {
		return ErrInvalidSignature
	}
	for i, d := range p.Devices {
		if !bytes.Equal(d.AccountPub, p.AccountPub) {
			return fmt.Errorf("第 %d 张设备证书账号不匹配", i)
		}
		if err := VerifyDeviceCert(d, now); err != nil {
			return fmt.Errorf("第 %d 张设备证书无效: %w", i, err)
		}
	}
	return nil
}

// canonicalCert 生成字段 1..6 的确定性编码，用于签名与验签。
// 每段带 4 字节长度前缀，避免字段拼接歧义；域名做域隔离。
func canonicalCert(c *nexmemv1.DeviceCert) []byte {
	var buf bytes.Buffer
	writeChunk(&buf, []byte(certDomain))
	writeChunk(&buf, c.AccountPub)
	writeChunk(&buf, c.AccountXPub)
	writeChunk(&buf, c.DevicePub)
	writeChunk(&buf, []byte(c.DeviceName))
	writeInt64(&buf, c.IssuedAt)
	writeInt64(&buf, c.NotAfter)
	return buf.Bytes()
}

func canonicalProfile(p *nexmemv1.PublicProfile) []byte {
	var buf bytes.Buffer
	writeChunk(&buf, []byte(profileDomain))
	writeChunk(&buf, p.AccountPub)
	writeChunk(&buf, p.AccountXPub)
	if p.OfflineEnabled {
		writeChunk(&buf, []byte{1})
	} else {
		writeChunk(&buf, []byte{0})
	}
	writeInt64(&buf, p.UpdatedAt)
	for _, d := range p.Devices {
		writeChunk(&buf, canonicalCert(d))
	}
	return buf.Bytes()
}

func writeChunk(w *bytes.Buffer, b []byte) {
	var l [4]byte
	binary.BigEndian.PutUint32(l[:], uint32(len(b)))
	w.Write(l[:])
	w.Write(b)
}

func writeInt64(w *bytes.Buffer, v int64) {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(v))
	w.Write(b[:])
}
