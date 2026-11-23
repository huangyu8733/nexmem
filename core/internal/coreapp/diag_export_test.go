package coreapp

// P6-06 验收：诊断导出脱敏，不含明文与密钥。
//
// 场景：两个真实装配的内核完成一次直连文本收发后导出诊断包，校验
//   1. 导出文件是逐行合法 JSON，且包含内核生命周期元数据（证明不是空包）；
//   2. 消息明文、账号 X25519 私钥与设备私钥（十六进制/各类 base64）均不出现；
//   3. diag.snapshot 回包只含指标字段，没有任何正文字段名。

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nexmem/core/internal/dm"
)

func TestDiagnosticExportHasNoPlaintextOrKeys(t *testing.T) {
	var (
		mu sync.Mutex
		a  *App
		b  *App
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if a != nil && bytes.Equal(a.Account().Pub(), accountPub) {
			return targetOf(a), nil
		}
		if b != nil && bytes.Equal(b.Account().Pub(), accountPub) {
			return targetOf(b), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	gwA, appA, logA := startApp(t, filepath.Join(t.TempDir(), "a"), resolver)
	gwB, appB, logB := startApp(t, filepath.Join(t.TempDir(), "b"), resolver)
	mu.Lock()
	a, b = appA, appB
	mu.Unlock()

	marker := fmt.Sprintf("P6-DIAG-MARKER-%d", time.Now().UnixNano())
	call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": marker,
	})
	waitFor(t, 10*time.Second, func() bool { return logB.has("message.new") })
	waitFor(t, 10*time.Second, func() bool { return logA.has("message.updated") })

	// 明文确实进入了接收端本地库，确保「诊断包里没有」是有意义的结论。
	conv := dm.ConversationID(appA.Account().Pub(), appB.Account().Pub())
	history, ok := call(t, gwB, "msg.list", map[string]any{
		"conversation_id": conv,
		"limit":           10,
	}).(map[string]any)
	if !ok {
		t.Fatal("msg.list 回包不是对象")
	}
	items := listItems(t, history)
	if len(items) != 1 {
		t.Fatalf("接收端历史条数不符合预期: %v", items)
	}
	first, _ := items[0].(map[string]any)
	if first["text"] != marker {
		t.Fatalf("接收端历史不符合预期: %v", first)
	}

	path := filepath.Join(t.TempDir(), "diagnostics.jsonl")
	out, ok := call(t, gwA, "diag.export", map[string]any{"path": path}).(map[string]any)
	if !ok || out["path"] != path {
		t.Fatalf("diag.export 回包不符合预期: %v", out)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取诊断包: %v", err)
	}
	if len(raw) == 0 {
		t.Fatal("诊断包为空")
	}

	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) == 0 {
		t.Fatal("诊断包没有日志行")
	}
	sawCore := false
	for i, line := range lines {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("第 %d 行不是合法 JSON: %v", i+1, err)
		}
		for _, key := range []string{"ts", "level", "msg"} {
			if _, ok := rec[key]; !ok {
				t.Fatalf("第 %d 行缺少字段 %q: %v", i+1, key, rec)
			}
		}
		if rec["module"] == "core" {
			sawCore = true
		}
	}
	if !sawCore {
		t.Fatal("诊断包缺少内核生命周期日志，导出内容不完整")
	}

	if bytes.Contains(raw, []byte(marker)) {
		t.Fatal("诊断包出现了消息明文")
	}
	secrets := map[string][]byte{
		"账号 X25519 私钥(A)": appA.Account().XPriv(),
		"账号 X25519 私钥(B)": appB.Account().XPriv(),
	}
	deviceRaw, err := appA.devKey.Raw()
	if err != nil {
		t.Fatalf("读取设备私钥: %v", err)
	}
	secrets["设备私钥(A)"] = deviceRaw
	for name, secret := range secrets {
		if len(secret) == 0 {
			t.Fatalf("%s 为空，无法校验", name)
		}
		for _, encoded := range encodeVariants(secret) {
			if bytes.Contains(raw, []byte(encoded)) {
				t.Fatalf("诊断包泄漏了%s（编码形式 %q）", name, encoded)
			}
		}
	}

	snap, ok := call(t, gwA, "diag.snapshot", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("diag.snapshot 回包不是对象")
	}
	for key := range snap {
		if sensitiveFieldName(key) {
			t.Fatalf("diag.snapshot 暴露了敏感字段 %q", key)
		}
	}
	for _, key := range []string{"dht_lookups", "holepunch", "s3_status", "log_records"} {
		if _, ok := snap[key]; !ok {
			t.Fatalf("diag.snapshot 缺少指标字段 %q: %v", key, snap)
		}
	}
}

// encodeVariants 返回密钥可能出现在诊断包中的常见文本编码。
func encodeVariants(secret []byte) []string {
	return []string{
		hex.EncodeToString(secret),
		strings.ToUpper(hex.EncodeToString(secret)),
		base64.StdEncoding.EncodeToString(secret),
		base64.RawStdEncoding.EncodeToString(secret),
		base64.URLEncoding.EncodeToString(secret),
		base64.RawURLEncoding.EncodeToString(secret),
	}
}

// sensitiveFieldName 判定字段名是否会承载正文或凭证。
func sensitiveFieldName(key string) bool {
	k := strings.ToLower(strings.TrimSpace(key))
	switch k {
	case "text", "body", "content", "plaintext", "ak", "sk", "access_key", "secret_key", "private_key", "token":
		return true
	}
	for _, suffix := range []string{"_token", "_secret", "_password", "_key"} {
		if strings.HasSuffix(k, suffix) {
			return true
		}
	}
	return false
}

