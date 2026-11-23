package blob

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testAccessKey = "AKIAIOSFODNN7EXAMPLE"
	testSecretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
)

// TestSignRequestAWSVector 校验官方 SigV4 GET Object 示例的签名。
func TestSignRequestAWSVector(t *testing.T) {
	client := &Client{region: "us-east-1", accessKey: testAccessKey, secretKey: testSecretKey}
	now := mustParseTime(t, "20130524T000000Z")

	req, err := http.NewRequest(http.MethodGet, "https://examplebucket.s3.amazonaws.com/test.txt", nil)
	if err != nil {
		t.Fatalf("构造请求: %v", err)
	}
	req.Header.Set("Range", "bytes=0-9")
	req.Header.Set("x-amz-content-sha256", EmptyPayloadHash)
	req.Header.Set("x-amz-date", "20130524T000000Z")
	client.signRequest(req, EmptyPayloadHash, now)

	auth := req.Header.Get("Authorization")
	if !strings.Contains(auth, "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date") {
		t.Fatalf("SignedHeaders 不符: %s", auth)
	}
	const want = "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
	if got := authSignature(t, auth); got != want {
		t.Fatalf("签名不符:\n got %s\nwant %s", got, want)
	}
}

// TestPresignGetAWSVector 校验官方 SigV4 Query String 示例的签名。
func TestPresignGetAWSVector(t *testing.T) {
	client, err := New(Config{
		Endpoint:  "https://s3.amazonaws.com",
		Region:    "us-east-1",
		Bucket:    "examplebucket",
		AccessKey: testAccessKey,
		SecretKey: testSecretKey,
	})
	if err != nil {
		t.Fatalf("创建客户端: %v", err)
	}
	client.now = func() time.Time { return mustParseTime(t, "20130524T000000Z") }

	raw, err := client.PresignGet("test.txt", 24*time.Hour)
	if err != nil {
		t.Fatalf("生成 presign: %v", err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("解析 presign URL: %v", err)
	}
	if u.Host != "examplebucket.s3.amazonaws.com" {
		t.Fatalf("host 不符: %s", u.Host)
	}
	if u.Path != "/test.txt" {
		t.Fatalf("path 不符: %s", u.Path)
	}
	q := u.Query()
	if q.Get("X-Amz-Expires") != "86400" || q.Get("X-Amz-SignedHeaders") != "host" {
		t.Fatalf("presign 参数不符: %s", u.RawQuery)
	}
	const want = "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
	if got := q.Get("X-Amz-Signature"); got != want {
		t.Fatalf("presign 签名不符:\n got %s\nwant %s", got, want)
	}
}

func TestSigV4PathEncoding(t *testing.T) {
	client, err := New(Config{
		Endpoint:  "https://s3.amazonaws.com",
		Region:    "us-east-1",
		Bucket:    "b",
		AccessKey: testAccessKey,
		SecretKey: testSecretKey,
	})
	if err != nil {
		t.Fatalf("创建客户端: %v", err)
	}
	client.now = func() time.Time { return mustParseTime(t, "20130524T000000Z") }

	key := "inbox/目录 a+b/msg 1.msg"
	raw, err := client.PresignPut(key, 10*time.Minute)
	if err != nil {
		t.Fatalf("生成 presign: %v", err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("解析 presign URL: %v", err)
	}
	if want := "/inbox/%E7%9B%AE%E5%BD%95%20a%2Bb/msg%201.msg"; u.EscapedPath() != want {
		t.Fatalf("路径编码不符:\n got %s\nwant %s", u.EscapedPath(), want)
	}
	if strings.Contains(raw, " ") {
		t.Fatalf("presign URL 含未编码空格: %s", raw)
	}
}

func TestClientRoundTrip(t *testing.T) {
	server := newFakeS3(t, "test-bucket")
	defer server.Close()

	client := newFakeClient(t, server.URL())
	ctx := context.Background()

	info, err := client.Put(ctx, "inbox/a.txt", []byte("hello"), "text/plain")
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	if info.Size != 5 || info.Key != "inbox/a.txt" {
		t.Fatalf("Put 元数据不符: %+v", info)
	}

	head, err := client.Head(ctx, "inbox/a.txt")
	if err != nil {
		t.Fatalf("Head: %v", err)
	}
	if head.Size != 5 || head.ETag == "" {
		t.Fatalf("Head 元数据不符: %+v", head)
	}

	data, meta, err := client.Get(ctx, "inbox/a.txt")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(data) != "hello" || meta.Size != 5 {
		t.Fatalf("Get 内容不符: %q %+v", data, meta)
	}

	items, err := client.List(ctx, "inbox/")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(items) != 1 || items[0].Key != "inbox/a.txt" {
		t.Fatalf("List 结果不符: %+v", items)
	}

	if _, _, err := client.Get(ctx, "inbox/missing.txt"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("缺失对象应返回 ErrNotFound，实际 %v", err)
	}

	if err := client.Delete(ctx, "inbox/a.txt"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := client.Head(ctx, "inbox/a.txt"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("删除后 Head 应返回 ErrNotFound，实际 %v", err)
	}
}

func TestClientListPagination(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("continuation-token") == "" {
			w.Header().Set("Content-Type", "application/xml")
			_, _ = io.WriteString(w, `<ListBucketResult>
				<IsTruncated>true</IsTruncated>
				<NextContinuationToken>tok-2</NextContinuationToken>
				<Contents><Key>page/a</Key><Size>1</Size><ETag>"e1"</ETag></Contents>
			</ListBucketResult>`)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		_, _ = io.WriteString(w, `<ListBucketResult>
				<IsTruncated>false</IsTruncated>
				<Contents><Key>page/b</Key><Size>2</Size><ETag>"e2"</ETag></Contents>
			</ListBucketResult>`)
	}))
	defer server.Close()

	client := newFakeClient(t, server.URL)
	items, err := client.List(context.Background(), "page/")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(items) != 2 || items[0].Key != "page/a" || items[1].Key != "page/b" {
		t.Fatalf("分页结果不符: %+v", items)
	}
}

func TestClientRetryOnThrottle(t *testing.T) {
	server := newFakeS3(t, "test-bucket")
	server.failPuts(2)
	defer server.Close()

	client := newFakeClient(t, server.URL())
	client.retries = 2
	client.backoff = time.Millisecond

	if _, err := client.Put(context.Background(), "inbox/retry.txt", []byte("x"), ""); err != nil {
		t.Fatalf("重试后应成功: %v", err)
	}
	if got := server.putAttempts(); got != 3 {
		t.Fatalf("期望 3 次尝试，实际 %d", got)
	}
}

func TestClientErrorClassification(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   error
	}{
		{"鉴权失败", http.StatusForbidden, `<Error><Code>AccessDenied</Code><Message>denied</Message></Error>`, ErrAuth},
		{"签名错误", http.StatusForbidden, `<Error><Code>SignatureDoesNotMatch</Code></Error>`, ErrAuth},
		{"对象不存在", http.StatusNotFound, `<Error><Code>NoSuchKey</Code></Error>`, ErrNotFound},
		{"限流", http.StatusTooManyRequests, `<Error><Code>TooManyRequests</Code></Error>`, ErrQuota},
		{"慢速降级", http.StatusServiceUnavailable, `<Error><Code>SlowDown</Code></Error>`, ErrQuota},
		{"服务异常", http.StatusInternalServerError, `<Error><Code>InternalError</Code></Error>`, ErrIO},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()

			client := newFakeClient(t, server.URL)
			client.retries = 0
			_, _, err := client.Get(context.Background(), "inbox/x")
			if !errors.Is(err, tc.want) {
				t.Fatalf("期望 %v，实际 %v", tc.want, err)
			}
		})
	}
}

