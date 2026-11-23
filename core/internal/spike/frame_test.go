package spike

import (
	"bytes"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	want := []byte("ping-1760000000000")

	if err := Write(&buf, want); err != nil {
		t.Fatalf("写入失败: %v", err)
	}
	got, err := Read(&buf, MaxFrameSize)
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("回显不一致: got=%q want=%q", got, want)
	}
}

func TestReadRejectsOversize(t *testing.T) {
	var buf bytes.Buffer
	// 2 MiB，超过 MaxFrameSize
	buf.Write([]byte{0x00, 0x20, 0x00, 0x00})

	if _, err := Read(&buf, MaxFrameSize); err == nil {
		t.Fatal("超长帧应返回错误")
	}
}

func TestWriteRejectsOversize(t *testing.T) {
	var buf bytes.Buffer
	big := make([]byte, MaxFrameSize+1)

	if err := Write(&buf, big); err == nil {
		t.Fatal("超长帧应返回错误")
	}
}

func TestReadTruncated(t *testing.T) {
	var buf bytes.Buffer
	buf.Write([]byte{0x00, 0x00, 0x00, 0x08, 'a', 'b'})

	if _, err := Read(&buf, MaxFrameSize); err == nil {
		t.Fatal("帧不完整应返回错误")
	}
}
