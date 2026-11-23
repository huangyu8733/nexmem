// Package settingsync 实现多设备设置同步的「导出 / 导入」本地闭环（P6-41）。
//
// 多端在线已支持，但设置与未读游标各端独立；换机后体验割裂。本包把本机
// 设置快照编码为一段自描述、带校验和的文本（settings://v1/<base64url>），
// 用户通过文件/剪贴板在设备间搬运：导出端 Produce，导入端 Consume 后按
// 冲突策略合并。真正的实时跨设备推送依赖共用 S3 桶 / 真机，按 R-17 挂起。
package settingsync

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

const (
	// Prefix 是设置快照文本的可识别前缀。
	Prefix = "settings://v1/"
	version = 1
	maxEntries = 512
	maxValueBytes = 4096
	maxKeyLen = 64
)

var (
	ErrFormat = errors.New("设置快照格式非法")
	ErrVersion = errors.New("设置快照版本不支持")
	ErrChecksum = errors.New("设置快照校验和错误")
)

// Entry 是快照中的单个设置项。
type Entry struct {
	Key   string `json:"k"`
	Value string `json:"v"`
}

// Snapshot 是可序列化的设置快照，含规则版本号与校验和。
type Snapshot struct {
	Version int     `json:"v"`
	Entries []Entry `json:"e"`
	Sum     string  `json:"s"` // sha256(规范化 entries 的 hex)
}

type keyPatternCheck func(string) bool

// defaultKeyValid 是设置键的宽松校验（与 coreapp.normalizeSettingKey 兼容的超集）。
func defaultKeyValid(k string) bool {
	if k == "" || len(k) > maxKeyLen {
		return false
	}
	for _, r := range k {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' {
			continue
		}
		return false
	}
	return true
}

// checksum 计算 entries 的确定性校验和（先按 key 排序序列化）。
func checksum(entries []Entry) string {
	normalized := make([]Entry, len(entries))
	copy(normalized, entries)
	sort.Slice(normalized, func(i, j int) bool { return normalized[i].Key < normalized[j].Key })
	raw, _ := json.Marshal(normalized)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// Produce 把一组设置项编码为快照文本。调用方负责提供已规范化的 key/value。
func Produce(entries []Entry) (string, error) {
	if len(entries) > maxEntries {
		return "", fmt.Errorf("%w: 条目数超过 %d", ErrFormat, maxEntries)
	}
	seen := make(map[string]bool, len(entries))
	for _, e := range entries {
		if !defaultKeyValid(e.Key) {
			return "", fmt.Errorf("%w: 非法设置键 %q", ErrFormat, e.Key)
		}
		if seen[e.Key] {
			return "", fmt.Errorf("%w: 重复设置键 %q", ErrFormat, e.Key)
		}
		seen[e.Key] = true
		if len(e.Value) > maxValueBytes {
			return "", fmt.Errorf("%w: 设置值超过 %d 字节", ErrFormat, maxValueBytes)
		}
	}
	snap := Snapshot{Version: version, Entries: entries, Sum: checksum(entries)}
	raw, err := json.Marshal(snap)
	if err != nil {
		return "", fmt.Errorf("序列化设置快照: %w", err)
	}
	return Prefix + base64.RawURLEncoding.EncodeToString(raw), nil
}

// Consume 解析并校验快照文本，返回其中的设置项。
func Consume(text string) ([]Entry, error) {
	raw := strings.TrimSpace(text)
	if !strings.HasPrefix(raw, Prefix) {
		return nil, fmt.Errorf("%w: 缺少前缀", ErrFormat)
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(raw, Prefix))
	if err != nil || len(data) == 0 {
		return nil, fmt.Errorf("%w: base64url 解码失败", ErrFormat)
	}
	var snap Snapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return nil, fmt.Errorf("%w: JSON 解析失败", ErrFormat)
	}
	if snap.Version != version {
		return nil, fmt.Errorf("%w: %d", ErrVersion, snap.Version)
	}
	if len(snap.Entries) > maxEntries {
		return nil, fmt.Errorf("%w: 条目数超过上限", ErrFormat)
	}
	seen := make(map[string]bool, len(snap.Entries))
	for _, e := range snap.Entries {
		if !defaultKeyValid(e.Key) || seen[e.Key] || len(e.Value) > maxValueBytes {
			return nil, fmt.Errorf("%w: 非法条目 %q", ErrFormat, e.Key)
		}
		seen[e.Key] = true
	}
	if checksum(snap.Entries) != snap.Sum {
		return nil, ErrChecksum
	}
	return snap.Entries, nil
}

// unused 保留对可注入 key 校验器的扩展点，避免未来改动破坏 API。
var _ keyPatternCheck = defaultKeyValid
