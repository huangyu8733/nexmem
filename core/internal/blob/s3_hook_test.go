package blob

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// TestOnResponseRecordsRetryStatuses 校验每次尝试（含重试）都会回报状态码。
func TestOnResponseRecordsRetryStatuses(t *testing.T) {
	var mu sync.Mutex
	var got []string
	fails := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		fails++
		n := fails
		mu.Unlock()
		if n <= 2 {
			w.WriteHeader(http.StatusInternalServerError)
			io.WriteString(w, `<Error><Code>InternalError</Code></Error>`)
			return
		}
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "ok")
	}))
	defer server.Close()

	client, err := New(Config{
		Endpoint:  server.URL,
		Bucket:    "bucket",
		AccessKey: "ak",
		SecretKey: "sk",
		PathStyle: true,
		Retries:   2,
		RetryBackoff: time.Millisecond,
		OnResponse: func(method string, status int) {
			mu.Lock()
			got = append(got, fmt.Sprintf("%s/%d", method, status))
			mu.Unlock()
		},
	})
	if err != nil {
		t.Fatalf("创建客户端: %v", err)
	}

	if _, _, err := client.Get(context.Background(), "key"); err != nil {
		t.Fatalf("GET 应在第 3 次成功: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	want := []string{"GET/500", "GET/500", "GET/200"}
	if len(got) != len(want) {
		t.Fatalf("回调次数不符: %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("第 %d 次回调不符: got %v want %v", i, got, want)
		}
	}
}

// TestOnResponseRecordsTransportError 校验传输失败以状态码 0 回报。
func TestOnResponseRecordsTransportError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := server.URL
	server.Close()

	var mu sync.Mutex
	var got []string
	client, err := New(Config{
		Endpoint:  url,
		Bucket:    "bucket",
		AccessKey: "ak",
		SecretKey: "sk",
		PathStyle: true,
		Retries:   0,
		HTTPClient: &http.Client{Timeout: 500 * time.Millisecond},
		OnResponse: func(method string, status int) {
			mu.Lock()
			got = append(got, fmt.Sprintf("%s/%d", method, status))
			mu.Unlock()
		},
	})
	if err != nil {
		t.Fatalf("创建客户端: %v", err)
	}

	if _, _, err := client.Get(context.Background(), "key"); err == nil {
		t.Fatal("连接已关闭的服务应失败")
	}

	mu.Lock()
	defer mu.Unlock()
	if len(got) != 1 || got[0] != "GET/0" {
		t.Fatalf("传输失败回调不符: %v", got)
	}
}
