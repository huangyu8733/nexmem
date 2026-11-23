package settingsync

import (
	"errors"
	"strings"
	"testing"
)

func TestProduceConsumeRoundTrip(t *testing.T) {
	entries := []Entry{
		{Key: "ui.theme_mode", Value: "dark"},
		{Key: "relay.addrs", Value: "/ip4/1.2.3.4/tcp/4001"},
		{Key: "a", Value: ""},
	}
	text, err := Produce(entries)
	if err != nil {
		t.Fatalf("Produce: %v", err)
	}
	if !strings.HasPrefix(text, Prefix) {
		t.Fatalf("缺少前缀: %s", text)
	}
	got, err := Consume(text)
	if err != nil {
		t.Fatalf("Consume: %v", err)
	}
	if len(got) != len(entries) {
		t.Fatalf("条目数 = %d，期望 %d", len(got), len(entries))
	}
	want := map[string]string{}
	for _, e := range entries {
		want[e.Key] = e.Value
	}
	for _, e := range got {
		if want[e.Key] != e.Value {
			t.Fatalf("%s = %q，期望 %q", e.Key, e.Value, want[e.Key])
		}
	}
}

func TestConsumeRejectsTamper(t *testing.T) {
	text, _ := Produce([]Entry{{Key: "ui.theme", Value: "dark"}})
	// 改动 base64 载荷的第 5 个字符，使解码内容变化。
	raw := strings.TrimPrefix(text, Prefix)
	alt := 'A'
	if raw[5] == 'A' {
		alt = 'B'
	}
	tampered := Prefix + raw[:5] + string(alt) + raw[6:]
	_, err := Consume(tampered)
	if err == nil {
		t.Fatal("篡改快照应被拒绝")
	}
	if !errors.Is(err, ErrChecksum) && !errors.Is(err, ErrFormat) && !errors.Is(err, ErrVersion) {
		t.Fatalf("err=%v，期望校验/格式类错误", err)
	}
}

func TestConsumeRejectsBad(t *testing.T) {
	cases := []string{"", "hello", Prefix, Prefix + "!!!invalid!!!"}
	for _, c := range cases {
		if _, err := Consume(c); err == nil {
			t.Fatalf("Consume(%q) 应拒绝", c)
		}
	}
}

func TestProduceRejectsInvalid(t *testing.T) {
	if _, err := Produce([]Entry{{Key: "Bad Key", Value: "x"}}); !errors.Is(err, ErrFormat) {
		t.Fatalf("非法键应拒绝: %v", err)
	}
	if _, err := Produce([]Entry{{Key: "a", Value: "x"}, {Key: "a", Value: "y"}}); !errors.Is(err, ErrFormat) {
		t.Fatalf("重复键应拒绝: %v", err)
	}
}
