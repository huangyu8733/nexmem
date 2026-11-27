package group

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"image"
	"image/png"
	"strings"
	"testing"
)

// testLevelIcon 生成指定边长的合法 PNG，返回 base64.StdEncoding 编码结果。
func testLevelIcon(t *testing.T, size int) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("生成测试 PNG: %v", err)
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func TestValidateLevelConfig(t *testing.T) {
	validIcon := testLevelIcon(t, LevelIconSize)

	valid := LevelConfig{Enabled: true, Levels: []GroupLevel{{ID: "vip1", Name: "VIP1", IconB64: validIcon}}}
	if err := ValidateLevelConfig(valid); err != nil {
		t.Fatalf("合法配置应通过: %v", err)
	}
	if err := ValidateLevelConfig(LevelConfig{}); err != nil {
		t.Fatalf("空配置应通过: %v", err)
	}
	// 12 项是上限；图标为空允许；名称恰好 16 字允许。
	levels := make([]GroupLevel, 0, MaxLevels)
	for i := 0; i < MaxLevels; i++ {
		levels = append(levels, GroupLevel{
			ID: fmt.Sprintf("lv%d", i), Name: strings.Repeat("名", MaxLevelNameRunes), IconB64: "",
		})
	}
	if err := ValidateLevelConfig(LevelConfig{Enabled: true, Levels: levels}); err != nil {
		t.Fatalf("12 项/16 字/空图标应通过: %v", err)
	}

	tooMany := append(append([]GroupLevel{}, levels...), GroupLevel{ID: "lv12", Name: "额外"})
	if err := ValidateLevelConfig(LevelConfig{Levels: tooMany}); !errors.Is(err, ErrLevelConfigTooMany) ||
		!errors.Is(err, ErrLevelConfigInvalid) {
		t.Fatalf("13 项应返回超限错误, 实际 %v", err)
	}
	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "", Name: "x"}}}); !errors.Is(err, ErrLevelIDInvalid) {
		t.Fatalf("空 ID 应被拒绝, 实际 %v", err)
	}
	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "a,b", Name: "x"}}}); !errors.Is(err, ErrLevelIDInvalid) {
		t.Fatalf("含逗号 ID 应被拒绝, 实际 %v", err)
	}
	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "a\x01b", Name: "x"}}}); !errors.Is(err, ErrLevelIDInvalid) {
		t.Fatalf("含控制字符 ID 应被拒绝, 实际 %v", err)
	}
	dup := []GroupLevel{{ID: "same", Name: "a"}, {ID: "same", Name: "b"}}
	if err := ValidateLevelConfig(LevelConfig{Levels: dup}); !errors.Is(err, ErrLevelIDDuplicate) {
		t.Fatalf("重复 ID 应被拒绝, 实际 %v", err)
	}
	longName := strings.Repeat("名", MaxLevelNameRunes+1)
	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "x", Name: longName}}}); !errors.Is(err, ErrLevelNameTooLong) {
		t.Fatalf("17 字名称应被拒绝, 实际 %v", err)
	}

	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "x", Name: "x", IconB64: "!!!not-base64"}}}); !errors.Is(err, ErrLevelIconInvalid) {
		t.Fatalf("非法 base64 图标应被拒绝, 实际 %v", err)
	}
	notPNG := base64.StdEncoding.EncodeToString([]byte("hello world"))
	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "x", Name: "x", IconB64: notPNG}}}); !errors.Is(err, ErrLevelIconInvalid) {
		t.Fatalf("非 PNG 图标应被拒绝, 实际 %v", err)
	}
	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "x", Name: "x", IconB64: testLevelIcon(t, 32)}}}); !errors.Is(err, ErrLevelIconInvalid) {
		t.Fatalf("32x32 图标应被拒绝, 实际 %v", err)
	}
	raw, err := base64.StdEncoding.DecodeString(validIcon)
	if err != nil {
		t.Fatal(err)
	}
	oversized := base64.StdEncoding.EncodeToString(append(raw, make([]byte, MaxLevelIconBytes+1)...))
	if err := ValidateLevelConfig(LevelConfig{Levels: []GroupLevel{{ID: "x", Name: "x", IconB64: oversized}}}); !errors.Is(err, ErrLevelIconTooLarge) {
		t.Fatalf("超过 16 KiB 图标应被拒绝, 实际 %v", err)
	}
}

