package blob

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/nexmem/core/gateway"
)

// TestSelfTestAgainstFakeS3 验证自检在 S3 兼容后端上完成写入、回读、列举与清理。
func TestSelfTestAgainstFakeS3(t *testing.T) {
	fake := newFakeS3(t, "test-bucket")
	defer fake.Close()

	res, err := SelfTest(context.Background(), SelfTestParams{
		Endpoint:  fake.URL(),
		Bucket:    "test-bucket",
		Prefix:    "p6-04",
		Region:    "us-east-1",
		AccessKey: testAccessKey,
		SecretKey: testSecretKey,
		PathStyle: true,
	})
	if err != nil {
		t.Fatalf("自检失败: %v", err)
	}
	if !res.OK || !res.Writable || !res.Listable {
		t.Fatalf("自检结果不完整: %+v", res)
	}
	if res.LatencyMS < 0 {
		t.Fatalf("耗时不能为负: %d", res.LatencyMS)
	}

	fake.mu.Lock()
	remaining := len(fake.objects)
	fake.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("自检对象未清理，残留 %d 个", remaining)
	}
}

// TestSelfTestAuthRejected 验证凭证错误被归类为 ErrAuth。
func TestSelfTestAuthRejected(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, `<Error><Code>AccessDenied</Code><Message>denied</Message></Error>`)
	}))
	defer server.Close()

	_, err := SelfTest(context.Background(), SelfTestParams{
		Endpoint:  server.URL,
		Bucket:    "test-bucket",
		Prefix:    "p6-04",
		Region:    "us-east-1",
		AccessKey: "bad",
		SecretKey: "bad",
		PathStyle: true,
	})
	if !errors.Is(err, ErrAuth) {
		t.Fatalf("期望 ErrAuth，实际 %v", err)
	}
}

// TestSelfTestRejectsBadConfig 验证缺前缀与非法 Endpoint 在发请求前就被拒绝。
func TestSelfTestRejectsBadConfig(t *testing.T) {
	cases := map[string]SelfTestParams{
		"缺少前缀": {
			Endpoint: "http://127.0.0.1:1", Bucket: "b", Region: "auto",
			AccessKey: "ak", SecretKey: "sk",
		},
		"非法协议": {
			Endpoint: "ftp://127.0.0.1", Bucket: "b", Prefix: "p", Region: "auto",
			AccessKey: "ak", SecretKey: "sk",
		},
		"缺少凭证": {
			Endpoint: "http://127.0.0.1:1", Bucket: "b", Prefix: "p", Region: "auto",
		},
	}
	for name, params := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := SelfTest(context.Background(), params); !errors.Is(err, errInvalidConfig) {
				t.Fatalf("期望配置错误，实际 %v", err)
			}
		})
	}
}

// TestStorageTestGateway 验证 storage.test 的注册、返回结构与错误码映射。
func TestStorageTestGateway(t *testing.T) {
	fake := newFakeS3(t, "test-bucket")
	defer fake.Close()

	g := gateway.New()
	if err := Bind(g); err != nil {
		t.Fatalf("绑定网关: %v", err)
	}

	params, err := json.Marshal(map[string]any{
		"endpoint":   fake.URL(),
		"bucket":     "test-bucket",
		"prefix":     "p6-04/gateway",
		"region":     "us-east-1",
		"ak":         testAccessKey,
		"sk":         testSecretKey,
		"path_style": true,
	})
	if err != nil {
		t.Fatalf("构造参数: %v", err)
	}
	data, gerr := g.Handle(context.Background(), "storage.test", params)
	if gerr != nil {
		t.Fatalf("storage.test 失败: %v", gerr)
	}
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("序列化结果: %v", err)
	}
	for _, want := range []string{`"ok":true`, `"writable":true`, `"listable":true`, `"latency_ms"`} {
		if !strings.Contains(string(raw), want) {
			t.Fatalf("结果缺少 %s: %s", want, raw)
		}
	}

	info, gerr := g.Handle(context.Background(), "core.info", nil)
	if gerr != nil {
		t.Fatalf("core.info 失败: %v", gerr)
	}
	features := info.(map[string]any)["features"].([]string)
	found := false
	for _, name := range features {
		if name == "storage.test" {
			found = true
		}
	}
	if !found {
		t.Fatalf("core.info 未上报 storage.test: %v", features)
	}
}

// TestStorageTestGatewayErrorCodes 验证参数缺失、配置错误与鉴权失败的错误码。
func TestStorageTestGatewayErrorCodes(t *testing.T) {
	g := gateway.New()
	if err := Bind(g); err != nil {
		t.Fatalf("绑定网关: %v", err)
	}

	if _, gerr := g.Handle(context.Background(), "storage.test", json.RawMessage(`{"endpoint":"http://127.0.0.1:1"}`)); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺必填参数应返回 INVALID_ARG，实际 %+v", gerr)
	}

	emptyPrefix := json.RawMessage(`{"endpoint":"http://127.0.0.1:1","bucket":"b","prefix":" ","region":"auto","ak":"a","sk":"s"}`)
	if _, gerr := g.Handle(context.Background(), "storage.test", emptyPrefix); gerr == nil || gerr.Code != gateway.CodeInvalidArg {
		t.Fatalf("空前缀应返回 INVALID_ARG，实际 %+v", gerr)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, `<Error><Code>AccessDenied</Code></Error>`)
	}))
	defer server.Close()
	authParams, err := json.Marshal(map[string]any{
		"endpoint": server.URL, "bucket": "b", "prefix": "p", "region": "auto", "ak": "a", "sk": "s",
		"path_style": true,
	})
	if err != nil {
		t.Fatalf("构造参数: %v", err)
	}
	if _, gerr := g.Handle(context.Background(), "storage.test", authParams); gerr == nil || gerr.Code != gateway.CodeS3Auth {
		t.Fatalf("伪造凭证应返回 S3_AUTH，实际 %+v", gerr)
	}
}
