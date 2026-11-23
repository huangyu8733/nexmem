package spike

import (
	"encoding/binary"
	"fmt"
	"io"

	"github.com/libp2p/go-libp2p/core/protocol"
)

// PID 是 P0 阶段用于连通性验证的回显协议。
const PID protocol.ID = "/nexmem/spike/1.0.0"

// MaxFrameSize 限制单帧大小，防止对端构造超大帧耗尽内存。
const MaxFrameSize = 1 << 20

// Write 写入「4 字节大端长度 + 载荷」的帧。
func Write(w io.Writer, payload []byte) error {
	if len(payload) > MaxFrameSize {
		return fmt.Errorf("帧超长: %d > %d", len(payload), MaxFrameSize)
	}
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

// Read 读取一帧。
func Read(r io.Reader, max uint32) ([]byte, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n > max {
		return nil, fmt.Errorf("帧超长: %d > %d", n, max)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}
