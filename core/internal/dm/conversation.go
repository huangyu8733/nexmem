package dm

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// ConversationID 生成单聊会话 ID：对两端账号公钥按字典序排序后拼接，
// 保证双方算出的 ID 完全一致。
func ConversationID(a, b []byte) string {
	first, second := a, b
	if bytes.Compare(a, b) > 0 {
		first, second = b, a
	}
	return "dm:" + hex.EncodeToString(first) + "|" + hex.EncodeToString(second)
}

// newUUIDv7 生成基于毫秒时间戳的 UUIDv7 字符串。
// 时间戳严格递增时，其字符串序与时间序一致，可直接作为消息主键与排序键。
func newUUIDv7(tsMS int64) (string, error) {
	var rnd [10]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return "", fmt.Errorf("生成消息 UUID: %w", err)
	}
	// 末尾 2 字节不参与版本/变体位，混入时间戳哈希，降低同毫秒碰撞概率。
	sum := sha256.Sum256([]byte(fmt.Sprintf("%d/%x", tsMS, rnd)))
	rnd[8] ^= sum[0]
	rnd[9] ^= sum[1]

	var b [16]byte
	ts := uint64(tsMS)
	b[0] = byte(ts >> 40)
	b[1] = byte(ts >> 32)
	b[2] = byte(ts >> 24)
	b[3] = byte(ts >> 16)
	b[4] = byte(ts >> 8)
	b[5] = byte(ts)
	b[6] = 0x70 | (rnd[0] & 0x0f)
	b[7] = rnd[1]
	b[8] = 0x80 | (rnd[2] & 0x3f)
	copy(b[9:], rnd[3:10])

	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

func validAccountPub(pub []byte) bool {
	return len(pub) == ed25519.PublicKeySize
}
