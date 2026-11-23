package identity

import (
	"errors"
	"testing"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

func sampleOffline() *nexmemv1.OfflineMessage {
	return &nexmemv1.OfflineMessage{
		MsgUuid:         "0192f3c0-0000-7000-8000-000000000001",
		Timestamp:       1_730_000_000_000,
		ReceiverAccount: make([]byte, 32),
		ConversationId:  []byte("dm:abc"),
		EncryptedKey:    []byte("wrapped-key"),
		Nonce:           []byte("nonce-12byte"),
		Ciphertext:      []byte("ciphertext"),
		KeyAlg:          1,
		ContentType:     nexmemv1.ContentType_CONTENT_TYPE_TEXT,
		TtlHours:        168,
	}
}

func TestOfflineMessageSignVerify(t *testing.T) {
	acc, err := GenerateAccount()
	if err != nil {
		t.Fatal(err)
	}
	m := sampleOffline()
	if err := acc.SignOfflineMessage(m); err != nil {
		t.Fatalf("签名: %v", err)
	}
	if err := VerifyOfflineMessage(m); err != nil {
		t.Fatalf("验签应通过: %v", err)
	}

	tampered := []*nexmemv1.OfflineMessage{}
	for _, mutate := range []func(*nexmemv1.OfflineMessage){
		func(m *nexmemv1.OfflineMessage) { m.Ciphertext = []byte("tampered") },
		func(m *nexmemv1.OfflineMessage) { m.MsgUuid = "other" },
		func(m *nexmemv1.OfflineMessage) { m.TtlHours++ },
		func(m *nexmemv1.OfflineMessage) { m.ContentType = nexmemv1.ContentType_CONTENT_TYPE_FILE },
	} {
		c := proto.Clone(m).(*nexmemv1.OfflineMessage)
		mutate(c)
		tampered = append(tampered, c)
	}
	for i, c := range tampered {
		if err := VerifyOfflineMessage(c); !errors.Is(err, ErrInvalidSignature) {
			t.Fatalf("第 %d 项篡改应返回 ErrInvalidSignature，实际 %v", i, err)
		}
	}
}

func TestOfflineMessageVerifyFieldValidation(t *testing.T) {
	m := sampleOffline()
	if err := VerifyOfflineMessage(m); err == nil {
		t.Fatal("缺少签名应失败")
	}
	if err := VerifyOfflineMessage(nil); err == nil {
		t.Fatal("空消息应失败")
	}
}
