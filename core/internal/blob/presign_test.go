package blob

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPutPresignedSuccess(t *testing.T) {
	var gotBody []byte
	var gotMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	payload := []byte("offline-ciphertext")
	if err := PutPresigned(context.Background(), srv.Client(), srv.URL+"/obj?X-Amz-Signature=sig", payload); err != nil {
		t.Fatalf("上传应成功: %v", err)
	}
	if gotMethod != http.MethodPut {
		t.Fatalf("方法 %s，期望 PUT", gotMethod)
	}
	if string(gotBody) != string(payload) {
		t.Fatalf("请求体 %q，期望 %q", gotBody, payload)
	}
}

func TestPutPresignedErrors(t *testing.T) {
	cases := []struct {
		status int
		want   error
	}{
		{http.StatusForbidden, ErrAuth},
		{http.StatusNotFound, ErrNotFound},
		{http.StatusTooManyRequests, ErrQuota},
		{http.StatusInternalServerError, ErrIO},
	}
	for _, c := range cases {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(c.status)
		}))
		err := PutPresigned(context.Background(), srv.Client(), srv.URL+"/obj?X-Amz-Signature=sig", []byte("x"))
		srv.Close()
		if !errors.Is(err, c.want) {
			t.Fatalf("状态 %d 应返回 %v，实际 %v", c.status, c.want, err)
		}
	}
}

func TestPutPresignedRejectsInvalidURL(t *testing.T) {
	if err := PutPresigned(context.Background(), nil, "ftp://host/obj?X-Amz-Signature=sig", []byte("x")); !errors.Is(err, ErrInvalidTicket) {
		t.Fatalf("非法协议应返回 ErrInvalidTicket，实际 %v", err)
	}
	if err := PutPresigned(context.Background(), nil, "https://host/obj", []byte("x")); !errors.Is(err, ErrInvalidTicket) {
		t.Fatalf("缺少签名应返回 ErrInvalidTicket，实际 %v", err)
	}
}
