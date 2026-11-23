// Package backup 提供账号与本地库的加密备份（P6-05）。
//
// 备份文件是流式分块加密容器，避免把整库读进内存：
//
//	magic "NEXMEMBK1"(9B) | salt(16B) | noncePrefix(8B) | chunkSize(uint32 BE)
//	{ ciphertextLen(uint32 BE) | ciphertext }*
//	0 长度块 = 结束
//
// 口令经 scrypt 派生 32 字节密钥；每块用 noncePrefix||counter 的 AES-256-GCM
// 加密，AAD 绑定文件头，因此换头、重排、截断与篡改都会解密失败。
package backup

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/scrypt"
)

const (
	backupMagic     = "NEXMEMBK1"
	magicSize       = len(backupMagic)
	formatVersion   = 1
	saltSize        = 16
	noncePrefixSize = 8
	nonceSize       = 12
	keySize         = 32
	defaultChunk    = 1 << 20
	maxChunkSize    = 16 << 20

	// scrypt 参数：约 32 MiB 内存开销，桌面与移动端均可接受。
	scryptN = 1 << 15
	scryptR = 8
	scryptP = 1
)

var (
	// ErrFormat 表示备份文件头、分块或容器结构非法。
	ErrFormat = errors.New("备份文件格式不支持或已损坏")
	// ErrDecrypt 表示口令错误或密文被篡改。
	ErrDecrypt = errors.New("备份口令错误或文件被篡改")
	// ErrPassphraseRequired 表示未提供备份口令。
	ErrPassphraseRequired = errors.New("备份口令不能为空")
)

func deriveKey(passphrase, salt []byte) ([]byte, error) {
	if len(passphrase) == 0 {
		return nil, ErrPassphraseRequired
	}
	return scrypt.Key(passphrase, salt, scryptN, scryptR, scryptP, keySize)
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	if len(key) != keySize {
		return nil, fmt.Errorf("%w: 密钥长度 %d", ErrFormat, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("初始化 AES: %w", err)
	}
	return cipher.NewGCM(block)
}

// sealWriter 把写入的明文按块加密后写到下游。
type sealWriter struct {
	w      io.Writer
	aead   cipher.AEAD
	header []byte
	nonce  []byte
	chunk  int
	buf    []byte
	fill   int
	count  uint32
	closed bool
}

func newSealWriter(w io.Writer, key, header []byte, chunk int) (*sealWriter, error) {
	aead, err := newAEAD(key)
	if err != nil {
		return nil, err
	}
	if chunk <= 0 || chunk > maxChunkSize {
		return nil, fmt.Errorf("%w: 分块大小 %d", ErrFormat, chunk)
	}
	return &sealWriter{
		w:      w,
		aead:   aead,
		header: header,
		nonce:  make([]byte, nonceSize),
		chunk:  chunk,
		buf:    make([]byte, chunk),
	}, nil
}

func (s *sealWriter) Write(p []byte) (int, error) {
	if s.closed {
		return 0, errors.New("备份流已关闭")
	}
	written := 0
	for len(p) > 0 {
		n := copy(s.buf[s.fill:], p)
		s.fill += n
		p = p[n:]
		written += n
		if s.fill == s.chunk {
			if err := s.flush(); err != nil {
				return written, err
			}
		}
	}
	return written, nil
}

func (s *sealWriter) flush() error {
	if s.fill == 0 {
		return nil
	}
	copy(s.nonce[:noncePrefixSize], s.header[magicSize+saltSize:magicSize+saltSize+noncePrefixSize])
	binary.BigEndian.PutUint32(s.nonce[noncePrefixSize:], s.count)
	ct := s.aead.Seal(nil, s.nonce, s.buf[:s.fill], s.header)
	s.count++
	var lb [4]byte
	binary.BigEndian.PutUint32(lb[:], uint32(len(ct)))
	if _, err := s.w.Write(lb[:]); err != nil {
		return fmt.Errorf("写入备份分块长度: %w", err)
	}
	if _, err := s.w.Write(ct); err != nil {
		return fmt.Errorf("写入备份分块: %w", err)
	}
	s.fill = 0
	return nil
}

// Close 刷出剩余明文并写入结束标记。
func (s *sealWriter) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true
	if err := s.flush(); err != nil {
		return err
	}
	var zero [4]byte
	if _, err := s.w.Write(zero[:]); err != nil {
		return fmt.Errorf("写入备份结束标记: %w", err)
	}
	return nil
}

