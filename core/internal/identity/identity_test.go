package identity

import (
	"bytes"
	"errors"
	"path/filepath"
	"testing"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

func TestAccountPersistRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "account.json")
	acc, err := LoadOrCreateAccount(path)
	if err != nil {
		t.Fatalf("首次创建账号失败: %v", err)
	}
	if len(acc.Pub()) != 32 || len(acc.XPub()) != 32 {
		t.Fatalf("公钥长度异常: ed=%d x=%d", len(acc.Pub()), len(acc.XPub()))
	}

	loaded, err := LoadOrCreateAccount(path)
	if err != nil {
		t.Fatalf("重新加载账号失败: %v", err)
	}
	if !bytes.Equal(acc.Pub(), loaded.Pub()) {
		t.Fatal("账号公钥不一致")
	}
	if !bytes.Equal(acc.XPub(), loaded.XPub()) {
		t.Fatal("账号 X25519 公钥不一致")
	}
	if acc.ID() != loaded.ID() {
		t.Fatal("账号 ID 不一致")
	}
}

func TestDeviceCertVerify(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	devicePub := bytes.Repeat([]byte{7}, 32)
	cert, err := acc.IssueDeviceCert(devicePub, "Pixel 9", time.Hour)
	if err != nil {
		t.Fatalf("签发设备证书失败: %v", err)
	}
	if err := VerifyDeviceCert(cert, time.Now()); err != nil {
		t.Fatalf("设备证书应校验通过: %v", err)
	}
}

func TestTwoDeviceCertsSameAccount(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	phone, err := acc.IssueDeviceCert(bytes.Repeat([]byte{1}, 32), "手机", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	laptop, err := acc.IssueDeviceCert(bytes.Repeat([]byte{2}, 32), "笔记本", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(phone.DevicePub, laptop.DevicePub) {
		t.Fatal("两台设备应使用不同设备公钥")
	}
	for _, c := range []*nexmemv1.DeviceCert{phone, laptop} {
		if err := VerifyDeviceCert(c, time.Now()); err != nil {
			t.Fatalf("设备 %s 证书应校验通过: %v", c.DeviceName, err)
		}
		if !bytes.Equal(c.AccountPub, acc.Pub()) {
			t.Fatalf("设备 %s 证书账号不匹配", c.DeviceName)
		}
	}
}

func TestDeviceCertTampered(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	cert, err := acc.IssueDeviceCert(bytes.Repeat([]byte{7}, 32), "Pixel 9", time.Hour)
	if err != nil {
		t.Fatal(err)
	}

	tampered := &nexmemv1.DeviceCert{
		AccountPub:  cert.AccountPub,
		AccountXPub: cert.AccountXPub,
		DevicePub:   cert.DevicePub,
		DeviceName:  "攻击者设备",
		IssuedAt:    cert.IssuedAt,
		NotAfter:    cert.NotAfter,
		Signature:   cert.Signature,
	}
	if err := VerifyDeviceCert(tampered, time.Now()); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("篡改字段后应验签失败, 实际: %v", err)
	}

	tamperedPub := &nexmemv1.DeviceCert{
		AccountPub:  cert.AccountPub,
		AccountXPub: cert.AccountXPub,
		DevicePub:   bytes.Repeat([]byte{9}, 32),
		DeviceName:  cert.DeviceName,
		IssuedAt:    cert.IssuedAt,
		NotAfter:    cert.NotAfter,
		Signature:   cert.Signature,
	}
	if err := VerifyDeviceCert(tamperedPub, time.Now()); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("篡改设备公钥后应验签失败, 实际: %v", err)
	}
}

func TestDeviceCertExpired(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	cert, err := acc.IssueDeviceCert(bytes.Repeat([]byte{1}, 32), "旧设备", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyDeviceCert(cert, time.Now().Add(2*time.Minute)); err == nil {
		t.Fatal("过期证书应校验失败")
	}
}

func TestPublicProfileVerify(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	cert, err := acc.IssueDeviceCert(bytes.Repeat([]byte{3}, 32), "ThinkPad", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	p := &nexmemv1.PublicProfile{
		Devices:        []*nexmemv1.DeviceCert{cert},
		OfflineEnabled: true,
		UpdatedAt:      time.Now().Unix(),
	}
	if err := acc.SignProfile(p); err != nil {
		t.Fatalf("签名公开档案失败: %v", err)
	}
	if err := VerifyPublicProfile(p, time.Now()); err != nil {
		t.Fatalf("公开档案应校验通过: %v", err)
	}

	p.OfflineEnabled = false
	if err := VerifyPublicProfile(p, time.Now()); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("篡改公开档案后应验签失败, 实际: %v", err)
	}
}

func TestPublicProfileRejectsForeignDevice(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	other, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	foreign, err := other.IssueDeviceCert(bytes.Repeat([]byte{5}, 32), "他人设备", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	p := &nexmemv1.PublicProfile{
		Devices:   []*nexmemv1.DeviceCert{foreign},
		UpdatedAt: time.Now().Unix(),
	}
	if err := acc.SignProfile(p); err != nil {
		t.Fatal(err)
	}
	if err := VerifyPublicProfile(p, time.Now()); err == nil {
		t.Fatal("混入他人设备证书应校验失败")
	}
}
