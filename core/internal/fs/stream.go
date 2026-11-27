package fs

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"

	nexmemv1 "github.com/nexmem/core/api/v1"
	filecrypto "github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/wire"
)

// 共享协议帧类型。复用 wire.Frame 的签名与长度前缀，但使用独立协议 ID 与
// 帧类型段（100+），避免与 DM 文件的 1.0.0 协议互相干扰。
const (
	fsFrameInfo     nexmemv1.FrameType = 100 // 请求清单：{"id":"..."}
	fsFrameManifest nexmemv1.FrameType = 101 // 返回清单 JSON
	fsFrameChunkReq nexmemv1.FrameType = 102 // {"id":"...","path":"...","index":N}
	fsFrameChunk    nexmemv1.FrameType = 103 // {"index":N,"data":"<base64 密文>"}
	fsFrameError    nexmemv1.FrameType = 104 // {"code":"...","message":"..."}
)

const (
	fsChunkSize     = 256 << 10
	fsStreamTimeout = 30 * time.Second
)

var (
	ErrSeedUnavailable = errors.New("共享种子不可用")
	ErrChunkMismatch   = errors.New("共享分片校验失败")
)

type chunkRequest struct {
	ID    string `json:"id"`
	Path  string `json:"path"`
	Index uint32 `json:"index"`
}

type chunkResponse struct {
	Index uint32 `json:"index"`
	Data  string `json:"data"`
}

type frameError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func frameErrorOf(f *nexmemv1.Frame) string {
	var e frameError
	if json.Unmarshal(f.GetPayload(), &e) == nil && e.Message != "" {
		return e.Message
	}
	return "种子返回错误"
}

// manifestOf 返回本地存储的清单（发布或已导入）。
func (s *Service) manifestOf(id string) (*Manifest, string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.shares[id]
	if !ok {
		return nil, "", false
	}
	return rec.Manifest, rec.LocalRoot, true
}

// handleStream 处理入站共享流：先验签对端，再按帧请求清单或分片。
func (s *Service) handleStream(st network.Stream) {
	defer st.Close()
	_ = st.SetDeadline(time.Now().Add(fsStreamTimeout))
	pub := st.Conn().RemotePublicKey()
	f, err := wire.ReadFrame(st)
	if err != nil || wire.VerifyFrame(pub, f) != nil || f.GetType() != fsFrameInfo {
		return
	}
	var info struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(f.GetPayload(), &info) != nil || info.ID == "" {
		return
	}
	m, root, ok := s.manifestOf(info.ID)
	if !ok || root == "" {
		s.writeErr(st, ErrNotFound.Error())
		return
	}
	if err := s.signAndWrite(st, fsFrameManifest, m); err != nil {
		return
	}
	for {
		f, err = wire.ReadFrame(st)
		if err != nil || wire.VerifyFrame(pub, f) != nil {
			return
		}
		if f.GetType() != fsFrameChunkReq {
			return
		}
		var req chunkRequest
		if json.Unmarshal(f.GetPayload(), &req) != nil || req.ID != info.ID {
			return
		}
		data, err := s.readChunk(m, root, req)
		if err != nil {
			s.writeErr(st, err.Error())
			return
		}
		if err := s.signAndWrite(st, fsFrameChunk, chunkResponse{Index: req.Index, Data: data}); err != nil {
			return
		}
	}
}

func (s *Service) signAndWrite(st network.Stream, typ nexmemv1.FrameType, v any) error {
	payload, err := json.Marshal(v)
	if err != nil {
		return err
	}
	f := &nexmemv1.Frame{Version: wire.Version, Type: typ, Payload: payload}
	if err := wire.SignFrame(s.deviceKey, f); err != nil {
		return err
	}
	return wire.WriteFrame(st, f)
}

func (s *Service) writeErr(st network.Stream, msg string) {
	_ = s.signAndWrite(st, fsFrameError, frameError{Code: "FS_ERROR", Message: msg})
}

// readChunk 从本地文件读取指定分片并用该文件的密钥加密。
func (s *Service) readChunk(m *Manifest, root string, req chunkRequest) (string, error) {
	var entry *FileEntry
	for i := range m.Files {
		if m.Files[i].Path == req.Path {
			entry = &m.Files[i]
			break
		}
	}
	if entry == nil || !safeRelativePath(req.Path) {
		return "", ErrPathUnsafe
	}
	total := (entry.Size + fsChunkSize - 1) / fsChunkSize
	if int64(req.Index) >= total {
		return "", ErrPathUnsafe
	}
	path := filepath.Join(root, filepath.FromSlash(req.Path))
	if !withinRoot(path, root) {
		return "", ErrPathUnsafe
	}
	f, err := os.Open(path)
	if err != nil {
		return "", ErrNotFound
	}
	defer f.Close()
	off := int64(req.Index) * fsChunkSize
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		return "", err
	}
	n := int64(fsChunkSize)
	if remain := entry.Size - off; remain < n {
		n = remain
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(f, buf); err != nil {
		return "", err
	}
	key, err := base64.StdEncoding.DecodeString(entry.Key)
	if err != nil {
		return "", ErrInvalidManifest
	}
	cc, err := filecrypto.NewChunkCipher(key)
	if err != nil {
		return "", ErrInvalidManifest
	}
	return base64.StdEncoding.EncodeToString(cc.Seal(req.Index, buf)), nil
}

