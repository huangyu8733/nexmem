package readsync

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"

	"github.com/nexmem/core/internal/blob"
)

func testAccount(t *testing.T) (ed25519.PrivateKey, []byte) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return priv, pub
}

// TestProduceConsumeRoundTrip 覆盖水位签发/校验往返与账号签名器对接。
func TestProduceConsumeRoundTrip(t *testing.T) {
	priv, pub := testAccount(t)
	sign := func(data []byte) []byte { return ed25519.Sign(priv, data) }
	raw, err := Produce(sign, pub, "dm:alice|bob", 12345, 1700000000000, "dev-A")
	if err != nil {
		t.Fatalf("签发水位: %v", err)
	}
	w, err := Consume(raw, pub)
	if err != nil {
		t.Fatalf("校验水位: %v", err)
	}
	if w.ConversationID != "dm:alice|bob" || w.UpTo != 12345 || w.DeviceID != "dev-A" {
		t.Fatalf("解析结果不符: %+v", w)
	}
	// 同一账号签名可验，其他账号公钥应拒绝。
	_, otherPub := testAccount(t)
	if _, err := Consume(raw, otherPub); err == nil {
		t.Fatal("其他账号公钥不应验过")
	}
}

// TestConsumeRejectsTamper 覆盖篡改签名/字段被拒绝。
func TestConsumeRejectsTamper(t *testing.T) {
	priv, pub := testAccount(t)
	sign := func(data []byte) []byte { return ed25519.Sign(priv, data) }
	raw, err := Produce(sign, pub, "dm:alice|bob", 100, 1, "dev-A")
	if err != nil {
		t.Fatal(err)
	}
	// 篡改字节（签名或字段任一处），均应被拒绝。
	for i := range raw {
		bad := append([]byte(nil), raw...)
		bad[i] ^= 0xff
		if i > 6 {
			break // 抽样若干字节即可
		}
		if _, err := Consume(bad, pub); err == nil {
			t.Fatalf("第 %d 字节被篡改应被拒绝", i)
		}
	}
}

// TestMaxByConversation 覆盖多设备水位取最大值、确定性排序。
func TestMaxByConversation(t *testing.T) {
	in := []Watermark{
		{ConversationID: "b", UpTo: 10, UpdatedAt: 1},
		{ConversationID: "a", UpTo: 5, UpdatedAt: 1},
		{ConversationID: "b", UpTo: 8, UpdatedAt: 9},
		{ConversationID: "b", UpTo: 10, UpdatedAt: 2},
		{ConversationID: "a", UpTo: 3, UpdatedAt: 9},
	}
	got := MaxByConversation(in)
	if len(got) != 2 {
		t.Fatalf("期望 2 条会话，实际 %d", len(got))
	}
	if got[0].ConversationID != "a" || got[0].UpTo != 5 {
		t.Fatalf("a 会话水位错误: %+v", got[0])
	}
	if got[1].ConversationID != "b" || got[1].UpTo != 10 || got[1].UpdatedAt != 2 {
		t.Fatalf("b 会话应取 upTo 最大、updatedAt 较新: %+v", got[1])
	}
}

// TestObjectKeyRoundTrip 覆盖水位对象键编解码。
func TestObjectKeyRoundTrip(t *testing.T) {
	prefix := blob.InboxPrefix([]byte("account-pub-32-bytes-long-xxxx"))
	conv := "dm:alice|bob/特殊 字符"
	key := ObjectKey(prefix, conv)
	got, ok := ParseObjectKey(prefix, key)
	if !ok || got != conv {
		t.Fatalf("对象键往返失败: got=%q ok=%v", got, ok)
	}
	if _, ok := ParseObjectKey(prefix, "im_offline/other/inbox/file.msg"); ok {
		t.Fatal("非水位对象不应被解析")
	}
}

// memStore 是内存对象存储替身，实现 List/Get（与 dm.OfflineStore 同构）。
type memStore struct {
	objects map[string][]byte
}

func (m *memStore) Put(_ context.Context, key string, data []byte, _ string) (blob.ObjectInfo, error) {
	m.objects[key] = append([]byte(nil), data...)
	return blob.ObjectInfo{Key: key, Size: int64(len(data))}, nil
}

func (m *memStore) List(_ context.Context, prefix string) ([]blob.ObjectInfo, error) {
	out := make([]blob.ObjectInfo, 0, len(m.objects))
	for k, v := range m.objects {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			out = append(out, blob.ObjectInfo{Key: k, Size: int64(len(v))})
		}
	}
	return out, nil
}

func (m *memStore) Get(_ context.Context, key string) ([]byte, blob.ObjectInfo, error) {
	data, ok := m.objects[key]
	if !ok {
		return nil, blob.ObjectInfo{}, blob.ErrNotFound
	}
	return append([]byte(nil), data...), blob.ObjectInfo{Key: key, Size: int64(len(data))}, nil
}

// TestListWatermarks 覆盖从共用桶拉取多设备水位、跳过伪造对象、按会话取最大值。
func TestListWatermarks(t *testing.T) {
	ctx := context.Background()
	priv, pub := testAccount(t)
	sign := func(data []byte) []byte { return ed25519.Sign(priv, data) }
	prefix := blob.InboxPrefix(pub)
	store := &memStore{objects: make(map[string][]byte)}

	raw1, _ := Produce(sign, pub, "dm:a|b", 100, 10, "dev-1")
	_, _ = store.Put(ctx, ObjectKey(prefix, "dm:a|b")+"dev1", raw1, ObjectContentType)
	raw2, _ := Produce(sign, pub, "dm:a|b", 200, 11, "dev-2")
	_, _ = store.Put(ctx, ObjectKey(prefix, "dm:a|b")+"dev2", raw2, ObjectContentType)
	// 伪造对象：其他账号签名，应被 ListWatermarks 跳过。
	evilPriv, evilPub := testAccount(t)
	badSign := func(data []byte) []byte { return ed25519.Sign(evilPriv, data) }
	badRaw, _ := Produce(badSign, evilPub, "dm:a|b", 999, 12, "evil")
	_, _ = store.Put(ctx, ObjectKey(prefix, "dm:a|b")+"evil", badRaw, ObjectContentType)

	ws, err := ListWatermarks(ctx, store, prefix, pub)
	if err != nil {
		t.Fatalf("拉取水位: %v", err)
	}
	max := MaxByConversation(ws)
	if len(max) != 1 || max[0].UpTo != 200 {
		t.Fatalf("应只保留本账号最高水位 200，实际 %+v", max)
	}
}
