package group

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
)

// TestRecallNoticeRoundTrip 覆盖群撤回控制帧编码/解析（P6-14）。
func TestRecallNoticeRoundTrip(t *testing.T) {
	uuid := "00112233445566778899aabbccddeeff"
	frame, err := EncodeRecallNotice(uuid)
	if err != nil {
		t.Fatalf("编码撤回控制帧: %v", err)
	}
	got, ok := ParseRecallNotice([]byte(frame))
	if !ok || got != uuid {
		t.Fatalf("解析撤回控制帧失败: ok=%v uuid=%q", ok, got)
	}

	// 普通聊天文本与非法目标标识都不应被识别为撤回。
	if _, ok := ParseRecallNotice([]byte("你好，这是一条普通群消息")); ok {
		t.Fatal("普通文本被误判为撤回帧")
	}
	if _, ok := ParseRecallNotice([]byte(recallNoticePrefix + "not-hex")); ok {
		t.Fatal("非法目标标识被接受")
	}
	if _, err := EncodeRecallNotice("zz"); err == nil {
		t.Fatal("非法目标标识编码未报错")
	}
	if frame, err := EncodeRecallNotice("AABBCCDDEEFF00112233445566778899"); err != nil {
		t.Fatalf("大写十六进制应被接受: %v", err)
	} else if got, _ := ParseRecallNotice([]byte(frame)); got != "aabbccddeeff00112233445566778899" {
		t.Fatalf("大写标识未归一化: %q", got)
	}
	if _, err := hex.DecodeString(uuid); err != nil {
		t.Fatalf("测试向量非法: %v", err)
	}
}

// TestAnnouncementNoticeRoundTrip 覆盖群公告控制帧编码/解析与长度边界（P6-26）。
func TestAnnouncementNoticeRoundTrip(t *testing.T) {
	text := "本周六上午十点全员会议，请准时参加。"
	frame, err := EncodeAnnouncementNotice(text)
	if err != nil {
		t.Fatalf("编码公告控制帧: %v", err)
	}
	if !IsControlFrame([]byte(frame)) {
		t.Fatal("公告帧应属于控制帧")
	}
	got, ok := ParseAnnouncementNotice([]byte(frame))
	if !ok || got != text {
		t.Fatalf("解析公告控制帧失败: ok=%v text=%q", ok, got)
	}

	// 空串表示清除公告，仍可编码与解析。
	if frame, err := EncodeAnnouncementNotice(""); err != nil {
		t.Fatalf("空公告应被接受: %v", err)
	} else if got, ok := ParseAnnouncementNotice([]byte(frame)); !ok || got != "" {
		t.Fatalf("空公告解析失败: ok=%v text=%q", ok, got)
	}

	// 512 个字符为上限，513 个字符必须拒绝。
	exact := strings.Repeat("太", MaxAnnouncementRunes)
	if _, err := EncodeAnnouncementNotice(exact); err != nil {
		t.Fatalf("512 字应被接受: %v", err)
	}
	tooLong := strings.Repeat("长", MaxAnnouncementRunes+1)
	if _, err := EncodeAnnouncementNotice(tooLong); !errors.Is(err, ErrAnnouncementTooLong) {
		t.Fatalf("513 字应返回超限错误, 实际 %v", err)
	}
	if _, ok := ParseAnnouncementNotice([]byte(announcementNoticePrefix +
		base64.RawURLEncoding.EncodeToString([]byte(tooLong)))); ok {
		t.Fatal("超限公告帧应被丢弃")
	}

	// 普通文本与非法 base64 不应被识别为公告帧。
	if _, ok := ParseAnnouncementNotice([]byte("你好，这是一条普通群消息")); ok {
		t.Fatal("普通文本被误判为公告帧")
	}
	if _, ok := ParseAnnouncementNotice([]byte(announcementNoticePrefix + "!!!not-base64")); ok {
		t.Fatal("非法 base64 被接受")
	}
}
