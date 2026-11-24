// Package discovery 提供三种并存的节点发现源，统一为「账号公钥 -> 可直连地址」：
//
//  1. 本地地址簿（Peerbook）：用户手动导入或从二维码名片写入的 multiaddr，
//     持久化在本机 KV，解析优先级最高，不依赖任何公网服务。
//  2. mDNS 局域网发现：同网段广播 PeerID 与地址，无需任何基础设施。
//  3. 公共 DHT：接入公共 IPFS bootstrap，冷启动时兜底寻址。
//
// 三者都实现同一个 Source 接口，由 CascadingResolver 按优先级串联，
// 任意一个源命中即可返回；全部失败才判定对端不可达。
package discovery

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/libp2p/go-libp2p/core/peer"
	ma "github.com/multiformats/go-multiaddr"

	"github.com/nexmem/core/internal/store"
)

const (
	// peerbookKVKey 是本地地址簿在 KV 中的存储键。
	peerbookKVKey = "net.peerbook"
	// maxPeerbookEntries 限制地址簿条目数，避免被当作任意写入的存储器。
	maxPeerbookEntries = 512
	// addrTTL 是 mDNS 发现地址的过期时间；过期后需重新发现，避免僵尸地址。
	addrTTL = 5 * time.Minute
)

// Source 是一个发现源：给定账号公钥，返回一组候选 PeerID/地址。
// 找不到时返回 ok=false，不视为错误，交由下一个源继续。
type Source interface {
	Discover(ctx context.Context, accountPub []byte) ([]peer.AddrInfo, bool)
	Name() string
}

// PeerEntry 是地址簿中的一条记录。
type PeerEntry struct {
	AccountID string   `json:"account_id"` // 账号公钥 hex
	PeerID    string   `json:"peer_id"`    // 设备 PeerID
	Addrs     []string `json:"addrs"`      // multiaddr 字符串列表
	Label     string   `json:"label,omitempty"`
	UpdatedAt int64    `json:"updated_at"` // Unix 毫秒
}

// Peerbook 是持久化的本地地址簿（手动发现源）。
// 它实现 Source 与 store 无关的接口，便于独立测试。
type Peerbook struct {
	mu      sync.RWMutex
	entries map[string]PeerEntry // key = accountID hex
	dao     *store.DAO
}

// NewPeerbook 创建空地址簿。dao 为空时仅内存存储（测试/无持久化场景）。
func NewPeerbook(dao *store.DAO) *Peerbook {
	return &Peerbook{entries: map[string]PeerEntry{}, dao: dao}
}

// Name 实现 Source。
func (b *Peerbook) Name() string { return "本地地址簿" }

// Load 从 KV 恢复地址簿；数据损坏时返回空簿而不阻断启动。
func (b *Peerbook) Load(ctx context.Context) error {
	if b.dao == nil {
		return nil
	}
	raw, err := b.dao.GetKV(ctx, peerbookKVKey)
	if err != nil || len(raw) == 0 {
		return nil
	}
	var list []PeerEntry
	if err := json.Unmarshal(raw, &list); err != nil {
		return fmt.Errorf("解析本地地址簿: %w", err)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, e := range list {
		if normalizeAccount(e.AccountID) == "" {
			continue
		}
		b.entries[normalizeAccount(e.AccountID)] = e
	}
	return nil
}

// saveLocked 把当前条目写回 KV；调用方需持有写锁。
func (b *Peerbook) saveLocked(ctx context.Context) error {
	if b.dao == nil {
		return nil
	}
	list := make([]PeerEntry, 0, len(b.entries))
	for _, e := range b.entries {
		list = append(list, e)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].AccountID < list[j].AccountID })
	raw, err := json.Marshal(list)
	if err != nil {
		return err
	}
	return b.dao.SetKV(ctx, peerbookKVKey, raw)
}

