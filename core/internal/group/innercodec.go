package group

// 群 InnerMessage 结构化正文的编解码（七-1 @成员 / 七-2 消息编辑）。
//
// 历史群文本消息的 Plaintext 是原始 UTF-8 文本，coreapp 落库时用
// InnerMessage{Text: plaintext} 重新包装。新增的 mentions / edited 等字段
// 需要把完整 InnerMessage 序列化后塞进 Plaintext，接收端才能原样还原。
// 为与历史纯文本与控制帧（\x01 前缀）区分，结构化正文统一加 \x02 前缀。

import (
	"strings"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

// innerMessagePrefix 标记 Plaintext 为序列化 InnerMessage（非纯文本）。
const innerMessagePrefix = "\x02nexmem:inner:"

// EncodeInnerPlaintext 把 InnerMessage 编码为可放进群广播 Plaintext 的字节串；
// 非结构化消息（无 mentions、未编辑）返回原文本字节，保持历史兼容。
func EncodeInnerPlaintext(inner *nexmemv1.InnerMessage, fallbackText string) ([]byte, error) {
	if inner == nil || (len(inner.GetMentions()) == 0 && !inner.GetEdited() && inner.GetReplyTo() == "") {
		return []byte(fallbackText), nil
	}
	payload, err := proto.Marshal(inner)
	if err != nil {
		return nil, err
	}
	return []byte(innerMessagePrefix + string(payload)), nil
}

// DecodeInnerPlaintext 尝试把群 Plaintext 解为完整 InnerMessage。
// 返回 (inner, true) 表示是结构化正文；返回 (nil, false) 表示历史纯文本，
// 调用方应回退 InnerMessage{Text: string(plaintext)}。
func DecodeInnerPlaintext(plaintext []byte) (*nexmemv1.InnerMessage, bool) {
	if !strings.HasPrefix(string(plaintext), innerMessagePrefix) {
		return nil, false
	}
	payload := plaintext[len(innerMessagePrefix):]
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(payload, inner); err != nil {
		return nil, false
	}
	return inner, true
}
