package dm

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"os"

	nexmemv1 "github.com/nexmem/core/api/v1"
)

// 断点续传（P2-05）：接收端把已解密校验通过的分片保留在 <目标>.part，
// 并在同名 .part.meta 中记录与文件消息绑定的元数据。重传时据此上报续传起点，
// 发送端从对端确认的分片继续发送，不再重传已完成分片。
const (
	filePartSuffix = ".part"
	fileMetaSuffix = ".part.meta"
)

// partialFileMeta 记录接收端半成品文件的归属与校验参数，用于判定能否续传。
type partialFileMeta struct {
	MsgUUID     string `json:"msg_uuid"`
	ChunkSize   int    `json:"chunk_size"`
	TotalChunks int    `json:"total_chunks"`
	Size        int64  `json:"size"`
	Sha256      string `json:"sha256"`
}

func newPartialFileMeta(meta *nexmemv1.FileMeta, sum []byte) partialFileMeta {
	return partialFileMeta{
		MsgUUID:     meta.GetMsgUuid(),
		ChunkSize:   int(meta.GetChunkSize()),
		TotalChunks: int(meta.GetTotalChunks()),
		Size:        int64(meta.GetSize()),
		Sha256:      hex.EncodeToString(sum),
	}
}

// matches 判断半成品文件是否属于当前文件消息，参数顺序或分片大小变化都不可续传。
func (m partialFileMeta) matches(meta *nexmemv1.FileMeta, sum []byte) bool {
	if m.MsgUUID != meta.GetMsgUuid() ||
		m.ChunkSize != int(meta.GetChunkSize()) ||
		m.TotalChunks != int(meta.GetTotalChunks()) ||
		m.Size != int64(meta.GetSize()) {
		return false
	}
	saved, err := hex.DecodeString(m.Sha256)
	if err != nil {
		return false
	}
	return bytes.Equal(saved, sum)
}

func loadPartialMeta(path string) (partialFileMeta, bool) {
	body, err := os.ReadFile(path)
	if err != nil {
		return partialFileMeta{}, false
	}
	var m partialFileMeta
	if err := json.Unmarshal(body, &m); err != nil {
		return partialFileMeta{}, false
	}
	return m, true
}

func writePartialMeta(path string, m partialFileMeta) error {
	body, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// removePartialFiles 清理半成品与续传元数据；续传参数不匹配或最终校验失败时调用。
func removePartialFiles(partPath, metaPath string) {
	_ = os.Remove(partPath)
	_ = os.Remove(metaPath)
}

// openInboundPartial 打开（必要时创建）半成品文件，返回续传起点、可写句柄，
// 以及已覆盖前缀的 SHA-256 摘要器。半成品文件尾部不完整的分片会被截断，
// 保证后续只从完整分片边界继续写。
func openInboundPartial(partPath, metaPath string, meta *nexmemv1.FileMeta, sum []byte) (int, *os.File, hash.Hash, error) {
	chunkSize := int(meta.GetChunkSize())
	total := int(meta.GetTotalChunks())
	size := int64(meta.GetSize())

	startChunk := 0
	offset := int64(0)
	if saved, ok := loadPartialMeta(metaPath); ok && saved.matches(meta, sum) {
		if fi, err := os.Stat(partPath); err == nil && fi.Mode().IsRegular() && fi.Size() > 0 {
			partSize := fi.Size()
			switch {
			case partSize >= size:
				startChunk = total
				offset = size
			case chunkSize > 0:
				startChunk = int(partSize / int64(chunkSize))
				if startChunk > total {
					startChunk = total
				}
				offset = int64(startChunk) * int64(chunkSize)
			}
		}
	}
	if startChunk == 0 {
		removePartialFiles(partPath, metaPath)
	}

	f, err := os.OpenFile(partPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return 0, nil, nil, err
	}
	fail := func(err error) (int, *os.File, hash.Hash, error) {
		_ = f.Close()
		return 0, nil, nil, err
	}
	if err := f.Truncate(offset); err != nil {
		return fail(fmt.Errorf("截断半成品文件: %w", err))
	}
	h := sha256.New()
	if offset > 0 {
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return fail(err)
		}
		if _, err := io.CopyN(h, f, offset); err != nil {
			return fail(fmt.Errorf("校验续传前缀: %w", err))
		}
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return fail(err)
	}
	if startChunk == 0 {
		if err := writePartialMeta(metaPath, newPartialFileMeta(meta, sum)); err != nil {
			return fail(err)
		}
	}
	return startChunk, f, h, nil
}
