package crypto

import (
	"bytes"
	"errors"
	"testing"
)

func TestChunkCipherRoundTrip(t *testing.T) {
	key, err := GenerateFileKey()
	if err != nil {
		t.Fatal(err)
	}
	c, err := NewChunkCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	for i := uint32(0); i < 5; i++ {
		plain := bytes.Repeat([]byte{byte(i + 1)}, int(1024*(i+1)))
		sealed := c.Seal(i, plain)
		if bytes.Equal(sealed, plain) {
			t.Fatalf("第 %d 片密文与明文相同", i)
		}
		got, err := c.Open(i, sealed)
		if err != nil {
			t.Fatalf("第 %d 片解密失败: %v", i, err)
		}
		if !bytes.Equal(got, plain) {
			t.Fatalf("第 %d 片解密内容不一致", i)
		}
	}
}

func TestChunkCipherWrongKeyFails(t *testing.T) {
	key1, _ := GenerateFileKey()
	key2, _ := GenerateFileKey()
	c1, err := NewChunkCipher(key1)
	if err != nil {
		t.Fatal(err)
	}
	c2, err := NewChunkCipher(key2)
	if err != nil {
		t.Fatal(err)
	}
	sealed := c1.Seal(0, []byte("secret payload"))
	if _, err := c2.Open(0, sealed); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("错误密钥应返回 ErrDecrypt，实际 %v", err)
	}
	if _, err := c1.Open(1, sealed); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("错位分片应返回 ErrDecrypt，实际 %v", err)
	}
}

func TestChunkCipherTamperFails(t *testing.T) {
	key, _ := GenerateFileKey()
	c, err := NewChunkCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	sealed := c.Seal(3, []byte("payload"))
	sealed[len(sealed)-1] ^= 0xff
	if _, err := c.Open(3, sealed); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("篡改密文应返回 ErrDecrypt，实际 %v", err)
	}
}

func TestChunkCipherRejectsBadKeySize(t *testing.T) {
	if _, err := NewChunkCipher(make([]byte, 16)); err == nil {
		t.Fatal("非 32 字节密钥应报错")
	}
}
