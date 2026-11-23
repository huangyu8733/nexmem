package expiry

import (
	"errors"
	"testing"
	"time"
)

func TestValidate(t *testing.T) {
	cases := []struct {
		hours   uint32
		wantErr bool
	}{
		{0, false},   // 永不过期
		{1, false},   // 下界
		{168, false}, // 上界 7 天
		{2, false},   // 中间值
		{169, true},  // 越界
		{1000, true},
	}
	for _, c := range cases {
		err := Validate(c.hours)
		if c.wantErr && !errors.Is(err, ErrTTLOutOfRange) {
			t.Fatalf("Validate(%d) 期望越界错误，实际 %v", c.hours, err)
		}
		if !c.wantErr && err != nil {
			t.Fatalf("Validate(%d) 不应报错，实际 %v", c.hours, err)
		}
	}
}

func TestExpiresAt(t *testing.T) {
	sentAt := int64(1_700_000_000_000)
	if got := ExpiresAt(sentAt, 0); got != 0 {
		t.Fatalf("TTL=0 应返回 0，实际 %d", got)
	}
	want := sentAt + 24*int64(time.Hour/time.Millisecond)
	if got := ExpiresAt(sentAt, 24); got != want {
		t.Fatalf("TTL=24h 销毁时间 = %d，期望 %d", got, want)
	}
	want = sentAt + 168*int64(time.Hour/time.Millisecond)
	if got := ExpiresAt(sentAt, 168); got != want {
		t.Fatalf("TTL=168h 销毁时间 = %d，期望 %d", got, want)
	}
}
