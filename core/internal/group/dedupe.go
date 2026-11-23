package group

import (
	"sync"
	"time"
)

// fingerprintEntry 是去重缓存中的一条记录。
type fingerprintEntry struct {
	key string
	at  time.Time
}

// fingerprintCache 记录最近受理过的群消息指纹（msg_uuid）。
//
// GossipSub 自身会按消息 ID 去重，但缓存会随节点重启与 seen 窗口淘汰，
// 且在"同一消息从多个 mesh 邻居重复下发"时仍需一层应用侧兜底，
// 因此这里维护一个带 TTL 与容量上限的窗口。
type fingerprintCache struct {
	mu       sync.Mutex
	ttl      time.Duration
	capacity int
	order    []fingerprintEntry
	seen     map[string]time.Time
}

func newFingerprintCache(ttl time.Duration, capacity int) *fingerprintCache {
	if ttl <= 0 {
		ttl = DefaultDedupeTTL
	}
	if capacity <= 0 {
		capacity = DefaultDedupeCapacity
	}
	return &fingerprintCache{
		ttl:      ttl,
		capacity: capacity,
		seen:     make(map[string]time.Time),
	}
}

// Add 记录一条指纹并返回它是否为首次出现。重复或空指纹返回 false。
func (c *fingerprintCache) Add(key string) bool {
	if key == "" {
		return false
	}
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pruneLocked(now)
	if _, ok := c.seen[key]; ok {
		return false
	}
	c.seen[key] = now
	c.order = append(c.order, fingerprintEntry{key: key, at: now})
	for len(c.order) > c.capacity {
		old := c.order[0]
		c.order = c.order[1:]
		if at, ok := c.seen[old.key]; ok && at.Equal(old.at) {
			delete(c.seen, old.key)
		}
	}
	return true
}

// Has 判断指纹是否仍在窗口内（不写入）。
func (c *fingerprintCache) Has(key string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pruneLocked(time.Now())
	_, ok := c.seen[key]
	return ok
}

func (c *fingerprintCache) pruneLocked(now time.Time) {
	cutoff := now.Add(-c.ttl)
	i := 0
	for ; i < len(c.order); i++ {
		e := c.order[i]
		if e.at.After(cutoff) {
			break
		}
		if at, ok := c.seen[e.key]; ok && at.Equal(e.at) {
			delete(c.seen, e.key)
		}
	}
	if i > 0 {
		c.order = append(c.order[:0], c.order[i:]...)
	}
}
