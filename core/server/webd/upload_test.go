package webd

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func uploadRequest(t *testing.T, root, token string, fields map[string]string, files map[string][]byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for key, value := range fields {
		if err := writer.WriteField(key, value); err != nil {
			t.Fatalf("写入表单字段: %v", err)
		}
	}
	for name, content := range files {
		part, err := writer.CreateFormFile(name, filepath.Base(name))
		if err != nil {
			t.Fatalf("创建上传分片: %v", err)
		}
		if _, err := part.Write(content); err != nil {
			t.Fatalf("写入上传分片: %v", err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("关闭 multipart: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/upload?token="+token, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	rec := httptest.NewRecorder()
	rootHandler := root
	srv, _ := newServer(t, Config{UploadDir: rootHandler})
	srv.Handler().ServeHTTP(rec, req)
	srv.Close()
	return rec
}

func decodeUpload(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if rec.Code != http.StatusOK {
		t.Fatalf("上传状态码 = %d，body=%s", rec.Code, rec.Body.String())
	}
	var data map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &data); err != nil {
		t.Fatalf("上传响应不是 JSON: %v (%s)", err, rec.Body.String())
	}
	return data
}

func TestUploadFileReturnsServerPath(t *testing.T) {
	root := t.TempDir()
	rec := uploadRequest(t, root, testToken, map[string]string{"mode": "file"}, map[string][]byte{
		"file": []byte("nexmem-upload"),
	})
	data := decodeUpload(t, rec)
	gotPath, _ := data["path"].(string)
	name, _ := data["name"].(string)
	size, _ := data["size"].(float64)
	if name != "file" || size != float64(len("nexmem-upload")) {
		t.Fatalf("上传元数据不正确: %v", data)
	}
	raw, err := os.ReadFile(gotPath)
	if err != nil || string(raw) != "nexmem-upload" {
		t.Fatalf("上传文件内容不正确: %q, err=%v", raw, err)
	}
	if filepath.Dir(filepath.Dir(gotPath)) != root {
		t.Fatalf("上传文件未落在上传根目录: %s (root=%s)", gotPath, root)
	}
}

func TestUploadDirectoryPreservesRelativePath(t *testing.T) {
	root := t.TempDir()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("mode", "dir")
	_ = writer.WriteField("relative_path", "photos/a.txt")
	_ = writer.WriteField("relative_path", "docs/b.txt")
	for _, item := range []struct{ name, content string }{
		{"a.txt", "image-bytes"},
		{"b.txt", "doc-bytes"},
	} {
		part, err := writer.CreateFormFile("files", item.name)
		if err != nil {
			t.Fatalf("创建目录分片: %v", err)
		}
		_, _ = part.Write([]byte(item.content))
	}
	_ = writer.Close()

	req := httptest.NewRequest(http.MethodPost, "/upload?token="+testToken, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	srv, _ := newServer(t, Config{UploadDir: root})
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	srv.Close()

	data := decodeUpload(t, rec)
	dir, _ := data["path"].(string)
	for rel, want := range map[string]string{
		"photos/a.txt": "image-bytes",
		"docs/b.txt":   "doc-bytes",
	} {
		raw, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil || string(raw) != want {
			t.Fatalf("目录文件 %s 不正确: %q, err=%v", rel, raw, err)
		}
	}
}

func TestUploadDirectoryAcceptsRelativePathParts(t *testing.T) {
	root := t.TempDir()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("mode", "dir")
	for _, item := range []struct{ rel, content string }{
		{"photos/a.txt", "image-bytes"},
		{"docs/b.txt", "doc-bytes"},
	} {
		relPart, err := writer.CreateFormFile("relative_path", "relative_path")
		if err != nil {
			t.Fatalf("创建相对路径分片: %v", err)
		}
		_, _ = relPart.Write([]byte(item.rel))
		filePart, err := writer.CreateFormFile("files", filepath.Base(item.rel))
		if err != nil {
			t.Fatalf("创建文件分片: %v", err)
		}
		_, _ = filePart.Write([]byte(item.content))
	}
	_ = writer.Close()

	req := httptest.NewRequest(http.MethodPost, "/upload?token="+testToken, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	srv, _ := newServer(t, Config{UploadDir: root})
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	srv.Close()

	data := decodeUpload(t, rec)
	dir, _ := data["path"].(string)
	for rel, want := range map[string]string{
		"photos/a.txt": "image-bytes",
		"docs/b.txt":   "doc-bytes",
	} {
		raw, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil || string(raw) != want {
			t.Fatalf("目录分片 %s 不正确: %q, err=%v", rel, raw, err)
		}
	}
}

func TestUploadRejectsBadTokenAndTraversal(t *testing.T) {
	root := t.TempDir()
	rec := uploadRequest(t, root, "wrong", map[string]string{"mode": "file"}, map[string][]byte{
		"file": []byte("nope"),
	})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("错误令牌应返回 401，实际 %d", rec.Code)
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("mode", "dir")
	_ = writer.WriteField("relative_path", "../escape.txt")
	part, _ := writer.CreateFormFile("files", "escape.txt")
	_, _ = part.Write([]byte("bad"))
	_ = writer.Close()
	req := httptest.NewRequest(http.MethodPost, "/upload?token="+testToken, &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	srv, _ := newServer(t, Config{UploadDir: root})
	rec = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	srv.Close()
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("路径穿越应返回 400，实际 %d: %s", rec.Code, rec.Body.String())
	}
}
