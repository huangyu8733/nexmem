package coreapp

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"testing"

	"github.com/nexmem/core/internal/group"
)

func TestDecodeGroupIDStringAcceptsHexAndBase64URL(t *testing.T) {
	raw := make([]byte, group.GroupIDSize)
	for i := range raw {
		raw[i] = byte(i + 1)
	}
	for _, text := range []string{
		hex.EncodeToString(raw),
		base64.RawURLEncoding.EncodeToString(raw),
	} {
		got, err := decodeGroupIDString(text)
		if err != nil || !bytes.Equal(got, raw) {
			t.Fatalf("群 ID 解码失败: text=%s err=%v got=%x", text, err, got)
		}
	}
	if _, err := decodeGroupIDString("bad-group-id"); err == nil {
		t.Fatal("非法群 ID 应返回错误")
	}
}