// openReader 流式解密备份明文。
type openReader struct {
	r       io.Reader
	aead    cipher.AEAD
	header  []byte
	nonce   []byte
	count   uint32
	pending []byte
	done    bool
}

func (o *openReader) Read(p []byte) (int, error) {
	for len(o.pending) == 0 {
		if o.done {
			return 0, io.EOF
		}
		var lb [4]byte
		if _, err := io.ReadFull(o.r, lb[:]); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return 0, fmt.Errorf("%w: 备份文件被截断", ErrFormat)
			}
			return 0, err
		}
		size := binary.BigEndian.Uint32(lb[:])
		if size == 0 {
			o.done = true
			return 0, io.EOF
		}
		if size > uint32(maxChunkSize+o.aead.Overhead()) {
			return 0, fmt.Errorf("%w: 分块长度 %d", ErrFormat, size)
		}
		ct := make([]byte, size)
		if _, err := io.ReadFull(o.r, ct); err != nil {
			return 0, fmt.Errorf("%w: 备份分块不完整", ErrFormat)
		}
		copy(o.nonce[:noncePrefixSize], o.header[magicSize+saltSize:magicSize+saltSize+noncePrefixSize])
		binary.BigEndian.PutUint32(o.nonce[noncePrefixSize:], o.count)
		plain, err := o.aead.Open(nil, o.nonce, ct, o.header)
		if err != nil {
			return 0, ErrDecrypt
		}
		o.count++
		o.pending = plain
	}
	n := copy(p, o.pending)
	o.pending = o.pending[n:]
	return n, nil
}

// openBackup 校验文件头并返回明文流。
func openBackup(r io.Reader, passphrase []byte) (io.Reader, error) {
	if len(passphrase) == 0 {
		return nil, ErrPassphraseRequired
	}
	header := make([]byte, magicSize+saltSize+noncePrefixSize+4)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, fmt.Errorf("%w: 文件头不完整", ErrFormat)
	}
	if string(header[:magicSize]) != backupMagic {
		return nil, fmt.Errorf("%w: magic 不匹配", ErrFormat)
	}
	chunk := binary.BigEndian.Uint32(header[len(header)-4:])
	if chunk == 0 || chunk > maxChunkSize {
		return nil, fmt.Errorf("%w: 分块大小 %d", ErrFormat, chunk)
	}
	salt := header[magicSize : magicSize+saltSize]
	key, err := deriveKey(passphrase, salt)
	if err != nil {
		return nil, err
	}
	aead, err := newAEAD(key)
	if err != nil {
		return nil, err
	}
	return &openReader{
		r:      r,
		aead:   aead,
		header: header,
		nonce:  make([]byte, nonceSize),
	}, nil
}

// newHeader 生成文件头：magic | salt | noncePrefix | chunkSize。
func newHeader(chunk int) ([]byte, []byte, error) {
	header := make([]byte, magicSize+saltSize+noncePrefixSize+4)
	copy(header, backupMagic)
	if _, err := rand.Read(header[magicSize : magicSize+saltSize+noncePrefixSize]); err != nil {
		return nil, nil, fmt.Errorf("生成备份盐值: %w", err)
	}
	binary.BigEndian.PutUint32(header[len(header)-4:], uint32(chunk))
	return header, header[magicSize : magicSize+saltSize], nil
}
