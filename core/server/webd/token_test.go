package webd

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nexmem/core/gateway"
)

func writeTokenFile(t *testing.T, dir, content string) string {
	t.Helper()
	path := filepath.Join(dir, "token")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("写入令牌文件: %v", err)
	}
	return path
}

func TestTokenFileLoadAndAuth(t *testing.T) {
	path := writeTokenFile(t, t.TempDir(), "file-token-2026\n")

	_, ts := newServer(t, Config{TokenFile: path})

	conn := mustDial(t, ts, "?token=file-token-2026", nil)
	if resp := roundTrip(t, conn, `{"id":1,"method":"core.ping"}`); resp["ok"] != true {
		t.Fatalf("令牌文件中的令牌应可用: %v", resp)
	}
	if conn, resp, err := dialWS(t, ts, "?token="+testToken, nil); err == nil {
		_ = conn.Close()
		t.Fatal("旧令牌不应被接受")
	} else if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("旧令牌握手状态码 = %v，期望 401", resp)
	}
}

func TestTokenSourceErrors(t *testing.T) {
	if _, err := New(Config{Gateway: gateway.New()}); !errors.Is(err, ErrTokenRequired) {
		t.Fatalf("缺少令牌与令牌文件应返回 ErrTokenRequired，实际 %v", err)
	}

	missing := filepath.Join(t.TempDir(), "absent")
	if _, err := New(Config{TokenFile: missing, Gateway: gateway.New()}); err == nil {
		t.Fatal("令牌文件不存在时应拒绝启动")
	}

	empty := writeTokenFile(t, t.TempDir(), "  \n")
	if _, err := New(Config{TokenFile: empty, Gateway: gateway.New()}); !errors.Is(err, ErrTokenFileEmptyFile) {
		t.Fatalf("空令牌文件应返回 ErrTokenFileEmptyFile，实际 %v", err)
	}
}

func TestReloadTokenFileRotatesAndDropsSessions(t *testing.T) {
	dir := t.TempDir()
	path := writeTokenFile(t, dir, "token-v1")
	srv, ts := newServer(t, Config{TokenFile: path})

	conn := mustDial(t, ts, "?token=token-v1", nil)
	// 握手成功与会话登记之间存在间隙，整包并行执行时会被放大；复用已提供的
	// waitConnections 等待登记完成，避免满载时偶发读到 0 连接（R-21 同类时序）。
	waitConnections(t, srv, 1)

	// 内容未变时不触发轮换
	if changed, err := srv.ReloadTokenFile(); err != nil || changed {
		t.Fatalf("令牌未变时 Reload = (%v, %v)，期望 (false, nil)", changed, err)
	}

	if err := os.WriteFile(path, []byte("token-v2"), 0o600); err != nil {
		t.Fatalf("改写令牌文件: %v", err)
	}
	changed, err := srv.ReloadTokenFile()
	if err != nil || !changed {
		t.Fatalf("令牌变化后 Reload = (%v, %v)，期望 (true, nil)", changed, err)
	}

	// 旧连接被断开，旧令牌不再可用
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("轮换后旧连接应被断开")
	}
	if conn, resp, err := dialWS(t, ts, "?token=token-v1", nil); err == nil {
		_ = conn.Close()
		t.Fatal("旧令牌在轮换后不应被接受")
	} else if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("旧令牌握手状态码 = %v，期望 401", resp)
	}

	newConn := mustDial(t, ts, "?token=token-v2", nil)
	if resp := roundTrip(t, newConn, `{"id":2,"method":"core.ping"}`); resp["ok"] != true {
		t.Fatalf("新令牌应可用: %v", resp)
	}
}

func TestSetTokenValidation(t *testing.T) {
	srv, _ := newServer(t, Config{})
	if _, err := srv.SetToken("   "); !errors.Is(err, ErrTokenRequired) {
		t.Fatalf("空令牌应返回 ErrTokenRequired，实际 %v", err)
	}
	if changed, err := srv.SetToken(testToken); err != nil || changed {
		t.Fatalf("相同令牌 SetToken = (%v, %v)，期望 (false, nil)", changed, err)
	}
	if changed, err := srv.SetToken("rotated-token"); err != nil || !changed {
		t.Fatalf("不同令牌 SetToken = (%v, %v)，期望 (true, nil)", changed, err)
	}

	// 未配置令牌文件时 ReloadTokenFile 明确报错
	if _, err := srv.ReloadTokenFile(); !errors.Is(err, ErrTokenFileEmpty) {
		t.Fatalf("未配置令牌文件应返回 ErrTokenFileEmpty，实际 %v", err)
	}
}
