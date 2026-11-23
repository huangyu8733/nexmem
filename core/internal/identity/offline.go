package identity

// 离线消息签名（P3-06）。
//
// OfflineMessage 会被上传到对象存储，接收方与索引服务都无法依赖传输信道；
// 发送方用账号 ed25519 私钥对除 sender_sig 外的全部字段签名，
// 接收方用 sender_account 验签，保证密文、票据归属与元数据不可被调包。

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"errors"
	"fmt"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

const offlineMessageDomain = "nexmem/offline-message/v1"

// SignOfflineMessage 写入发送方账号并把签名写入回 m.SenderSig。
func (a *Account) SignOfflineMessage(m *nexmemv1.OfflineMessage) error {
	if m == nil {
		return errors.New("离线消息为空")
	}
	m.SenderAccount = a.Pub()
	m.SenderSig = ed25519.Sign(a.priv, canonicalOfflineMessage(m))
	return nil
}

// VerifyOfflineMessage 校验离线消息的发送方签名与基本字段。
func VerifyOfflineMessage(m *nexmemv1.OfflineMessage) error {
	if m == nil {
		return errors.New("离线消息为空")
	}
	if len(m.SenderAccount) != ed25519.PublicKeySize {
		return fmt.Errorf("发送方账号公钥长度错误: %d", len(m.SenderAccount))
	}
	if len(m.ReceiverAccount) != ed25519.PublicKeySize {
		return fmt.Errorf("接收方账号公钥长度错误: %d", len(m.ReceiverAccount))
	}
	if len(m.SenderSig) != ed25519.SignatureSize {
		return fmt.Errorf("签名长度错误: %d", len(m.SenderSig))
	}
	if !ed25519.Verify(ed25519.PublicKey(m.SenderAccount), canonicalOfflineMessage(m), m.SenderSig) {
		return ErrInvalidSignature
	}
	return nil
}

// canonicalOfflineMessage 生成字段 1～11 的确定性编码，sender_sig 不参与签名。
func canonicalOfflineMessage(m *nexmemv1.OfflineMessage) []byte {
	var buf bytes.Buffer
	writeChunk(&buf, []byte(offlineMessageDomain))
	writeChunk(&buf, []byte(m.MsgUuid))
	writeInt64(&buf, m.Timestamp)
	writeChunk(&buf, m.SenderAccount)
	writeChunk(&buf, m.ReceiverAccount)
	writeChunk(&buf, m.ConversationId)
	writeChunk(&buf, m.EncryptedKey)
	writeChunk(&buf, m.Nonce)
	writeChunk(&buf, m.Ciphertext)
	writeUint32(&buf, m.KeyAlg)
	writeUint32(&buf, uint32(m.ContentType))
	writeUint32(&buf, m.TtlHours)
	return buf.Bytes()
}

func writeUint32(w *bytes.Buffer, v uint32) {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	w.Write(b[:])
}
