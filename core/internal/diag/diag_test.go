package diag

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func fixedClock() func() time.Time {
	ts := time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	return func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		ts = ts.Add(time.Second)
		return ts
	}
}

func TestLoggerRecordsStructuredFields(t *testing.T) {
	l := New(WithClock(fixedClock()))
	l.Info("net", "dht.lookup", map[string]any{"dht_lookup_ms": 12.5, "ok": true})
	l.Warn("net", "net.holepunch", map[string]any{"network": "quic", "holepunch": HolePunchRelayed})

	recs := l.Recent(0)
	if len(recs) != 2 {
		t.Fatalf("记录数不符: %d", len(recs))
	}
	if recs[0].Level != "info" || recs[0].Module != "net" || recs[0].Msg != "dht.lookup" {
		t.Fatalf("首条记录字段不符: %+v", recs[0])
	}
	if recs[0].TS == 0 || recs[1].TS <= recs[0].TS {
		t.Fatalf("时间戳未单调递增: %d %d", recs[0].TS, recs[1].TS)
	}
	if got, ok := recs[0].Fields["dht_lookup_ms"].(float64); !ok || got != 12.5 {
		t.Fatalf("dht_lookup_ms 丢失: %+v", recs[0].Fields)
	}
	if recs[1].Fields["holepunch"] != HolePunchRelayed {
		t.Fatalf("holepunch 字段不符: %+v", recs[1].Fields)
	}

	raw, err := json.Marshal(recs[0])
	if err != nil {
		t.Fatalf("序列化记录: %v", err)
	}
	for _, want := range []string{`"ts"`, `"level":"info"`, `"module":"net"`, `"msg":"dht.lookup"`, `"dht_lookup_ms":12.5`} {
		if !strings.Contains(string(raw), want) {
			t.Fatalf("JSON 缺少 %s: %s", want, raw)
		}
	}
}

func TestLoggerRingBufferEviction(t *testing.T) {
	l := New(WithBufferSize(3), WithClock(fixedClock()))
	for i := 0; i < 5; i++ {
		l.Info("test", "msg", map[string]any{"i": i})
	}
	if l.Len() != 3 {
		t.Fatalf("缓冲条数不符: %d", l.Len())
	}
	if l.Dropped() != 2 {
		t.Fatalf("丢弃条数不符: %d", l.Dropped())
	}
	recs := l.Recent(0)
	if recs[0].Fields["i"] != 2 || recs[2].Fields["i"] != 4 {
		t.Fatalf("淘汰顺序不符: %+v", recs)
	}
	if got := l.Recent(1); len(got) != 1 || got[0].Fields["i"] != 4 {
		t.Fatalf("Recent(1) 不符: %+v", got)
	}
}

func TestLoggerMinLevelFilters(t *testing.T) {
	l := New(WithMinLevel(LevelWarn))
	l.Debug("test", "debug", nil)
	l.Info("test", "info", nil)
	l.Error("test", "error", nil)
	if l.Len() != 1 {
		t.Fatalf("级别过滤失效: %d", l.Len())
	}
	if l.Recent(0)[0].Msg != "error" {
		t.Fatalf("保留记录不符: %+v", l.Recent(0))
	}
}

func TestParseLevel(t *testing.T) {
	cases := map[string]Level{"debug": LevelDebug, "info": LevelInfo, "WARN": LevelWarn, "warning": LevelWarn, "error": LevelError, "": LevelInfo}
	for in, want := range cases {
		got, err := ParseLevel(in)
		if err != nil || got != want {
			t.Fatalf("ParseLevel(%q)=%v,%v", in, got, err)
		}
	}
	if _, err := ParseLevel("trace"); err == nil {
		t.Fatal("未知级别应报错")
	}
}

func TestExportRedactsSensitiveFields(t *testing.T) {
	l := New(WithClock(fixedClock()))
	l.Info("dm", "send", map[string]any{
		"peer":     "account-1",
		"text":     "hello-secret",
		"body":     []byte("cipher-or-plain"),
		"ak":       "AKIA-SECRET",
		"sk":       "SK-SECRET",
		"token":    "tok-123",
		"nested":   map[string]any{"passphrase": "p@ssw0rd", "count": 2},
		"attempts": []any{map[string]any{"secret": "inner-secret", "code": 401}},
	})
	l.Info("blob", "s3.request", map[string]any{"method": "PUT", "s3_status": 200})

	var buf bytes.Buffer
	n, err := l.Export(&buf)
	if err != nil || n != 2 {
		t.Fatalf("导出失败: n=%d err=%v", n, err)
	}
	out := buf.String()
	for _, leak := range []string{"hello-secret", "cipher-or-plain", "AKIA-SECRET", "SK-SECRET", "tok-123", "p@ssw0rd", "inner-secret"} {
		if strings.Contains(out, leak) {
			t.Fatalf("导出泄漏敏感值 %q:\n%s", leak, out)
		}
	}
	if strings.Count(out, redacted) < 6 {
		t.Fatalf("脱敏字段数不足:\n%s", out)
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("JSON Lines 行数不符: %d", len(lines))
	}
	var rec Record
	if err := json.Unmarshal([]byte(lines[0]), &rec); err != nil {
		t.Fatalf("解析导出 JSON: %v", err)
	}
	if rec.Fields["peer"] != "account-1" || rec.Fields["text"] != redacted {
		t.Fatalf("字段保留/脱敏不符: %+v", rec.Fields)
	}
	nested, _ := rec.Fields["nested"].(map[string]any)
	if nested["count"] != float64(2) || nested["passphrase"] != redacted {
		t.Fatalf("嵌套字段脱敏不符: %+v", nested)
	}
}

