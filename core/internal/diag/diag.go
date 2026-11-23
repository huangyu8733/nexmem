// Package diag 提供结构化日志、运行指标与脱敏导出。
//
// 设计约束：
//   - 日志只记录元数据（模块、方法、耗时、结果、状态码），不记录消息正文与凭证；
//   - 导出前按字段名脱敏，敏感值不落盘；
//   - 指标覆盖 DHT 寻址耗时、打洞结果与 S3 状态码，供诊断包与排障使用。
package diag

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Level 是日志级别，数值越小越详细。
type Level int

const (
	// LevelDebug 用于高频细节（逐次请求、重试）。
	LevelDebug Level = iota
	// LevelInfo 用于常规运行事件。
	LevelInfo
	// LevelWarn 用于可恢复的异常。
	LevelWarn
	// LevelError 用于失败与降级。
	LevelError
)

// String 返回级别名称。
func (l Level) String() string {
	switch l {
	case LevelDebug:
		return "debug"
	case LevelInfo:
		return "info"
	case LevelWarn:
		return "warn"
	case LevelError:
		return "error"
	default:
		return "info"
	}
}

// ParseLevel 解析级别名称，未知名称返回错误。
func ParseLevel(s string) (Level, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return LevelDebug, nil
	case "info", "":
		return LevelInfo, nil
	case "warn", "warning":
		return LevelWarn, nil
	case "error":
		return LevelError, nil
	default:
		return LevelInfo, fmt.Errorf("未知日志级别 %q", s)
	}
}

const (
	defaultBufferSize = 1024
	redacted          = "[REDACTED]"
)

// Record 是一条结构化日志。
type Record struct {
	TS     int64          `json:"ts"` // 毫秒时间戳
	Level  string         `json:"level"`
	Module string         `json:"module,omitempty"`
	Msg    string         `json:"msg"`
	Fields map[string]any `json:"fields,omitempty"`
}

// Logger 是并发安全的环形结构化日志器。
type Logger struct {
	mu      sync.Mutex
	records []Record
	size    int
	min     Level
	writer  io.Writer
	clock   func() time.Time
	dropped int64
}

// Option 配置 Logger。
type Option func(*Logger)

// WithBufferSize 设置环形缓冲条数，下限 1，默认 1024。
func WithBufferSize(n int) Option {
	return func(l *Logger) {
		if n > 0 {
			l.size = n
		}
	}
}

// WithMinLevel 设置最小记录级别，默认 info。
func WithMinLevel(level Level) Option {
	return func(l *Logger) { l.min = level }
}

// WithWriter 同时把每条日志以 JSON Line 写入 w（例如标准错误）。
func WithWriter(w io.Writer) Option {
	return func(l *Logger) { l.writer = w }
}

// WithClock 替换时钟，便于测试。
func WithClock(now func() time.Time) Option {
	return func(l *Logger) {
		if now != nil {
			l.clock = now
		}
	}
}

// New 创建 Logger。
func New(opts ...Option) *Logger {
	l := &Logger{size: defaultBufferSize, min: LevelInfo, clock: time.Now}
	for _, opt := range opts {
		if opt != nil {
			opt(l)
		}
	}
	return l
}

// Debug 记录 debug 级别日志。
func (l *Logger) Debug(module, msg string, fields map[string]any) {
	l.Log(LevelDebug, module, msg, fields)
}

// Info 记录 info 级别日志。
func (l *Logger) Info(module, msg string, fields map[string]any) {
	l.Log(LevelInfo, module, msg, fields)
}

// Warn 记录 warn 级别日志。
func (l *Logger) Warn(module, msg string, fields map[string]any) {
	l.Log(LevelWarn, module, msg, fields)
}

// Error 记录 error 级别日志。
func (l *Logger) Error(module, msg string, fields map[string]any) {
	l.Log(LevelError, module, msg, fields)
}

// Log 记录一条日志；低于最小级别的直接丢弃。
func (l *Logger) Log(level Level, module, msg string, fields map[string]any) {
	if l == nil || level < l.min {
		return
	}
	rec := Record{
		TS:     l.clock().UnixMilli(),
		Level:  level.String(),
		Module: module,
		Msg:    msg,
		Fields: sanitizeFields(fields),
	}

	l.mu.Lock()
	l.records = append(l.records, rec)
	if extra := len(l.records) - l.size; extra > 0 {
		copy(l.records, l.records[extra:])
		l.records = l.records[:l.size]
		l.dropped += int64(extra)
	}
	writer := l.writer
	l.mu.Unlock()

	if writer != nil {
		_ = json.NewEncoder(writer).Encode(rec)
	}
}

