package qrshare

import (
	"errors"
	"strings"
	"testing"

	"github.com/nexmem/core/internal/identity"
)

func testAccount(t *testing.T) *identity.Account {
	t.Helper()
	acc, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成账号: %v", err)
	}
	return acc
}

func TestEncodeDecodeRoundTrip(t *testing.T) {
	acc := testAccount(t)
	payload, err := Encode(acc, "12D3KooWDevice", "张三")
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	if !strings.HasPrefix(payload, Prefix) {
		t.Fatalf("载荷缺少前缀: %s", payload[:min(20, len(payload))])
	}
	card, err := Decode(payload)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if card.AccountID != acc.ID() {
		t.Fatalf("账号 ID = %s，期望 %s", card.AccountID, acc.ID())
	}
	if card.DeviceID != "12D3KooWDevice" {
		t.Fatalf("设备 ID = %s", card.DeviceID)
	}
	if card.DisplayName != "张三" {
		t.Fatalf("昵称 = %s", card.DisplayName)
	}
}

func TestDecodeRejectsTamper(t *testing.T) {
	acc := testAccount(t)
	payload, err := Encode(acc, "d1", "Alice")
	if err != nil {
		t.Fatal(err)
	}
	// 篡改 base64 载荷中的一个字符（保持可解码），验签必须失败。
	raw := strings.TrimPrefix(payload, Prefix)
	if len(raw) < 4 {
		t.Fatal("载荷过短")
	}
	replacement := "A"
	if raw[len(raw)/2] == 'A' {
		replacement = "B"
	}
	tampered := Prefix + raw[:len(raw)/2] + replacement + raw[len(raw)/2+1:]
	_, err = Decode(tampered)
	if !errors.Is(err, ErrSignature) && !errors.Is(err, ErrFormat) {
		t.Fatalf("篡改载荷应被拒绝，实际 err=%v", err)
	}
}

func TestDecodeRejectsForeignPayload(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		want    error
	}{
		{"缺少前缀", "hello", ErrFormat},
		{"空载荷", Prefix, ErrFormat},
		{"非法 base64", Prefix + "!!!not-base64!!!", ErrFormat},
		// {"p":{}} 可解析但版本为 0：应被拒绝（任一版本/格式错误均视为拒绝）。
		{"版本错误", Prefix + "eyJwIjp7fX0", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Decode(c.payload)
			if err == nil {
				t.Fatal("期望拒绝非法载荷")
			}
			if c.want != nil && !errors.Is(err, c.want) && !errors.Is(err, ErrFormat) {
				t.Fatalf("err=%v，期望 %v", err, c.want)
			}
			if c.want == nil && !errors.Is(err, ErrVersion) && !errors.Is(err, ErrFormat) && !errors.Is(err, ErrSignature) {
				t.Fatalf("err=%v，期望版本/格式/签名类错误", err)
			}
		})
	}
}

func TestEncodeRejectsLongName(t *testing.T) {
	acc := testAccount(t)
	_, err := Encode(acc, "", strings.Repeat("名", maxNameLen+1))
	if !errors.Is(err, ErrFormat) {
		t.Fatalf("超长昵称应拒绝，实际 err=%v", err)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