func TestLevelAndMemberProfileControlFrames(t *testing.T) {
	cfg := LevelConfig{Enabled: true, Levels: []GroupLevel{
		{ID: "vip1", Name: "贵宾", IconB64: testLevelIcon(t, LevelIconSize)},
	}}
	frame, err := EncodeLevelsNotice(cfg)
	if err != nil {
		t.Fatalf("编码等级帧: %v", err)
	}
	if !IsControlFrame([]byte(frame)) {
		t.Fatal("等级帧应属于控制帧")
	}
	got, ok := ParseLevelsNotice([]byte(frame))
	if !ok || got.Enabled != cfg.Enabled || len(got.Levels) != 1 || got.Levels[0].ID != "vip1" {
		t.Fatalf("等级帧解析失败: %+v / %v", got, ok)
	}
	if _, ok := ParseLevelsNotice([]byte("普通群消息")); ok {
		t.Fatal("普通消息被误判为等级帧")
	}
	if _, ok := ParseLevelsNotice([]byte(levelsNoticePrefix + "!!!not-base64")); ok {
		t.Fatal("非法 base64 等级帧被接受")
	}
	// 篡改后的配置在解析时再次校验，超限配置不被接受。
	badFrame := levelsNoticePrefix + base64.RawURLEncoding.EncodeToString(
		[]byte(`{"enabled":true,"levels":[{"id":"a,b","name":"x","icon_b64":""}]}`))
	if _, ok := ParseLevelsNotice([]byte(badFrame)); ok {
		t.Fatal("非法等级配置帧应被丢弃")
	}
	if _, err := EncodeLevelsNotice(LevelConfig{Levels: []GroupLevel{{ID: "a,b", Name: "x"}}}); !errors.Is(err, ErrLevelConfigInvalid) {
		t.Fatalf("非法配置编码应失败, 实际 %v", err)
	}

	profile := MemberProfile{Account: strings.Repeat("ab", 32), Nickname: "队长", LevelID: "vip1"}
	pframe, err := EncodeMemberProfileNotice(profile)
	if err != nil {
		t.Fatalf("编码成员资料帧: %v", err)
	}
	if !IsControlFrame([]byte(pframe)) {
		t.Fatal("成员资料帧应属于控制帧")
	}
	pgot, ok := ParseMemberProfileNotice([]byte(pframe))
	if !ok || pgot != profile {
		t.Fatalf("成员资料帧解析失败: %+v / %v", pgot, ok)
	}
	// 空昵称/等级 ID 表示清除，仍须能编解码。
	if frame, err := EncodeMemberProfileNotice(MemberProfile{Account: profile.Account}); err != nil {
		t.Fatalf("空资料帧编码失败: %v", err)
	} else if got, ok := ParseMemberProfileNotice([]byte(frame)); !ok || got.Nickname != "" || got.LevelID != "" {
		t.Fatalf("空资料帧解析失败: %+v / %v", got, ok)
	}
	if _, ok := ParseMemberProfileNotice([]byte("普通群消息")); ok {
		t.Fatal("普通消息被误判为成员资料帧")
	}
	if _, ok := ParseMemberProfileNotice([]byte(memberProfileNoticePrefix +
		base64.RawURLEncoding.EncodeToString([]byte(`{"nickname":"x","level_id":""}`)))); ok {
		t.Fatal("缺少 account 的资料帧应被丢弃")
	}
	if _, err := EncodeMemberProfileNotice(MemberProfile{
		Account: profile.Account, Nickname: strings.Repeat("长", MaxNicknameRunes+1),
	}); !errors.Is(err, ErrNicknameTooLong) {
		t.Fatalf("超长昵称编码应失败, 实际 %v", err)
	}
}
