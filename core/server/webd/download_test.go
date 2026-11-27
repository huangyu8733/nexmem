package webd

import (
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func downloadRequest(t *testing.T, token, requestedPath string) *http.Response {
	t.Helper()
	return downloadRawRequest(t, http.MethodGet, url.Values{
		"token": []string{token},
		"path":  []string{requestedPath},
	}, nil)
}

// downloadRawRequest 构造可自定义方法、查询参数与请求头的下载请求，
// 用于验证 Range / HEAD / inline / header token 等浏览器媒体播放所需能力。
func downloadRawRequest(
	t *testing.T,
	method string,
	values url.Values,
	headers http.Header,
) *http.Response {
	t.Helper()
	_, ts := newServer(t, Config{
		UploadDir:    t.TempDir(),
		DownloadDirs: []string{downloadTestRoot},
	})
	u := ts.URL + "/download"
	if len(values) > 0 {
		u += "?" + values.Encode()
	}
	req, err := http.NewRequest(method, u, nil)
	if err != nil {
		t.Fatalf("构造下载请求: %v", err)
	}
	for key, vals := range headers {
		for _, val := range vals {
			req.Header.Add(key, val)
		}
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("请求下载: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

// downloadTestRoot 是 downloadRequest 内使用的白名单根目录，按测试进程固定。
var downloadTestRoot = func() string {
	dir, err := os.MkdirTemp("", "nexmem-download-root-")
	if err != nil {
		panic(err)
	}
	return dir
}()

func TestDownloadAuthenticatedFile(t *testing.T) {
	want := []byte("group-file-bytes-\x00\x01")
	target := filepath.Join(downloadTestRoot, "report.bin")
	if err := os.WriteFile(target, want, 0o600); err != nil {
		t.Fatalf("写入测试文件: %v", err)
	}
	resp := downloadRequest(t, testToken, target)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("正确令牌应下载成功，实际 %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Content-Disposition"); !strings.Contains(got, "attachment") || !strings.Contains(got, "report.bin") {
		t.Fatalf("缺少附件下载头: %q", got)
	}
	buf, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取下载内容: %v", err)
	}
	if string(buf) != string(want) {
		t.Fatalf("下载内容不符: got %q want %q", buf, want)
	}
}

func TestDownloadRejectsBadToken(t *testing.T) {
	target := filepath.Join(downloadTestRoot, "secret.bin")
	if err := os.WriteFile(target, []byte("x"), 0o600); err != nil {
		t.Fatalf("写入测试文件: %v", err)
	}
	resp := downloadRequest(t, "wrong-token", target)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("错误令牌应 401，实际 %d", resp.StatusCode)
	}
}

func TestDownloadRejectsOutsideWhitelist(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "private.bin")
	if err := os.WriteFile(outside, []byte("private-key"), 0o600); err != nil {
		t.Fatalf("写入测试文件: %v", err)
	}
	// data-dir 根的父目录/临时目录不在白名单内。
	resp := downloadRequest(t, testToken, outside)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("白名单外文件应 403，实际 %d", resp.StatusCode)
	}
}

func TestDownloadRejectsTraversalAndDirectory(t *testing.T) {
	// 请求白名单目录本身（目录不是普通文件）应 404。
	resp := downloadRequest(t, testToken, downloadTestRoot)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("目录应拒绝下载，实际 %d", resp.StatusCode)
	}

	// 符号链接指向白名单外的文件，解析后应 403。
	outside := filepath.Join(t.TempDir(), "private.bin")
	if err := os.WriteFile(outside, []byte("private-key"), 0o600); err != nil {
		t.Fatalf("写入测试文件: %v", err)
	}
	link := filepath.Join(downloadTestRoot, "escape.bin")
	_ = os.Remove(link)
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("当前平台不支持符号链接: %v", err)
	}
	resp = downloadRequest(t, testToken, link)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("符号链接逃逸应 403，实际 %d", resp.StatusCode)
	}
}