func withinRoot(path, root string) bool {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(absRoot, absPath)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// seedSession 是与单个种子的请求/响应会话，同一流上的请求需串行。
type seedSession struct {
	stream    network.Stream
	deviceKey crypto.PrivKey
	mu        sync.Mutex
}

// openSeedSession 连接种子、发送清单请求并消费清单响应帧，返回可复用的分片会话。
// expectedOwner 非空时同时校验发布者，防止同 ID 清单被其他账号冒充。
func (s *Service) openSeedSession(ctx context.Context, p peer.ID, addrs []string, shareID, expectedOwner string) (*seedSession, *Manifest, error) {
	mas, err := parseAddrs(addrs)
	if err != nil {
		return nil, nil, err
	}
	if err := s.connectSeed(ctx, peer.AddrInfo{ID: p, Addrs: mas}); err != nil {
		return nil, nil, err
	}
	st, err := s.host.NewStream(ctx, p, wire.PIDFs)
	if err != nil {
		return nil, nil, err
	}
	_ = st.SetDeadline(time.Now().Add(fsStreamTimeout))
	ss := &seedSession{stream: st, deviceKey: s.deviceKey}
	info, _ := json.Marshal(struct {
		ID string `json:"id"`
	}{ID: shareID})
	if err := ss.write(fsFrameInfo, info); err != nil {
		_ = st.Reset()
		return nil, nil, err
	}
	f, err := ss.read()
	if err != nil {
		_ = st.Reset()
		return nil, nil, err
	}
	if f.GetType() == fsFrameError {
		_ = st.Reset()
		return nil, nil, errors.New(frameErrorOf(f))
	}
	if f.GetType() != fsFrameManifest {
		_ = st.Reset()
		return nil, nil, fmt.Errorf("种子返回未知帧 %d", f.GetType())
	}
	var m Manifest
	if err := json.Unmarshal(f.GetPayload(), &m); err != nil {
		_ = st.Reset()
		return nil, nil, err
	}
	if m.ID != shareID {
		_ = st.Reset()
		return nil, nil, ErrBadSignature
	}
	if _, err := m.Verify(); err != nil {
		_ = st.Reset()
		return nil, nil, err
	}
	if expectedOwner != "" && m.Owner != expectedOwner {
		_ = st.Reset()
		return nil, nil, ErrBadSignature
	}
	return ss, &m, nil
}

func (ss *seedSession) write(typ nexmemv1.FrameType, payload []byte) error {
	f := &nexmemv1.Frame{Version: wire.Version, Type: typ, Payload: payload}
	if err := wire.SignFrame(ss.deviceKey, f); err != nil {
		return err
	}
	return wire.WriteFrame(ss.stream, f)
}

func (ss *seedSession) read() (*nexmemv1.Frame, error) {
	_ = ss.stream.SetDeadline(time.Now().Add(fsStreamTimeout))
	f, err := wire.ReadFrame(ss.stream)
	if err != nil {
		return nil, err
	}
	if err := wire.VerifyFrame(ss.stream.Conn().RemotePublicKey(), f); err != nil {
		return nil, err
	}
	return f, nil
}

// fetchChunk 请求单个分片，返回解密后的明文。
func (ss *seedSession) fetchChunk(m *Manifest, path string, index uint32, key []byte) ([]byte, error) {
	ss.mu.Lock()
	defer ss.mu.Unlock()
	req, _ := json.Marshal(chunkRequest{ID: m.ID, Path: path, Index: index})
	if err := ss.write(fsFrameChunkReq, req); err != nil {
		return nil, err
	}
	f, err := ss.read()
	if err != nil {
		return nil, err
	}
	if f.GetType() == fsFrameError {
		return nil, errors.New(frameErrorOf(f))
	}
	if f.GetType() != fsFrameChunk {
		return nil, fmt.Errorf("分片帧类型错误 %d", f.GetType())
	}
	var cr chunkResponse
	if err := json.Unmarshal(f.GetPayload(), &cr); err != nil {
		return nil, err
	}
	if cr.Index != index {
		return nil, ErrChunkMismatch
	}
	ciphertext, err := base64.StdEncoding.DecodeString(cr.Data)
	if err != nil {
		return nil, ErrChunkMismatch
	}
	cc, err := filecrypto.NewChunkCipher(key)
	if err != nil {
		return nil, err
	}
	plain, err := cc.Open(index, ciphertext)
	if err != nil {
		return nil, ErrChunkMismatch
	}
	return plain, nil
}

// hashOfFile 流式计算文件摘要。
func hashOfFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}