func TestPresignPutUpload(t *testing.T) {
	server := newFakeS3(t, "test-bucket")
	defer server.Close()

	client := newFakeClient(t, server.URL())
	raw, err := client.PresignPut("inbox/presigned.txt", 10*time.Minute)
	if err != nil {
		t.Fatalf("PresignPut: %v", err)
	}
	req, err := http.NewRequest(http.MethodPut, raw, strings.NewReader("presigned"))
	if err != nil {
		t.Fatalf("构造请求: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("上传: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("上传状态 %d", resp.StatusCode)
	}
	data, _, err := client.Get(context.Background(), "inbox/presigned.txt")
	if err != nil || string(data) != "presigned" {
		t.Fatalf("读回失败: %q %v", data, err)
	}
}

func TestNewRejectsBadConfig(t *testing.T) {
	cases := []Config{
		{},
		{Endpoint: "ftp://host", Bucket: "b", AccessKey: "k", SecretKey: "s"},
		{Endpoint: "https://host", AccessKey: "k", SecretKey: "s"},
		{Endpoint: "https://host", Bucket: "b"},
	}
	for i, cfg := range cases {
		if _, err := New(cfg); err == nil {
			t.Fatalf("配置 %d 应被拒绝: %+v", i, cfg)
		}
	}
}

// TestLiveS3PutListGet 用于真实 R2 / MinIO 联调，未设置 NEXMEM_S3_ENDPOINT 时跳过。
func TestLiveS3PutListGet(t *testing.T) {
	endpoint := os.Getenv("NEXMEM_S3_ENDPOINT")
	if endpoint == "" {
		t.Skip("未设置 NEXMEM_S3_ENDPOINT，跳过真实 S3 联调")
	}
	cfg := Config{
		Endpoint:  endpoint,
		Region:    envOr("NEXMEM_S3_REGION", "us-east-1"),
		Bucket:    envOr("NEXMEM_S3_BUCKET", "nexmem"),
		AccessKey: envOr("NEXMEM_S3_ACCESS_KEY", "minioadmin"),
		SecretKey: envOr("NEXMEM_S3_SECRET_KEY", "minioadmin"),
		PathStyle: envOr("NEXMEM_S3_PATH_STYLE", "true") == "true",
	}
	client, err := New(cfg)
	if err != nil {
		t.Fatalf("创建客户端: %v", err)
	}

	ctx := context.Background()
	prefix := fmt.Sprintf("p3-02-live/%d/", time.Now().UnixNano())
	key := prefix + "hello.txt"
	payload := []byte("nexmem p3-02 live")

	if _, err := client.Put(ctx, key, payload, "text/plain"); err != nil {
		t.Fatalf("PUT: %v", err)
	}
	if info, err := client.Head(ctx, key); err != nil || info.Size != int64(len(payload)) {
		t.Fatalf("HEAD: %+v %v", info, err)
	}
	data, _, err := client.Get(ctx, key)
	if err != nil || string(data) != string(payload) {
		t.Fatalf("GET: %q %v", data, err)
	}
	items, err := client.List(ctx, prefix)
	if err != nil {
		t.Fatalf("LIST: %v", err)
	}
	found := false
	for _, item := range items {
		if item.Key == key {
			found = true
		}
	}
	if !found {
		t.Fatalf("LIST 未包含 %s: %+v", key, items)
	}

	if raw, err := client.PresignPut(prefix+"presigned.txt", 5*time.Minute); err != nil {
		t.Fatalf("PresignPut: %v", err)
	} else {
		req, _ := http.NewRequest(http.MethodPut, raw, strings.NewReader("presigned"))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("presigned PUT: %v", err)
		}
		resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			t.Fatalf("presigned PUT 状态 %d", resp.StatusCode)
		}
	}

	if err := client.Delete(ctx, key); err != nil {
		t.Fatalf("DELETE: %v", err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func newFakeClient(t *testing.T, endpoint string) *Client {
	t.Helper()
	client, err := New(Config{
		Endpoint:  endpoint,
		Region:    "us-east-1",
		Bucket:    "test-bucket",
		AccessKey: testAccessKey,
		SecretKey: testSecretKey,
		PathStyle: true,
	})
	if err != nil {
		t.Fatalf("创建客户端: %v", err)
	}
	client.backoff = time.Millisecond
	return client
}

func mustParseTime(t *testing.T, value string) time.Time {
	t.Helper()
	parsed, err := time.Parse(amzDateLayout, value)
	if err != nil {
		t.Fatalf("解析时间: %v", err)
	}
	return parsed
}

func authSignature(t *testing.T, authorization string) string {
	t.Helper()
	for _, part := range strings.Split(authorization, ",") {
		part = strings.TrimSpace(part)
		if strings.HasPrefix(part, "Signature=") {
			return strings.TrimPrefix(part, "Signature=")
		}
	}
	t.Fatalf("Authorization 缺少 Signature: %s", authorization)
	return ""
}

// fakeS3 是最小的 S3 兼容服务端，仅覆盖客户端用到的行为。
type fakeS3 struct {
	t        *testing.T
	bucket   string
	server   *httptest.Server
	mu       sync.Mutex
	objects  map[string][]byte
	failLeft int
	puts     int
}

func newFakeS3(t *testing.T, bucket string) *fakeS3 {
	t.Helper()
	f := &fakeS3{t: t, bucket: bucket, objects: map[string][]byte{}}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	return f
}

func (f *fakeS3) URL() string { return f.server.URL }
func (f *fakeS3) Close()      { f.server.Close() }

func (f *fakeS3) failPuts(n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failLeft = n
}

func (f *fakeS3) putAttempts() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.puts
}

func (f *fakeS3) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()

	key := strings.TrimPrefix(r.URL.Path, "/"+f.bucket)
	key = strings.TrimPrefix(key, "/")

	if r.Method == http.MethodGet && key == "" {
		f.list(w, r)
		return
	}

	switch r.Method {
	case http.MethodPut:
		f.puts++
		if f.failLeft > 0 {
			f.failLeft--
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, `<Error><Code>SlowDown</Code><Message>retry</Message></Error>`)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		sum := sha256.Sum256(body)
		if got := r.Header.Get("x-amz-content-sha256"); got != "" && got != hex.EncodeToString(sum[:]) {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `<Error><Code>XAmzContentSHA256Mismatch</Code></Error>`)
			return
		}
		presigned := r.URL.Query().Get("X-Amz-Signature") != ""
		if !presigned && !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=") {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, `<Error><Code>AccessDenied</Code></Error>`)
			return
		}
		f.objects[key] = body
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:8])+`"`)
	case http.MethodGet:
		body, ok := f.objects[key]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `<Error><Code>NoSuchKey</Code><Message>missing</Message></Error>`)
			return
		}
		w.Header().Set("ETag", `"etag"`)
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(body)
	case http.MethodHead:
		body, ok := f.objects[key]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("ETag", `"etag"`)
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
	case http.MethodDelete:
		if _, ok := f.objects[key]; !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `<Error><Code>NoSuchKey</Code></Error>`)
			return
		}
		delete(f.objects, key)
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (f *fakeS3) list(w http.ResponseWriter, r *http.Request) {
	prefix := r.URL.Query().Get("prefix")
	keys := make([]string, 0, len(f.objects))
	for key := range f.objects {
		if strings.HasPrefix(key, prefix) {
			keys = append(keys, key)
		}
	}
	var result listBucketResult
	for _, key := range keys {
		result.Contents = append(result.Contents, struct {
			Key          string `xml:"Key"`
			Size         int64  `xml:"Size"`
			ETag         string `xml:"ETag"`
			LastModified string `xml:"LastModified"`
		}{Key: key, Size: int64(len(f.objects[key])), ETag: `"etag"`, LastModified: time.Now().UTC().Format(time.RFC3339)})
	}
	w.Header().Set("Content-Type", "application/xml")
	_ = xml.NewEncoder(w).Encode(result)
}
