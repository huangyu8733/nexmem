package diag

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/nexmem/core/gateway"
)

// newBoundGateway 组装一个绑定诊断能力的网关；logger 为 nil 时模拟未初始化。
func newBoundGateway(t *testing.T, logger *Logger) *gateway.Gateway {
	t.Helper()
	if logger == nil {
		logger = New(WithClock(fixedClock()))
	}
	rec := NewRecorder(logger)
	g := gateway.New()
	if err := Bind(g, rec); err != nil {
		t.Fatalf("绑定诊断能力: %v", err)
	}
	return g
}

func handleData(t *testing.T, g *gateway.Gateway, method string, params map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("编码参数: %v", err)
	}
	data, gerr := g.Handle(context.Background(), method, raw)
	if gerr != nil {
		t.Fatalf("%s 返回错误: %v", method, gerr)
	}
	out, ok := data.(map[string]any)
	if !ok {
		t.Fatalf("%s 返回类型不符: %T", method, data)
	}
	return out
}

func handleError(t *testing.T, g *gateway.Gateway, method string, params map[string]any) *gateway.Error {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("编码参数: %v", err)
	}
	_, gerr := g.Handle(context.Background(), method, raw)
	if gerr == nil {
		t.Fatalf("%s 预期失败但成功", method)
	}
	return gerr
}

func TestDiagExportWritesRedactedFile(t *testing.T) {
	logger := New(WithClock(fixedClock()))
	logger.Info("dm", "dm.send", map[string]any{
		"text":     "今晚八点老地方见",
		"token":    "user-access-token-123",
		"ak":       "AKPLAINTEXT",
		"msg_uuid": "uuid-1",
	})
	logger.Info("blob", "s3.request", map[string]any{
		"method":    "PUT",
		"s3_status": 200,
		"raw":       []byte("secret-body-bytes"),
	})

	g := newBoundGateway(t, logger)
	path := filepath.Join(t.TempDir(), "diag-out.jsonl")
	out := handleData(t, g, "diag.export", map[string]any{"path": path})

	if got := out["path"]; got != path {
		t.Fatalf("返回路径不符: %v", got)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取导出文件: %v", err)
	}
	if len(raw) == 0 {
		t.Fatal("导出文件为空")
	}
	for _, leak := range []string{"今晚八点老地方见", "user-access-token-123", "AKPLAINTEXT", "secret-body-bytes"} {
		if strings.Contains(string(raw), leak) {
			t.Fatalf("导出文件泄漏敏感值 %q: %s", leak, raw)
		}
	}
	for _, want := range []string{`"msg_uuid":"uuid-1"`, `"s3_status":200`, redacted, `"[17B]"`} {
		if !strings.Contains(string(raw), want) {
			t.Fatalf("导出文件缺少 %s: %s", want, raw)
		}
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != 2 {
		t.Fatalf("导出行数不符: %d", len(lines))
	}
	for _, line := range lines {
		var rec Record
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("导出内容不是合法 JSONL: %v", err)
		}
	}
}

func TestDiagExportRejectsInvalidPath(t *testing.T) {
	g := newBoundGateway(t, nil)

	for name, params := range map[string]map[string]any{
		"缺少 path": {},
		"空 path":  {"path": "   "},
		"目录路径":    {"path": t.TempDir() + string(filepath.Separator)},
	} {
		gerr := handleError(t, g, "diag.export", params)
		if gerr.Code != gateway.CodeInvalidArg {
			t.Fatalf("%s 的错误码不符: %s", name, gerr.Code)
		}
	}
}

func TestDiagExportWithoutLoggerReturnsNotStarted(t *testing.T) {
	g := gateway.New()
	if err := Bind(g, NewRecorder(nil)); err != nil {
		t.Fatalf("绑定诊断能力: %v", err)
	}
	gerr := handleError(t, g, "diag.export", map[string]any{
		"path": filepath.Join(t.TempDir(), "diag.jsonl"),
	})
	if gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("错误码不符: %s", gerr.Code)
	}
}

func TestDiagBindRejectsNilDependencies(t *testing.T) {
	if err := Bind(nil, NewRecorder(nil)); err == nil {
		t.Fatal("缺少网关时应报错")
	}
	if err := Bind(gateway.New(), nil); err == nil {
		t.Fatal("缺少采集器时应报错")
	}
}

func TestDiagSnapshotReportsMetrics(t *testing.T) {
	logger := New(WithClock(fixedClock()))
	rec := NewRecorder(logger)
	rec.ObserveDHTLookup(30*time.Millisecond, nil)
	rec.ObserveDHTLookup(50*time.Millisecond, nil)
	rec.ObserveHolePunch("quic", HolePunchDirect)
	rec.ObserveHolePunch("quic", HolePunchRelayed)
	rec.ObserveS3("PUT", 200)
	rec.ObserveS3("GET", 500)

	g := gateway.New()
	if err := Bind(g, rec); err != nil {
		t.Fatalf("绑定诊断能力: %v", err)
	}
	out := handleData(t, g, "diag.snapshot", map[string]any{})

	if got := out["dht_lookups"]; got != int64(2) {
		t.Fatalf("dht_lookups 不符: %v", got)
	}
	if got := out["dht_p50_ms"]; got != float64(30) {
		t.Fatalf("dht_p50_ms 不符: %v", got)
	}
	if got := out["dht_p95_ms"]; got != float64(50) {
		t.Fatalf("dht_p95_ms 不符: %v", got)
	}
	holes, ok := out["holepunch"].(map[string]int64)
	if !ok {
		t.Fatalf("holepunch 类型不符: %T", out["holepunch"])
	}
	keys := make([]string, 0, len(holes))
	for k := range holes {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := []string{"quic/direct", "quic/relayed"}
	if len(keys) != len(want) || keys[0] != want[0] || keys[1] != want[1] {
		t.Fatalf("holepunch 不符: %v", keys)
	}
	s3, ok := out["s3_status"].(map[string]int64)
	if !ok || s3["PUT/200"] != 1 || s3["GET/500"] != 1 {
		t.Fatalf("s3_status 不符: %#v", out["s3_status"])
	}
	if got := out["log_records"]; got != 6 {
		t.Fatalf("log_records 不符: %v", got)
	}
	if _, ok := out["uptime_ms"]; !ok {
		t.Fatal("缺少 uptime_ms")
	}
}
