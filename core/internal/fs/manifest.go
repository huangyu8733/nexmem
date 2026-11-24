// Package fs 实现 P2P 文件夹共享：把本地目录（或单个文件）发布为内容寻址的
// 「共享」，生成可转发的分享码；接收方从种子节点并行拉取加密分片，按 SHA-256
// 校验后落盘。分享码带账号签名，接收方可验证发布者身份与清单完整性。
//
// 设计要点：
//   - 无大小限制：清单只记录元数据，数据按固定分片经独立 libp2p 流传输，
//     分片序号为 uint32（256KiB/片 ≈ 1PiB/文件），文件数不设人为上限。
//   - 加速下载：同一共享可从多个种子并行拉取不同分片；下载完成后本机自动
//     成为该共享的种子，下载的人越多速度越快。
//   - 端到端加密：每文件独立 AES-256 密钥，密钥随签名清单下发，不经第三方。
package fs

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/nexmem/core/internal/identity"
)

const (
	// CodePrefix 是分享码的可识别前缀，便于在聊天消息中识别并一键导入。
	CodePrefix = "nexmem://fs/"
	// codeVersion 是分享码载荷版本。
	codeVersion = 1
	// manifestVersion 是清单版本。
	manifestVersion = 1
)

var (
	ErrInvalidCode    = errors.New("分享码格式非法")
	ErrInvalidManifest = errors.New("共享清单格式非法")
	ErrBadSignature   = errors.New("共享清单签名校验失败")
	ErrNotFound       = errors.New("共享不存在")
	ErrPathUnsafe     = errors.New("共享内文件路径不安全")
)

// FileEntry 描述共享中的单个文件。Key 是 32 字节 AES 密钥的 base64 编码。
type FileEntry struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
	Key    string `json:"key"`
	MIME   string `json:"mime,omitempty"`
}

// Manifest 是共享的内容寻址清单。ID 为规范化内容的 SHA-256；Sig 是发布者
// 账号私钥对 ID 的 ed25519 签名。Root 为解压后的根目录名，单文件共享为空。
type Manifest struct {
	Version   int         `json:"v"`
	ID        string      `json:"id"`
	Name      string      `json:"name"`
	Owner     string      `json:"owner"`
	Root      string      `json:"root,omitempty"`
	Files     []FileEntry `json:"files"`
	TotalSize int64       `json:"total_size"`
	CreatedAt int64       `json:"created_at"`
	Sig       string      `json:"sig"`
}

// canonical 返回参与 ID 计算的确定性 JSON。ID 只覆盖内容本身（不含发布者、
// 时间戳与签名），因此不同节点发布同一份内容会得到相同 ID，可互为种子。
// Owner 由签名保护（签名用 Owner 的公钥验证），CreatedAt 仅为展示元数据。
func (m *Manifest) canonical() ([]byte, error) {
	v := struct {
		Version   int         `json:"v"`
		Name      string      `json:"name"`
		Root      string      `json:"root,omitempty"`
		Files     []FileEntry `json:"files"`
		TotalSize int64       `json:"total_size"`
	}{m.Version, m.Name, m.Root, m.Files, m.TotalSize}
	return json.Marshal(v)
}

// Sign 由发布者账号对清单签名并回填 ID/Sig。
func (m *Manifest) Sign(acc *identity.Account) error {
	if acc == nil {
		return ErrInvalidManifest
	}
	m.Version = manifestVersion
	m.Owner = acc.ID()
	m.Files = append([]FileEntry(nil), m.Files...)
	sort.Slice(m.Files, func(i, j int) bool { return m.Files[i].Path < m.Files[j].Path })
	body, err := m.canonical()
	if err != nil {
		return err
	}
	sum := sha256.Sum256(body)
	m.ID = hex.EncodeToString(sum[:])
	m.Sig = base64.StdEncoding.EncodeToString(acc.Sign([]byte(m.ID)))
	return nil
}

// Verify 校验清单 ID 与账号签名一致，返回发布者账号 ID。
func (m *Manifest) Verify() (string, error) {
	if m == nil || m.Version != manifestVersion || m.ID == "" || len(m.Files) == 0 {
		return "", ErrInvalidManifest
	}
	owner, err := hex.DecodeString(m.Owner)
	if err != nil || len(owner) != ed25519.PublicKeySize {
		return "", ErrInvalidManifest
	}
	sig, err := base64.StdEncoding.DecodeString(m.Sig)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return "", ErrBadSignature
	}
	body, err := m.canonical()
	if err != nil {
		return "", ErrInvalidManifest
	}
	sum := sha256.Sum256(body)
	if hex.EncodeToString(sum[:]) != m.ID {
		return "", ErrBadSignature
	}
	if !ed25519.Verify(ed25519.PublicKey(owner), []byte(m.ID), sig) {
		return "", ErrBadSignature
	}
	seen := make(map[string]bool, len(m.Files))
	for _, f := range m.Files {
		if f.Path == "" || f.Size <= 0 || seen[f.Path] {
			return "", ErrInvalidManifest
		}
		if !safeRelativePath(f.Path) {
			return "", ErrPathUnsafe
		}
		if _, err := base64.StdEncoding.DecodeString(f.Key); err != nil {
			return "", ErrInvalidManifest
		}
		if _, err := hex.DecodeString(f.SHA256); err != nil {
			return "", ErrInvalidManifest
		}
		seen[f.Path] = true
	}
	return m.Owner, nil
}

// safeRelativePath 拒绝绝对路径、目录穿越与反斜杠（统一用正斜杠）。
func safeRelativePath(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") ||
		strings.Contains(p, "\x00") {
		return false
	}
	for _, part := range strings.Split(p, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

// Seed 是一个可服务该共享的种子的网络地址。
type Seed struct {
	PeerID string   `json:"peer_id"`
	Addrs  []string `json:"addrs,omitempty"`
}

// codePayload 是分享码的可移植载荷：签名清单 + 种子地址。
type codePayload struct {
	Version int       `json:"v"`
	Manifest *Manifest `json:"m"`
	Seeds   []Seed    `json:"s"`
}

// EncodeCode 生成形如 nexmem://fs/<base64url> 的分享码。
func EncodeCode(m *Manifest, seeds []Seed) (string, error) {
	if m == nil || m.ID == "" {
		return "", ErrInvalidManifest
	}
	data, err := json.Marshal(codePayload{Version: codeVersion, Manifest: m, Seeds: seeds})
	if err != nil {
		return "", err
	}
	return CodePrefix + base64.RawURLEncoding.EncodeToString(data), nil
}

// DecodeCode 解析分享码并验证清单签名，返回清单与种子地址。
func DecodeCode(code string) (*Manifest, []Seed, error) {
	code = strings.TrimSpace(code)
	if !strings.HasPrefix(code, CodePrefix) {
		return nil, nil, ErrInvalidCode
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(code, CodePrefix))
	if err != nil {
		return nil, nil, fmt.Errorf("%w: %v", ErrInvalidCode, err)
	}
	var p codePayload
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, nil, fmt.Errorf("%w: %v", ErrInvalidCode, err)
	}
	if p.Version != codeVersion || p.Manifest == nil {
		return nil, nil, ErrInvalidCode
	}
	if _, err := p.Manifest.Verify(); err != nil {
		return nil, nil, err
	}
	for _, s := range p.Seeds {
		if s.PeerID == "" {
			return nil, nil, ErrInvalidCode
		}
	}
	return p.Manifest, p.Seeds, nil
}
