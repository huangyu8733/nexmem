package group

import (
	"encoding/hex"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// pendingMaxPerVersion 是单个（群、密钥版本）最多暂存的消息数。
	pendingMaxPerVersion = 64
	// pendingMaxTotal 是全部暂存消息的总上限。
	pendingMaxTotal = 512
	// pendingTTL 是暂存消息等待对应密钥版本的最长时间。
	pendingTTL = 10 * time.Minute
)

// pendingEnvelope 是一条因缺少对应版本群密钥而暂存的入站消息。
// 只保留解密与入库所需字段，不持有 GossipSub 的缓冲引用。
type pendingEnvelope struct {
	GroupID       []byte
	SenderAccount []byte
	MsgUUID       string
	SentAt        int64
	KeyVersion    uint32
	Body          []byte
	Since         time.Time
}

// pendingMessages 按（群、密钥版本）暂存入站群消息，密钥到达后由 flushPending 补解交付。
// 暂存有界：单版本 64 条、总量 512 条、最长 10 分钟，超限或过期按最旧优先丢弃。
type pendingMessages struct {
	mu      sync.Mutex
	buckets map[string][]pendingEnvelope
	total   int
}

func newPendingMessages() *pendingMessages {
	return &pendingMessages{buckets: make(map[string][]pendingEnvelope)}
}

// pendingBucketKey 生成（群、密钥版本）的稳定索引键。
func pendingBucketKey(groupID []byte, version uint32) string {
	return hex.EncodeToString(groupID) + "/" + strconv.FormatUint(uint64(version), 10)
}

// Add 暂存一条消息，返回本次因过期或超限被丢弃的条数。
func (p *pendingMessages) Add(ev pendingEnvelope, now time.Time) int {
	p.mu.Lock()
	defer p.mu.Unlock()

	dropped := p.purgeLocked(now)
	key := pendingBucketKey(ev.GroupID, ev.KeyVersion)
	bucket := append(p.buckets[key], ev)
	p.total++
	for len(bucket) > pendingMaxPerVersion {
		bucket = bucket[1:]
		p.total--
		dropped++
	}
	p.buckets[key] = bucket
	for p.total > pendingMaxTotal {
		if !p.evictOldestLocked() {
			break
		}
		dropped++
	}
	return dropped
}

// Take 取出并清空指定（群、密钥版本）的暂存消息。
func (p *pendingMessages) Take(groupID []byte, version uint32) []pendingEnvelope {
	p.mu.Lock()
	defer p.mu.Unlock()

	key := pendingBucketKey(groupID, version)
	bucket := p.buckets[key]
	if len(bucket) == 0 {
		delete(p.buckets, key)
		return nil
	}
	delete(p.buckets, key)
	p.total -= len(bucket)
	return bucket
}

// Len 返回当前暂存条数。
func (p *pendingMessages) Len() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.total
}

// Drop 丢弃指定群的全部暂存消息；退群或解散后调用。
func (p *pendingMessages) Drop(groupID []byte) {
	p.mu.Lock()
	defer p.mu.Unlock()
	prefix := hex.EncodeToString(groupID) + "/"
	for key, bucket := range p.buckets {
		if !strings.HasPrefix(key, prefix) {
			continue
		}
		p.total -= len(bucket)
		delete(p.buckets, key)
	}
}

// purgeLocked 清理超过 TTL 的暂存消息；调用方必须持有 p.mu。
func (p *pendingMessages) purgeLocked(now time.Time) int {
	deadline := now.Add(-pendingTTL)
	dropped := 0
	for key, bucket := range p.buckets {
		keep := bucket[:0]
		for _, ev := range bucket {
			if ev.Since.Before(deadline) {
				dropped++
				continue
			}
			keep = append(keep, ev)
		}
		if len(keep) == 0 {
			delete(p.buckets, key)
			continue
		}
		p.buckets[key] = keep
	}
	p.total -= dropped
	return dropped
}

// evictOldestLocked 丢弃全局最旧的一条消息；返回是否成功。
func (p *pendingMessages) evictOldestLocked() bool {
	oldestKey := ""
	var oldest time.Time
	for key, bucket := range p.buckets {
		if len(bucket) == 0 {
			continue
		}
		if oldestKey == "" || bucket[0].Since.Before(oldest) {
			oldestKey = key
			oldest = bucket[0].Since
		}
	}
	if oldestKey == "" {
		return false
	}
	bucket := p.buckets[oldestKey]
	if len(bucket) <= 1 {
		delete(p.buckets, oldestKey)
	} else {
		p.buckets[oldestKey] = bucket[1:]
	}
	p.total--
	return true
}