// Put 写入或更新一条账号地址记录。accountID 必须是 64 位十六进制账号公钥。
func (b *Peerbook) Put(ctx context.Context, accountID, peerID string, addrs []string, label string) error {
	aid := normalizeAccount(accountID)
	if aid == "" {
		return fmt.Errorf("账号 ID 非法：需为 64 位十六进制")
	}
	clean := cleanAddrs(addrs)
	if len(clean) == 0 {
		return fmt.Errorf("至少需要一条合法的 multiaddr")
	}
	if pid, err := peer.Decode(strings.TrimSpace(peerID)); err == nil {
		peerID = pid.String()
	}
	entry := PeerEntry{
		AccountID: aid,
		PeerID:    strings.TrimSpace(peerID),
		Addrs:     clean,
		Label:     strings.TrimSpace(label),
		UpdatedAt: time.Now().UnixMilli(),
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, exists := b.entries[aid]; !exists && len(b.entries) >= maxPeerbookEntries {
		return fmt.Errorf("地址簿已满（上限 %d 条）", maxPeerbookEntries)
	}
	b.entries[aid] = entry
	if err := b.saveLocked(ctx); err != nil {
		delete(b.entries, aid)
		return fmt.Errorf("保存地址簿: %w", err)
	}
	return nil
}

// Remove 删除一条记录；键不存在时静默成功。
func (b *Peerbook) Remove(ctx context.Context, accountID string) error {
	aid := normalizeAccount(accountID)
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, exists := b.entries[aid]; !exists {
		return nil
	}
	delete(b.entries, aid)
	if err := b.saveLocked(ctx); err != nil {
		return fmt.Errorf("保存地址簿: %w", err)
	}
	return nil
}

// List 返回全部记录（按账号 ID 排序），供 RPC 展示。
func (b *Peerbook) List() []PeerEntry {
	b.mu.RLock()
	defer b.mu.RUnlock()
	out := make([]PeerEntry, 0, len(b.entries))
	for _, e := range b.entries {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AccountID < out[j].AccountID })
	return out
}

// Discover 实现 Source：按账号公钥查找地址簿。
func (b *Peerbook) Discover(_ context.Context, accountPub []byte) ([]peer.AddrInfo, bool) {
	if len(accountPub) != 32 {
		return nil, false
	}
	aid := hex.EncodeToString(accountPub)
	b.mu.RLock()
	entry, ok := b.entries[aid]
	b.mu.RUnlock()
	if !ok || len(entry.Addrs) == 0 {
		return nil, false
	}
	info, err := entryToAddrInfo(entry)
	if err != nil {
		return nil, false
	}
	return []peer.AddrInfo{info}, true
}

// AddrInfoFor 按账号 hex 返回地址簿条目对应的 AddrInfo，供 mDNS 关联使用。
func (b *Peerbook) AddrInfoFor(accountID string) (peer.AddrInfo, bool) {
	aid := normalizeAccount(accountID)
	b.mu.RLock()
	entry, ok := b.entries[aid]
	b.mu.RUnlock()
	if !ok {
		return peer.AddrInfo{}, false
	}
	info, err := entryToAddrInfo(entry)
	return info, err == nil
}

func entryToAddrInfo(entry PeerEntry) (peer.AddrInfo, error) {
	pid, err := peer.Decode(strings.TrimSpace(entry.PeerID))
	if err != nil {
		return peer.AddrInfo{}, err
	}
	addrs := make([]ma.Multiaddr, 0, len(entry.Addrs))
	for _, raw := range entry.Addrs {
		a, err := ma.NewMultiaddr(raw)
		if err == nil {
			addrs = append(addrs, a)
		}
	}
	if len(addrs) == 0 {
		return peer.AddrInfo{}, fmt.Errorf("无合法地址")
	}
	return peer.AddrInfo{ID: pid, Addrs: addrs}, nil
}

// normalizeAccount 规范化账号 hex：去 0x 前缀、去空白、转小写，并校验长度。
func normalizeAccount(s string) string {
	s = strings.TrimSpace(strings.ToLower(s))
	s = strings.TrimPrefix(s, "0x")
	if len(s) != 64 {
		return ""
	}
	if _, err := hex.DecodeString(s); err != nil {
		return ""
	}
	return s
}

// cleanAddrs 去重并校验 multiaddr 字符串。
func cleanAddrs(addrs []string) []string {
	out := make([]string, 0, len(addrs))
	seen := map[string]struct{}{}
	for _, raw := range addrs {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if _, err := ma.NewMultiaddr(raw); err != nil {
			continue
		}
		if _, dup := seen[raw]; dup {
			continue
		}
		seen[raw] = struct{}{}
		out = append(out, raw)
	}
	return out
}