func TestDownloadRejectsMissingMethodAndPath(t *testing.T) {
	srv, ts := newServer(t, Config{UploadDir: t.TempDir()})
	_ = srv

	resp, err := http.Post(ts.URL+"/download?token="+testToken, "text/plain", nil)
	if err != nil {
		t.Fatalf("POST 请求: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST 应 405，实际 %d", resp.StatusCode)
	}

	resp, err = http.Get(ts.URL + "/download?token=" + testToken)
	if err != nil {
		t.Fatalf("缺少 path: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("缺少 path 应 400，实际 %d", resp.StatusCode)
	}
}

func TestDownloadInlineDispositionForMedia(t *testing.T) {
	target := filepath.Join(downloadTestRoot, "clip.mp4")
	if err := os.WriteFile(target, []byte("0123456789"), 0o600); err != nil {
		t.Fatalf("写入测试文件: %v", err)
	}
	resp := downloadRawRequest(t, http.MethodGet, url.Values{
		"token":       []string{testToken},
		"path":        []string{target},
		"disposition": []string{"inline"},
	}, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("inline 播放应 200，实际 %d", resp.StatusCode)
	}
	got := resp.Header.Get("Content-Disposition")
	if !strings.Contains(got, "inline") || !strings.Contains(got, "clip.mp4") {
		t.Fatalf("缺少 inline 播放头: %q", got)
	}
	buf, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取播放内容: %v", err)
	}
	if string(buf) != "0123456789" {
		t.Fatalf("播放内容不符: %q", buf)
	}
}

func TestDownloadSupportsRangeAndHead(t *testing.T) {
	target := filepath.Join(downloadTestRoot, "range.mp4")
	if err := os.WriteFile(target, []byte("0123456789"), 0o600); err != nil {
		t.Fatalf("写入测试文件: %v", err)
	}

	resp := downloadRawRequest(t, http.MethodGet, url.Values{
		"token":       []string{testToken},
		"path":        []string{target},
		"disposition": []string{"inline"},
	}, http.Header{"Range": []string{"bytes=2-5"}})
	if resp.StatusCode != http.StatusPartialContent {
		t.Fatalf("Range 请求应 206，实际 %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Content-Range"); !strings.Contains(got, "bytes 2-5/10") {
		t.Fatalf("缺少 Content-Range: %q", got)
	}
	if got := resp.Header.Get("Accept-Ranges"); !strings.EqualFold(got, "bytes") {
		t.Fatalf("应声明字节范围: %q", got)
	}
	buf, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取 Range 内容: %v", err)
	}
	if string(buf) != "2345" {
		t.Fatalf("Range 内容不符: %q", buf)
	}

	head := downloadRawRequest(t, http.MethodHead, url.Values{
		"token": []string{testToken},
		"path":  []string{target},
	}, nil)
	if head.StatusCode != http.StatusOK {
		t.Fatalf("HEAD 应 200，实际 %d", head.StatusCode)
	}
	if got := head.Header.Get("Content-Length"); got != "10" {
		t.Fatalf("HEAD Content-Length 不符: %q", got)
	}
}

func TestDownloadAcceptsHeaderToken(t *testing.T) {
	target := filepath.Join(downloadTestRoot, "header-token.mp4")
	if err := os.WriteFile(target, []byte("ok"), 0o600); err != nil {
		t.Fatalf("写入测试文件: %v", err)
	}
	cases := map[string]http.Header{
		"authorization": {"Authorization": []string{"Bearer " + testToken}},
		"custom header": {"X-Nexmem-Token": []string{testToken}},
	}
	for name, headers := range cases {
		t.Run(name, func(t *testing.T) {
			resp := downloadRawRequest(t, http.MethodGet, url.Values{
				"path": []string{target},
			}, headers)
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("header token 应 200，实际 %d", resp.StatusCode)
			}
		})
	}
}