func TestExportFileWritesJSONLines(t *testing.T) {
	l := New(WithClock(fixedClock()))
	l.Info("dm", "send", map[string]any{"text": "do-not-export", "peer": "p1"})
	l.Error("net", "connect", map[string]any{"error": "timeout"})

	path := filepath.Join(t.TempDir(), "diag.jsonl")
	size, err := l.ExportFile(path)
	if err != nil {
		t.Fatalf("导出文件: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取导出文件: %v", err)
	}
	if size != int64(len(data)) || size == 0 {
		t.Fatalf("返回字节数不符: size=%d len=%d", size, len(data))
	}
	if strings.Contains(string(data), "do-not-export") {
		t.Fatalf("导出文件泄漏正文:\n%s", data)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("导出行数不符: %d", len(lines))
	}
	for _, line := range lines {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("导出内容不是合法 JSON: %v\n%s", err, line)
		}
	}
	leftovers, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".nexmem-diag-*"))
	if err != nil {
		t.Fatalf("检查临时文件: %v", err)
	}
	if len(leftovers) != 0 {
		t.Fatalf("残留临时文件: %v", leftovers)
	}
	if _, err := l.ExportFile(""); err == nil {
		t.Fatal("空路径应报错")
	}
}

func TestRecorderMetricsAndLogFields(t *testing.T) {
	l := New(WithClock(fixedClock()))
	r := NewRecorder(l)
	r.ObserveDHTLookup(10*time.Millisecond, nil)
	r.ObserveDHTLookup(30*time.Millisecond, nil)
	r.ObserveDHTLookup(50*time.Millisecond, errors.New("cold start"))
	r.ObserveHolePunch("TCP", HolePunchDirect)
	r.ObserveHolePunch("quic", HolePunchFailed)
	r.ObserveS3("get", 200)
	r.ObserveS3("PUT", 0)

	snap := r.Snapshot()
	if snap.DHTLookups != 3 || snap.DHTErrors != 1 {
		t.Fatalf("DHT 计数不符: %+v", snap)
	}
	if snap.DHTP50MS != 30 || snap.DHTP95MS != 50 {
		t.Fatalf("DHT 分位数不符: p50=%v p95=%v", snap.DHTP50MS, snap.DHTP95MS)
	}
	if snap.HolePunch["tcp/direct"] != 1 || snap.HolePunch["quic/failed"] != 1 {
		t.Fatalf("打洞计数不符: %+v", snap.HolePunch)
	}
	if snap.S3Status["GET/200"] != 1 || snap.S3Status["PUT/io"] != 1 {
		t.Fatalf("S3 状态码计数不符: %+v", snap.S3Status)
	}
	if snap.LogRecords != 7 {
		t.Fatalf("日志条数不符: %d", snap.LogRecords)
	}

	raw, err := json.Marshal(snap)
	if err != nil {
		t.Fatalf("序列化快照: %v", err)
	}
	for _, want := range []string{`"dht_p50_ms":30`, `"dht_p95_ms":50`, `"tcp/direct":1`, `"GET/200":1`} {
		if !strings.Contains(string(raw), want) {
			t.Fatalf("快照缺少 %s: %s", want, raw)
		}
	}

	var sawDHT, sawHole, sawS3 bool
	for _, rec := range l.Recent(0) {
		switch rec.Msg {
		case "dht.lookup":
			if _, ok := rec.Fields["dht_lookup_ms"]; ok {
				sawDHT = true
			}
		case "net.holepunch":
			if _, ok := rec.Fields["holepunch"]; ok {
				sawHole = true
			}
		case "s3.request":
			if _, ok := rec.Fields["s3_status"]; ok {
				sawS3 = true
			}
		}
	}
	if !sawDHT || !sawHole || !sawS3 {
		t.Fatalf("日志字段缺失: dht=%v holepunch=%v s3=%v", sawDHT, sawHole, sawS3)
	}
}

func TestRecorderWithoutLoggerAndEmptySnapshot(t *testing.T) {
	r := NewRecorder(nil)
	r.ObserveDHTLookup(time.Millisecond, nil)
	snap := r.Snapshot()
	if snap.LogRecords != 0 || snap.DHTLookups != 1 {
		t.Fatalf("无日志器快照不符: %+v", snap)
	}
	var nilRec *Recorder
	nilRec.ObserveS3("GET", 200)
	if snap := nilRec.Snapshot(); snap.DHTLookups != 0 {
		t.Fatalf("nil 采集器快照不符: %+v", snap)
	}
}

func TestConcurrentLogAndMetrics(t *testing.T) {
	l := New(WithBufferSize(50))
	r := NewRecorder(l)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				l.Info("test", "concurrent", map[string]any{"n": n, "j": j, "text": "secret"})
				r.ObserveDHTLookup(time.Duration(j)*time.Millisecond, nil)
				r.ObserveS3("PUT", 200)
			}
		}(i)
	}
	wg.Wait()

	if l.Len() != 50 {
		t.Fatalf("并发写入后缓冲条数不符: %d", l.Len())
	}
	snap := r.Snapshot()
	if snap.DHTLookups != 800 || snap.S3Status["PUT/200"] != 800 {
		t.Fatalf("并发指标计数不符: %+v", snap)
	}
}