// Len 返回当前缓冲中的日志条数。
func (l *Logger) Len() int {
	if l == nil {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.records)
}

// Dropped 返回因缓冲溢出被丢弃的日志条数。
func (l *Logger) Dropped() int64 {
	if l == nil {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.dropped
}

// Recent 返回最近 n 条日志的副本；n <= 0 表示全部。
func (l *Logger) Recent(n int) []Record {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	start := 0
	if n > 0 && n < len(l.records) {
		start = len(l.records) - n
	}
	out := make([]Record, 0, len(l.records)-start)
	for _, rec := range l.records[start:] {
		out = append(out, Record{
			TS:     rec.TS,
			Level:  rec.Level,
			Module: rec.Module,
			Msg:    rec.Msg,
			Fields: copyFields(rec.Fields),
		})
	}
	return out
}

// Export 以 JSON Lines 写出全部缓冲日志，返回写入条数。
func (l *Logger) Export(w io.Writer) (int, error) {
	if w == nil {
		return 0, errors.New("导出目标为空")
	}
	enc := json.NewEncoder(w)
	count := 0
	for _, rec := range l.Recent(0) {
		if err := enc.Encode(rec); err != nil {
			return count, fmt.Errorf("写日志: %w", err)
		}
		count++
	}
	return count, nil
}

// ExportFile 把脱敏日志原子写入 path，返回文件字节数。
func (l *Logger) ExportFile(path string) (int64, error) {
	if strings.TrimSpace(path) == "" {
		return 0, errors.New("诊断导出路径为空")
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".nexmem-diag-*.jsonl")
	if err != nil {
		return 0, fmt.Errorf("创建临时导出文件: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	bw := bufio.NewWriter(tmp)
	if _, err := l.Export(bw); err != nil {
		tmp.Close()
		return 0, err
	}
	if err := bw.Flush(); err != nil {
		tmp.Close()
		return 0, fmt.Errorf("刷新导出文件: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return 0, fmt.Errorf("同步导出文件: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return 0, fmt.Errorf("关闭导出文件: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return 0, fmt.Errorf("替换导出文件: %w", err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		return 0, fmt.Errorf("读取导出文件: %w", err)
	}
	return fi.Size(), nil
}

// sensitiveKeys 中的字段名一律脱敏；命中后缀规则的字段同样脱敏。
var sensitiveKeys = map[string]struct{}{
	"text":          {},
	"body":          {},
	"content":       {},
	"plaintext":     {},
	"params":        {},
	"token":         {},
	"access_token":  {},
	"session_token": {},
	"password":      {},
	"passphrase":    {},
	"secret":        {},
	"secret_key":    {},
	"secretkey":     {},
	"ak":            {},
	"sk":            {},
	"access_key":    {},
	"private_key":   {},
	"privatekey":    {},
	"x_priv":        {},
	"group_key":     {},
	"content_key":   {},
	"authorization": {},
}

func sensitiveKey(key string) bool {
	k := strings.ToLower(strings.TrimSpace(key))
	if _, ok := sensitiveKeys[k]; ok {
		return true
	}
	for _, suffix := range []string{"_token", "_secret", "_password", "_passphrase"} {
		if strings.HasSuffix(k, suffix) {
			return true
		}
	}
	return false
}

func sanitizeFields(fields map[string]any) map[string]any {
	if len(fields) == 0 {
		return nil
	}
	out := make(map[string]any, len(fields))
	for k, v := range fields {
		if sensitiveKey(k) {
			out[k] = redacted
			continue
		}
		out[k] = sanitizeValue(v)
	}
	return out
}

func sanitizeValue(v any) any {
	switch x := v.(type) {
	case nil:
		return nil
	case map[string]any:
		return sanitizeFields(x)
	case []any:
		out := make([]any, len(x))
		for i := range x {
			out[i] = sanitizeValue(x[i])
		}
		return out
	case []byte:
		// 二进制可能是密钥或正文，只保留长度。
		return fmt.Sprintf("[%dB]", len(x))
	case error:
		return x.Error()
	default:
		return x
	}
}

func copyFields(fields map[string]any) map[string]any {
	if fields == nil {
		return nil
	}
	out := make(map[string]any, len(fields))
	for k, v := range fields {
		out[k] = v
	}
	return out
}
