package directory

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func reportServer(t *testing.T, cfg Config) (*Server, *httptest.Server) {
	t.Helper()
	if cfg.PerIPPerSecond == 0 {
		cfg.PerIPPerSecond = 1 << 20
	}
	if cfg.PerAccountPerSecond == 0 {
		cfg.PerAccountPerSecond = 1 << 20
	}
	s := newTestServerWithConfig(t, cfg)
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return s, ts
}

func TestSubmitReportStoresRecord(t *testing.T) {
	s, ts := reportServer(t, Config{})
	fixture := newProfileFixture(t, 1)

	body, _ := json.Marshal(map[string]string{
		"reason":          "spam",
		"conversation_id": "dm:" + strings.Repeat("a", 43),
		"detail":          "连续发送广告",
		"diagnostics_b64": base64.StdEncoding.EncodeToString([]byte("{\"event\":\"boot\"}\n")),
		"client_version":  "nexmem-app/0.1.0",
	})
	status, raw := doRequest(t, ts, fixture.account, http.MethodPost, "/v1/report", body, "application/json")
	if status != http.StatusOK {
		t.Fatalf("举报应成功，实际 %d %s", status, raw)
	}
	var resp reportResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("解码举报回包: %v", err)
	}
	if len(resp.ID) != 32 {
		t.Fatalf("举报 ID 长度异常: %q", resp.ID)
	}
	if resp.CreatedAt <= 0 {
		t.Fatalf("举报时间戳缺失: %d", resp.CreatedAt)
	}

	n, err := s.countReports(context.Background(), fixture.id)
	if err != nil {
		t.Fatalf("统计举报: %v", err)
	}
	if n != 1 {
		t.Fatalf("举报应落库 1 条，实际 %d", n)
	}

	var detail string
	if err := s.db.QueryRow(`SELECT detail FROM reports WHERE id = ?`, resp.ID).Scan(&detail); err != nil {
		t.Fatalf("读取举报: %v", err)
	}
	if detail != "连续发送广告" {
		t.Fatalf("举报说明丢失: %q", detail)
	}
}

func TestSubmitReportRejectsInvalidInput(t *testing.T) {
	_, ts := reportServer(t, Config{ReportPerAccountPerSecond: 1 << 20})
	fixture := newProfileFixture(t, 1)

	cases := []struct {
		name string
		body map[string]string
	}{
		{"缺少原因", map[string]string{"detail": "空原因"}},
		{"原因非法", map[string]string{"reason": "whatever"}},
		{"说明超长", map[string]string{"reason": "other", "detail": strings.Repeat("长", 2001)}},
		{"诊断包非法", map[string]string{"reason": "other", "diagnostics_b64": "!!!"}},
		{
			"诊断包超限",
			map[string]string{
				"reason":          "other",
				"diagnostics_b64": base64.StdEncoding.EncodeToString(make([]byte, maxReportDiagnostics+1)),
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body, _ := json.Marshal(tc.body)
			status, raw := doRequest(t, ts, fixture.account, http.MethodPost, "/v1/report", body, "application/json")
			if status != http.StatusBadRequest {
				t.Fatalf("%s 应返回 400，实际 %d %s", tc.name, status, raw)
			}
		})
	}
}

func TestSubmitReportRequiresSignature(t *testing.T) {
	_, ts := reportServer(t, Config{})
	body, _ := json.Marshal(map[string]string{"reason": "spam"})
	status, _ := doRequest(t, ts, nil, http.MethodPost, "/v1/report", body, "application/json")
	if status != http.StatusUnauthorized {
		t.Fatalf("未签名举报应 401，实际 %d", status)
	}
}

func TestSubmitReportRateLimited(t *testing.T) {
	_, ts := reportServer(t, Config{ReportPerAccountPerSecond: 1})
	fixture := newProfileFixture(t, 1)
	body, _ := json.Marshal(map[string]string{"reason": "spam"})

	if status, raw := doRequest(t, ts, fixture.account, http.MethodPost, "/v1/report", body, "application/json"); status != http.StatusOK {
		t.Fatalf("首次举报应成功，实际 %d %s", status, raw)
	}
	if status, _ := doRequest(t, ts, fixture.account, http.MethodPost, "/v1/report", body, "application/json"); status != http.StatusTooManyRequests {
		t.Fatalf("同秒第二次举报应 429，实际 %d", status)
	}
}
