package crypto

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"testing"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("解码十六进制 %q: %v", s, err)
	}
	return b
}

// RFC 5869 附录 A 的固定测试向量，验证 HKDF-SHA256 派生结果。
func TestHKDFRFC5869Vectors(t *testing.T) {
	cases := []struct {
		name   string
		ikm    string
		salt   string
		info   string
		length int
		okm    string
	}{
		{
			name:   "case1",
			ikm:    "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b",
			salt:   "000102030405060708090a0b0c",
			info:   "f0f1f2f3f4f5f6f7f8f9",
			length: 42,
			okm:    "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
		},
		{
			name: "case2",
			ikm: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" +
				"202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f" +
				"404142434445464748494a4b4c4d4e4f",
			salt: "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f" +
				"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f" +
				"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf",
			info: "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecf" +
				"d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef" +
				"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
			length: 82,
			okm: "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c" +
				"59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71" +
				"cc30c58179ec3e87c14c01d5c1f3434f1d87",
		},
		{
			name:   "case3",
			ikm:    "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b",
			salt:   "",
			info:   "",
			length: 42,
			okm:    "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := hkdfSHA256(mustHex(t, c.ikm), mustHex(t, c.salt), mustHex(t, c.info), c.length)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, mustHex(t, c.okm)) {
				t.Fatalf("OKM 不一致\n got=%x\nwant=%s", got, c.okm)
			}
		})
	}
}

