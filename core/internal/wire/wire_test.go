package wire

import (
	"bytes"
	"crypto/rand"
	"testing"

	libp2pcrypto "github.com/libp2p/go-libp2p/core/crypto"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

func newFrame(t *testing.T) *nexmemv1.Frame {
	t.Helper()
	priv, _, err := libp2pcrypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		t.Fatalf("生成测试密钥失败: %v", err)
	}
	f := &nexmemv1.Frame{
		Version: Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_MSG,
		Payload: []byte("hello-nexmem"),
	}
	if err := SignFrame(priv, f); err != nil {
		t.Fatalf("签名失败: %v", err)
	}
	return f
}

func TestFrameRoundTrip(t *testing.T) {
	f := newFrame(t)
	var buf bytes.Buffer
	if err := WriteFrame(&buf, f); err != nil {
		t.Fatalf("写帧失败: %v", err)
	}
	got, err := ReadFrame(&buf)
	if err != nil {
		t.Fatalf("读帧失败: %v", err)
	}
	if got.Version != f.Version || got.Type != f.Type {
		t.Fatalf("帧头不一致: %+v", got)
	}
	if !bytes.Equal(got.Payload, f.Payload) || !bytes.Equal(got.Sig, f.Sig) {
		t.Fatalf("帧载荷或签名不一致")
	}
}

func TestFrameTooLarge(t *testing.T) {
	f := &nexmemv1.Frame{Version: Version, Payload: make([]byte, MaxFrameSize+1)}
	var buf bytes.Buffer
	if err := WriteFrame(&buf, f); err == nil {
		t.Fatalf("超长帧应写入失败")
	}
	// 手工构造超长长度前缀，读侧也必须拒绝。
	hdr := []byte{0x00, 0x10, 0x00, 0x01}
	if _, err := ReadFrame(bytes.NewReader(hdr)); err == nil {
		t.Fatalf("超长帧应读取失败")
	}
}

func TestSignAndVerify(t *testing.T) {
	priv, pub, err := libp2pcrypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f := &nexmemv1.Frame{
		Version: Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_ACK,
		Payload: []byte("ack"),
	}
	if err := SignFrame(priv, f); err != nil {
		t.Fatal(err)
	}
	if err := VerifyFrame(pub, f); err != nil {
		t.Fatalf("正常帧验签失败: %v", err)
	}

	tampered := &nexmemv1.Frame{Version: f.Version, Type: f.Type, Payload: []byte("ack2"), Sig: f.Sig}
	if err := VerifyFrame(pub, tampered); err == nil {
		t.Fatalf("篡改载荷后验签应失败")
	}
	// 类型变化也必须导致验签失败（域隔离覆盖帧头）。
	retyped := &nexmemv1.Frame{Version: f.Version, Type: nexmemv1.FrameType_FRAME_TYPE_MSG, Payload: f.Payload, Sig: f.Sig}
	if err := VerifyFrame(pub, retyped); err == nil {
		t.Fatalf("篡改帧类型后验签应失败")
	}

	_, otherPub, err := libp2pcrypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyFrame(otherPub, f); err == nil {
		t.Fatalf("其他公钥验签应失败")
	}
}
