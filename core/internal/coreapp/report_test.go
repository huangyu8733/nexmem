package coreapp

// 举报上报（P6-06）的联调用例：内核 → 索引服务 → 落库。

import (
	"context"
	"database/sql"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/nexmem/core/gateway"
	dirsrv "github.com/nexmem/core/server/directory"
)

// startAppWithDirectory 启动内核并接入一个真实索引服务实例。
func startAppWithDirectory(t *testing.T, dir, directoryURL string) (*gateway.Gateway, *App) {
	t.Helper()
	gw := gateway.New()
	app, err := New(gw, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if _, err := app.Start(context.Background(), Config{
		DataDir:      dir,
		Listen:       []string{"/ip4/127.0.0.1/tcp/0"},
		DirectoryURL: directoryURL,
	}); err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	t.Cleanup(func() { _ = app.Stop() })
	return gw, app
}

func newDirectoryServer(t *testing.T) (*dirsrv.Server, *httptest.Server, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "directory.db")
	srv, err := dirsrv.New(dbPath)
	if err != nil {
		t.Fatalf("创建索引服务: %v", err)
	}
	t.Cleanup(func() { _ = srv.Close() })
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, ts, dbPath
}

func TestReportSubmitEndToEnd(t *testing.T) {
	_, ts, dbPath := newDirectoryServer(t)
	dir := t.TempDir()
	gw, _ := startAppWithDirectory(t, dir, ts.URL)

	diagPath := filepath.Join(dir, "diag.jsonl")
	if err := os.WriteFile(diagPath, []byte("{\"event\":\"boot\"}\n"), 0o600); err != nil {
		t.Fatalf("写诊断包: %v", err)
	}

	data, ok := call(t, gw, "report.submit", map[string]any{
		"reason":           "harassment",
		"conversation_id":  "dm:peer",
		"detail":           "持续辱骂",
		"diagnostics_path": diagPath,
		"client_version":   "test",
	}).(map[string]any)
	if !ok {
		t.Fatal("report.submit 返回值不是对象")
	}
	id, _ := data["report_id"].(string)
	if len(id) != 32 {
		t.Fatalf("举报 ID 异常: %q", id)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("打开索引库: %v", err)
	}
	defer db.Close()
	var reason, detail, diagnostics string
	if err := db.QueryRow(
		`SELECT reason, detail, CAST(diagnostics AS TEXT) FROM reports WHERE id = ?`, id,
	).Scan(&reason, &detail, &diagnostics); err != nil {
		t.Fatalf("读取举报记录: %v", err)
	}
	if reason != "harassment" || detail != "持续辱骂" {
		t.Fatalf("举报内容不一致: %q %q", reason, detail)
	}
	if diagnostics != "{\"event\":\"boot\"}\n" {
		t.Fatalf("诊断包未按原样上报: %q", diagnostics)
	}
}

func TestReportSubmitWithoutDirectory(t *testing.T) {
	dir := t.TempDir()
	gw, _ := startAppWithDirectory(t, dir, "")

	gerr := callErr(t, gw, "report.submit", map[string]any{"reason": "spam"})
	if gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("未配置索引服务应返回 NOT_STARTED，实际 %s", gerr.Code)
	}
}

func TestReportSubmitRejectsBadInput(t *testing.T) {
	_, ts, _ := newDirectoryServer(t)
	dir := t.TempDir()
	gw, _ := startAppWithDirectory(t, dir, ts.URL)

	big := filepath.Join(dir, "big.jsonl")
	if err := os.WriteFile(big, make([]byte, maxReportDiagnostics+1), 0o600); err != nil {
		t.Fatalf("写超限诊断包: %v", err)
	}
	cases := []struct {
		name   string
		params map[string]any
	}{
		{"原因非法", map[string]any{"reason": "unknown"}},
		{"说明超长", map[string]any{"reason": "other", "detail": longText(maxReportDetailRunes + 1)}},
		{"诊断包缺失", map[string]any{"reason": "other", "diagnostics_path": filepath.Join(dir, "missing.jsonl")}},
		{"诊断包超限", map[string]any{"reason": "other", "diagnostics_path": big}},
		{"相对路径", map[string]any{"reason": "other", "diagnostics_path": "diag.jsonl"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gerr := callErr(t, gw, "report.submit", tc.params)
			if gerr.Code != gateway.CodeInvalidArg {
				t.Fatalf("%s 应返回 INVALID_ARG，实际 %s", tc.name, gerr.Code)
			}
		})
	}
}

func longText(runes int) string {
	out := make([]rune, runes)
	for i := range out {
		out[i] = '长'
	}
	return string(out)
}
