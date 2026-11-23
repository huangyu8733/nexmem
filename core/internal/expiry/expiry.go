// Package expiry 提供定时消息（阅后即焚）的 TTL 校验与本机销毁时间计算。
//
// TTL 只描述"消息从发出起存活多久"，随加密正文 InnerMessage.ttl_hours 到达双方，
// 双方各自按 sent_at + ttl 计算 expires_at 写入本地库，由 coreapp 的 sweeper
// 到点物理删除并发出 message.expired 事件。TTL 不上行索引服务器、不写 S3 元数据。
package expiry

import (
	"errors"
	"fmt"
	"time"
)

const (
	// MinHours / MaxHours 是契约允许的定时消息存活范围（1 小时～7 天）。
	MinHours = uint32(1)
	MaxHours = uint32(168)
)

// ErrTTLOutOfRange 表示 TTL 不在允许范围（0 表示不使用定时消息，不视为错误）。
var ErrTTLOutOfRange = errors.New("定时消息 TTL 超出范围")

// Validate 校验 TTL 小时数：0 表示永不过期（合法）；1～168 合法；其余报错。
func Validate(hours uint32) error {
	if hours == 0 || (hours >= MinHours && hours <= MaxHours) {
		return nil
	}
	return fmt.Errorf("%w: %d 不在 %d～%d 之间", ErrTTLOutOfRange, hours, MinHours, MaxHours)
}

// ExpiresAt 根据发送时间与 TTL 小时数计算本机销毁时间（Unix 毫秒）。
// ttlHours=0 返回 0（永不过期）。sentAt 为 Unix 毫秒。
func ExpiresAt(sentAt int64, ttlHours uint32) int64 {
	if ttlHours == 0 {
		return 0
	}
	return sentAt + int64(ttlHours)*int64(time.Hour/time.Millisecond)
}
