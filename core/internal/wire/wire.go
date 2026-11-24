// Package wire 定义 P2P 流上的帧格式、签名与协议 ID。
//
// 帧格式：4 字节大端长度 + protobuf 序列化字节，单帧上限 1 MiB。
// 每帧都附带发送方设备密钥的签名，接收方用连接对端的 libp2p 公钥验签，
// 从而在 Noise 信道之外再提供一层应用层完整性校验。
package wire

import (
	"encoding/binary"
	"fmt"
	"io"

	libp2pcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/protocol"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

const (
	// Version 是当前帧协议版本。
	Version uint32 = 1
	// MaxFrameSize 限制单帧大小，防止对端构造超大帧耗尽内存。
	MaxFrameSize = 1 << 20
)

// 流协议 ID。
const (
	PIDDM   protocol.ID = "/nexmem/dm/1.0.0"
	PIDFile protocol.ID = "/nexmem/dm-file/1.0.0"
	PIDMeta protocol.ID = "/nexmem/group-meta/1.0.0"
	PIDRTC  protocol.ID = "/nexmem/rtc/1.0.0"
	// PIDFs 是 P2P 文件夹共享协议（清单 + 加密分片请求）。
	PIDFs protocol.ID = "/nexmem/fs/1.0.0"
)

// frameDomain 做域隔离，避免签名在其他协议中被复用。
const frameDomain = "nexmem/wire-frame/v1"

// WriteFrame 写入「4 字节大端长度 + protobuf」的帧。
func WriteFrame(w io.Writer, f *nexmemv1.Frame) error {
	if f == nil {
		return fmt.Errorf("帧为空")
	}
	payload, err := proto.Marshal(f)
	if err != nil {
		return fmt.Errorf("序列化帧: %w", err)
	}
	if len(payload) > MaxFrameSize {
		return fmt.Errorf("帧超长: %d > %d", len(payload), MaxFrameSize)
	}
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return fmt.Errorf("写入帧长度: %w", err)
	}
	if _, err := w.Write(payload); err != nil {
		return fmt.Errorf("写入帧内容: %w", err)
	}
	return nil
}

// ReadFrame 读取一帧。
func ReadFrame(r io.Reader) (*nexmemv1.Frame, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n > MaxFrameSize {
		return nil, fmt.Errorf("帧超长: %d > %d", n, MaxFrameSize)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	f := &nexmemv1.Frame{}
	if err := proto.Unmarshal(buf, f); err != nil {
		return nil, fmt.Errorf("解析帧: %w", err)
	}
	return f, nil
}

// SignFrame 用发送方设备私钥为帧签名，写入 f.Sig。
func SignFrame(priv libp2pcrypto.PrivKey, f *nexmemv1.Frame) error {
	if priv == nil {
		return fmt.Errorf("设备私钥为空")
	}
	if f == nil {
		return fmt.Errorf("帧为空")
	}
	sig, err := priv.Sign(canonical(f))
	if err != nil {
		return fmt.Errorf("帧签名: %w", err)
	}
	f.Sig = sig
	return nil
}

// VerifyFrame 用对端公钥校验帧签名。
func VerifyFrame(pub libp2pcrypto.PubKey, f *nexmemv1.Frame) error {
	if pub == nil {
		return fmt.Errorf("对端公钥为空")
	}
	if f == nil {
		return fmt.Errorf("帧为空")
	}
	if len(f.Sig) == 0 {
		return fmt.Errorf("帧缺少签名")
	}
	ok, err := pub.Verify(canonical(f), f.Sig)
	if err != nil {
		return fmt.Errorf("帧验签: %w", err)
	}
	if !ok {
		return fmt.Errorf("帧签名校验失败")
	}
	return nil
}

// canonical 生成参与签名的确定性字节：域名 + 版本 + 类型 + 载荷长度前缀 + 载荷。
func canonical(f *nexmemv1.Frame) []byte {
	out := make([]byte, 0, len(frameDomain)+8+len(f.Payload))
	var tmp [8]byte
	binary.BigEndian.PutUint32(tmp[0:4], uint32(len(frameDomain)))
	out = append(out, tmp[0:4]...)
	out = append(out, frameDomain...)
	binary.BigEndian.PutUint32(tmp[0:4], f.Version)
	out = append(out, tmp[0:4]...)
	binary.BigEndian.PutUint32(tmp[0:4], uint32(f.Type))
	out = append(out, tmp[0:4]...)
	binary.BigEndian.PutUint32(tmp[0:4], uint32(len(f.Payload)))
	out = append(out, tmp[0:4]...)
	out = append(out, f.Payload...)
	return out
}