// RFC 7748 §6.1 固定向量，确认 X25519 协商结果。
func TestX25519RFC7748Vector(t *testing.T) {
	alicePriv := mustHex(t, "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	alicePub := mustHex(t, "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
	bobPriv := mustHex(t, "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	bobPub := mustHex(t, "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
	wantShared := mustHex(t, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

	apr, err := ecdh.X25519().NewPrivateKey(alicePriv)
	if err != nil {
		t.Fatal(err)
	}
	bpr, err := ecdh.X25519().NewPrivateKey(bobPriv)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(apr.PublicKey().Bytes(), alicePub) {
		t.Fatalf("Alice 公钥不一致: %x", apr.PublicKey().Bytes())
	}
	if !bytes.Equal(bpr.PublicKey().Bytes(), bobPub) {
		t.Fatalf("Bob 公钥不一致: %x", bpr.PublicKey().Bytes())
	}
	sharedAB, err := apr.ECDH(bpr.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	sharedBA, err := bpr.ECDH(apr.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sharedAB, wantShared) || !bytes.Equal(sharedBA, wantShared) {
		t.Fatalf("共享密钥不一致: %x / %x", sharedAB, sharedBA)
	}

	kekAB, err := deriveKEK(apr, bpr.PublicKey(), bobPub)
	if err != nil {
		t.Fatal(err)
	}
	kekBA, err := deriveKEK(bpr, apr.PublicKey(), bobPub)
	if err != nil {
		t.Fatal(err)
	}
	if len(kekAB) != ContentKeySize || !bytes.Equal(kekAB, kekBA) {
		t.Fatalf("KEK 派生不一致: %x / %x", kekAB, kekBA)
	}
}

func TestSealOpenRoundTrip(t *testing.T) {
	recipient, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	aad := []byte("dm:alice|bob|msg-001")
	for _, plain := range [][]byte{[]byte("hello nexmem"), {}, bytes.Repeat([]byte("x"), 4096)} {
		msg, err := SealMessage(recipient.PublicKey().Bytes(), plain, aad)
		if err != nil {
			t.Fatal(err)
		}
		if msg.KeyAlg != EnvelopeKeyAlg {
			t.Fatalf("key_alg=%d", msg.KeyAlg)
		}
		if len(msg.Nonce) != envelopeNonceSize {
			t.Fatalf("nonce 长度 %d", len(msg.Nonce))
		}
		got, err := OpenMessage(recipient.Bytes(), msg, aad)
		if err != nil {
			t.Fatalf("解密失败: %v", err)
		}
		if !bytes.Equal(got, plain) {
			t.Fatalf("解密内容不一致")
		}
	}
}

func TestOpenWithWrongKeyFails(t *testing.T) {
	right, _ := ecdh.X25519().GenerateKey(rand.Reader)
	wrong, _ := ecdh.X25519().GenerateKey(rand.Reader)
	msg, err := SealMessage(right.PublicKey().Bytes(), []byte("secret"), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenMessage(wrong.Bytes(), msg, nil); !errors.Is(err, ErrSealedOpen) {
		t.Fatalf("错误私钥应返回 ErrSealedOpen，实际 %v", err)
	}
}

func TestOpenTamperedFails(t *testing.T) {
	recipient, _ := ecdh.X25519().GenerateKey(rand.Reader)
	base, err := SealMessage(recipient.PublicKey().Bytes(), []byte("tamper me"), []byte("aad"))
	if err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name string
		mut  func(*SealedMessage)
	}{
		{"密文篡改", func(m *SealedMessage) { m.Ciphertext[0] ^= 0xff }},
		{"认证标签篡改", func(m *SealedMessage) { m.Ciphertext[len(m.Ciphertext)-1] ^= 0xff }},
		{"封装篡改", func(m *SealedMessage) { m.EncryptedKey[len(m.EncryptedKey)-1] ^= 0xff }},
		{"临时公钥篡改", func(m *SealedMessage) { m.EncryptedKey[1] ^= 0x01 }},
		{"nonce 篡改", func(m *SealedMessage) { m.Nonce[0] ^= 0xff }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := &SealedMessage{
				KeyAlg:       base.KeyAlg,
				EncryptedKey: append([]byte(nil), base.EncryptedKey...),
				Nonce:        append([]byte(nil), base.Nonce...),
				Ciphertext:   append([]byte(nil), base.Ciphertext...),
			}
			c.mut(m)
			if _, err := OpenMessage(recipient.Bytes(), m, []byte("aad")); !errors.Is(err, ErrSealedOpen) {
				t.Fatalf("篡改后应返回 ErrSealedOpen，实际 %v", err)
			}
		})
	}
}

func TestOpenAADMismatchFails(t *testing.T) {
	recipient, _ := ecdh.X25519().GenerateKey(rand.Reader)
	msg, err := SealMessage(recipient.PublicKey().Bytes(), []byte("bound"), []byte("msg-1"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenMessage(recipient.Bytes(), msg, []byte("msg-2")); !errors.Is(err, ErrSealedOpen) {
		t.Fatalf("AAD 不一致应返回 ErrSealedOpen，实际 %v", err)
	}
}

func TestSealRejectsBadInputs(t *testing.T) {
	if _, err := SealMessage([]byte("short"), []byte("x"), nil); err == nil {
		t.Fatal("非法接收方公钥应报错")
	}
	if _, err := WrapContentKey([]byte("short"), make([]byte, ContentKeySize)); err == nil {
		t.Fatal("非法接收方公钥应报错")
	}
	recipient, _ := ecdh.X25519().GenerateKey(rand.Reader)
	if _, err := WrapContentKey(recipient.PublicKey().Bytes(), make([]byte, 16)); err == nil {
		t.Fatal("非 32 字节内容密钥应报错")
	}
	if _, err := UnwrapContentKey(recipient.Bytes(), []byte{1, 2, 3}); !errors.Is(err, ErrSealedOpen) {
		t.Fatalf("过短封装应返回 ErrSealedOpen，实际 %v", err)
	}
}

func TestOpenRejectsUnknownAlg(t *testing.T) {
	recipient, _ := ecdh.X25519().GenerateKey(rand.Reader)
	msg, err := SealMessage(recipient.PublicKey().Bytes(), []byte("x"), nil)
	if err != nil {
		t.Fatal(err)
	}
	msg.KeyAlg = 99
	if _, err := OpenMessage(recipient.Bytes(), msg, nil); err == nil {
		t.Fatal("未知算法应报错")
	}
}

func TestWrapContentKeyRoundTrip(t *testing.T) {
	recipient, _ := ecdh.X25519().GenerateKey(rand.Reader)
	wrong, _ := ecdh.X25519().GenerateKey(rand.Reader)
	key := bytes.Repeat([]byte{0x42}, ContentKeySize)

	wrapped, err := WrapContentKey(recipient.PublicKey().Bytes(), key)
	if err != nil {
		t.Fatal(err)
	}
	got, err := UnwrapContentKey(recipient.Bytes(), wrapped)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, key) {
		t.Fatal("解封内容密钥不一致")
	}
	if _, err := UnwrapContentKey(wrong.Bytes(), wrapped); !errors.Is(err, ErrSealedOpen) {
		t.Fatalf("错误私钥解封应返回 ErrSealedOpen，实际 %v", err)
	}
}
