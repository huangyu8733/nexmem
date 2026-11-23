package group

import (
	"testing"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

func TestInnerCodecRoundTrip(t *testing.T) {
	inner := &nexmemv1.InnerMessage{
		Text:     "@alice 看这个",
		Mentions: []string{"alice-account-pub"},
		Edited:   true,
		EditedAt: 1730000000000,
	}
	plain, err := EncodeInnerPlaintext(inner, "")
	if err != nil {
		t.Fatalf("编码失败: %v", err)
	}
	got, ok := DecodeInnerPlaintext(plain)
	if !ok {
		t.Fatalf("未能识别结构化正文")
	}
	if got.GetText() != inner.GetText() ||
		len(got.GetMentions()) != 1 || got.GetMentions()[0] != "alice-account-pub" ||
		!got.GetEdited() || got.GetEditedAt() != inner.GetEditedAt() {
		t.Fatalf("往返不一致: %+v", got)
	}
}

func TestInnerCodecPlainTextFallback(t *testing.T) {
	// 无 mentions / 未编辑时返回原文本，且不被误判为结构化正文。
	plain, err := EncodeInnerPlaintext(&nexmemv1.InnerMessage{Text: "hello"}, "hello")
	if err != nil {
		t.Fatalf("编码失败: %v", err)
	}
	if string(plain) != "hello" {
		t.Fatalf("纯文本应原样返回, 得到 %q", string(plain))
	}
	if _, ok := DecodeInnerPlaintext(plain); ok {
		t.Fatalf("纯文本不应被识别为结构化正文")
	}
	// 历史纯文本同样回退。
	if _, ok := DecodeInnerPlaintext([]byte("历史消息")); ok {
		t.Fatalf("历史纯文本不应被识别为结构化正文")
	}
}
