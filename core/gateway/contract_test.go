package gateway

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestContractFileInSync 保证 core/contract/api.json 与注册表严格一致。
// 修改方法定义后执行：go -C core run ./cmd/nexmem-contract
func TestContractFileInSync(t *testing.T) {
	path := filepath.Join("..", "contract", "api.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取契约文件: %v", err)
	}
	var got Contract
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("契约文件不是合法 JSON: %v", err)
	}
	want := New().Contract()
	if !reflect.DeepEqual(canonical(t, got), canonical(t, want)) {
		t.Fatalf("契约文件与注册表不一致，请执行 go -C core run ./cmd/nexmem-contract 重新生成")
	}
}

func canonical(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("规范化契约: %v", err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("规范化契约: %v", err)
	}
	return out
}
