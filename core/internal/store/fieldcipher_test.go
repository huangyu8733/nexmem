package store

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"path/filepath"
	"testing"
)

func TestFieldCipherRoundTrip(t *testing.T) {
	master := bytes.Repeat([]byte{0x2a}, 32)
	c, err := NewFieldCipher(master)
	if err != nil {
		t.Fatalf("NewFieldCipher: %v", err)
	}
	for _, plain := range []string{"备注名", "同事/朋友", "a", ""} {
		sealed, err := c.Seal(plain)
		if err != nil {
			t.Fatalf("Seal(%q): %v", plain, err)
		}
		if plain == "" {
			if sealed != "" {
				t.Fatalf("空串应原样返回，实际 %q", sealed)
			}
			continue
		}
		if !IsEncrypted(sealed) {
			t.Fatalf("Seal(%q) 未带加密标记: %q", plain, sealed)
		}
		// 短明文（1~2 字符）可能在 base64 中偶然出现，仅对足够长的明文检查。
		if len([]rune(plain)) >= 4 && bytes.Contains([]byte(sealed), []byte(plain)) {
			t.Fatalf("密文中不应含明文 %q: %q", plain, sealed)
		}
		opened, err := c.Open(sealed)
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		if opened != plain {
			t.Fatalf("往返不一致: %q != %q", opened, plain)
		}
	}
}

func TestFieldCipherLegacyPlaintext(t *testing.T) {
	c, err := NewFieldCipher(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	// 历史明文（无前缀）解封时原样返回，保证旧库可读。
	for _, legacy := range []string{"old-alias", "老标题", ""} {
		got, err := c.Open(legacy)
		if err != nil {
			t.Fatalf("Open(legacy %q): %v", legacy, err)
		}
		if got != legacy {
			t.Fatalf("旧明文被改写: %q != %q", got, legacy)
		}
	}
}

func TestFieldCipherWrongKeyAndTamper(t *testing.T) {
	c1, _ := NewFieldCipher(bytes.Repeat([]byte{1}, 32))
	c2, _ := NewFieldCipher(bytes.Repeat([]byte{2}, 32))
	sealed, _ := c1.Seal("秘密")
	if _, err := c2.Open(sealed); !errors.Is(err, ErrFieldDecrypt) {
		t.Fatalf("错误密钥应拒绝: %v", err)
	}
	// 篡改密文：解码后翻转密文字节再重新编码，确保字节真实变化。
	body := bytes.TrimPrefix([]byte(sealed), []byte(FieldEncPrefix))
	decoded, err := base64.RawURLEncoding.DecodeString(string(body))
	if err != nil {
		t.Fatal(err)
	}
	decoded[len(decoded)-1] ^= 0xff
	tampered := FieldEncPrefix + base64.RawURLEncoding.EncodeToString(decoded)
	if _, err := c1.Open(tampered); !errors.Is(err, ErrFieldDecrypt) {
		t.Fatalf("篡改密文应拒绝: %v", err)
	}
}

func TestFieldCipherRejectsShortKey(t *testing.T) {
	if _, err := NewFieldCipher([]byte{1, 2, 3}); !errors.Is(err, ErrFieldCipherKey) {
		t.Fatalf("短密钥应拒绝: %v", err)
	}
}

func TestFieldCipherDAOIntegration(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "enc.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	if err := Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	dao := NewDAO(db)
	cipher, _ := NewFieldCipher(bytes.Repeat([]byte{9}, 32))
	dao.SetFieldCipher(cipher)

	pub := bytes.Repeat([]byte{3}, 32)
	if err := dao.UpsertContact(ctx, Contact{
		AccountPub: pub, Alias: "秘密备注", GroupName: "密友",
	}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}
	// 直接读原始库：remark 字段必须是密文，不含明文。
	var rawAlias string
	if err := db.QueryRowContext(ctx,
		`SELECT alias FROM contacts WHERE account_pub = ?`, pub).Scan(&rawAlias); err != nil {
		t.Fatal(err)
	}
	if !IsEncrypted(rawAlias) || bytes.Contains([]byte(rawAlias), []byte("秘密备注")) {
		t.Fatalf("库中备注未加密: %q", rawAlias)
	}
	// DAO 读取透明解封。
	got, err := dao.GetContact(ctx, pub)
	if err != nil {
		t.Fatal(err)
	}
	if got.Alias != "秘密备注" || got.GroupName != "密友" {
		t.Fatalf("解封后字段不一致: %+v", got)
	}

	// 会话标题同样加密。
	if err := dao.UpsertConversation(ctx, Conversation{
		ID: "dm:x|y", Title: "私密会话", Kind: ConversationKindDM,
	}); err != nil {
		t.Fatal(err)
	}
	var rawTitle string
	if err := db.QueryRowContext(ctx,
		`SELECT title FROM conversations WHERE id = ?`, "dm:x|y").Scan(&rawTitle); err != nil {
		t.Fatal(err)
	}
	if !IsEncrypted(rawTitle) || bytes.Contains([]byte(rawTitle), []byte("私密会话")) {
		t.Fatalf("库中标题未加密: %q", rawTitle)
	}
	conv, err := dao.GetConversation(ctx, "dm:x|y")
	if err != nil {
		t.Fatal(err)
	}
	if conv.Title != "私密会话" {
		t.Fatalf("解封标题=%q", conv.Title)
	}
}
