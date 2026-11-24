// Package contract 是跨端契约测试的 Go 侧驱动器（X-03）。
//
// 单一真源是 contract/api.json 与 contract/cases/*.json：同一批 case 既驱动 Go
// 的 gateway.Handle，也驱动 Dart 侧的请求/响应信封编解码，避免两端各写一套断言。
package contract

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/contacts"
	"github.com/nexmem/core/internal/group"
)

// caseFile 是 cases/*.json 的文件结构。
type caseFile struct {
	Version int            `json:"version"`
	Cases   []contractCase `json:"cases"`
}

// contractCase 是一条请求/响应样例。
type contractCase struct {
	ID            string            `json:"id"`
	UnknownMethod bool              `json:"unknown_method"`
	Request       gateway.Request   `json:"request"`
	Expect        caseExpect        `json:"expect"`
	Response      fixtureResponse   `json:"response"`
	DataRequired  []string          `json:"data_required"`
	DataTypes     map[string]string `json:"data_types"`
}

type caseExpect struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

type fixtureResponse struct {
	OK    bool           `json:"ok"`
	Data  map[string]any `json:"data"`
	Error *gateway.Error `json:"error"`
}

// apiContract 仅取出校验需要的字段。
type apiContract struct {
	Methods []struct {
		Name string `json:"name"`
	} `json:"methods"`
	Errors []gateway.ErrorSpec `json:"errors"`
}

func loadCases(t *testing.T) []contractCase {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join("cases", "*.json"))
	if err != nil {
		t.Fatalf("枚举 case 文件失败: %v", err)
	}
	if len(paths) == 0 {
		t.Fatal("cases/ 下没有任何用例文件")
	}
	sort.Strings(paths)

	var out []contractCase
	seen := make(map[string]string)
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", path, err)
		}
		var file caseFile
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.UseNumber()
		if err := dec.Decode(&file); err != nil {
			t.Fatalf("解析 %s 失败: %v", path, err)
		}
		if file.Version != 1 {
			t.Fatalf("%s 的 version=%d，期望 1", path, file.Version)
		}
		for _, c := range file.Cases {
			if c.ID == "" {
				t.Fatalf("%s 中存在缺少 id 的用例", path)
			}
			if prev, ok := seen[c.ID]; ok {
				t.Fatalf("用例 id 重复: %s（%s 与 %s）", c.ID, prev, path)
			}
			seen[c.ID] = path
			if c.Request.Method == "" {
				t.Fatalf("用例 %s 缺少 request.method", c.ID)
			}
			if c.Expect.OK == (c.Expect.Error != "") {
				t.Fatalf("用例 %s 的 expect 必须且只能指定 ok 或 error 之一", c.ID)
			}
			out = append(out, c)
		}
	}
	return out
}

func loadAPI(t *testing.T) apiContract {
	t.Helper()
	raw, err := os.ReadFile("api.json")
	if err != nil {
		t.Fatalf("读取 api.json 失败: %v", err)
	}
	var api apiContract
	if err := json.Unmarshal(raw, &api); err != nil {
		t.Fatalf("解析 api.json 失败: %v", err)
	}
	if len(api.Methods) == 0 || len(api.Errors) == 0 {
		t.Fatal("api.json 缺少 methods 或 errors")
	}
	return api
}

// TestContractCasesAgainstGateway 逐条回放用例，校验 gateway 的实际输出。
func TestContractCasesAgainstGateway(t *testing.T) {
	cases := loadCases(t)
	api := loadAPI(t)

	methods := make(map[string]bool, len(api.Methods))
	for _, m := range api.Methods {
		methods[m.Name] = true
	}
	errorSpecs := make(map[gateway.ErrorCode]gateway.ErrorSpec, len(api.Errors))
	for _, e := range api.Errors {
		errorSpecs[e.Code] = e
	}

	g := gateway.New()
	registerContractDoubles(t, g)
	for _, c := range cases {
		c := c
		t.Run(c.ID, func(t *testing.T) {
			// 用例本身与契约文件必须自洽。
			if c.UnknownMethod {
				if methods[c.Request.Method] {
					t.Fatalf("标了 unknown_method，但 %s 已存在于契约中", c.Request.Method)
				}
			} else if !methods[c.Request.Method] {
				t.Fatalf("case 使用的方法 %s 不在 contract/api.json 中", c.Request.Method)
			}
			if !c.Expect.OK {
				spec, ok := errorSpecs[gateway.ErrorCode(c.Expect.Error)]
				if !ok {
					t.Fatalf("期望的错误码 %s 不在契约错误码集合中", c.Expect.Error)
				}
				if c.Response.Error == nil || string(c.Response.Error.Code) != c.Expect.Error {
					t.Fatalf("用例自带的 response.error 与 expect.error 不一致")
				}
				if c.Response.Error.Retryable != spec.Retryable {
					t.Fatalf("用例自带的 retryable=%v 与契约 %v 不一致", c.Response.Error.Retryable, spec.Retryable)
				}
			} else {
				if c.Response.Error != nil || !c.Response.OK {
					t.Fatalf("ok 用例的 response 样例必须是成功响应")
				}
				if err := checkData(c.Response.Data, c.DataRequired, c.DataTypes); err != nil {
					t.Fatalf("用例自带的 response.data 与 data_types 不一致: %v", err)
				}
			}

			// 回放请求。
			req, err := json.Marshal(c.Request)
			if err != nil {
				t.Fatalf("序列化请求失败: %v", err)
			}
			res := decodeResponse(t, g.Serve(context.Background(), req))
			if res.ID != c.Request.ID {
				t.Fatalf("响应 id=%d 未回显请求 id=%d", res.ID, c.Request.ID)
			}
			if c.Expect.OK {
				if !res.OK {
					t.Fatalf("期望成功，实际失败: %+v", res.Error)
				}
				if res.Error != nil {
					t.Fatalf("成功响应不应带 error: %+v", res.Error)
				}
				if err := checkData(res.Data, c.DataRequired, c.DataTypes); err != nil {
					t.Fatalf("响应 data 不符合契约: %v", err)
				}
				return
			}
			if res.OK || res.Error == nil {
				t.Fatalf("期望错误 %s，实际成功: %+v", c.Expect.Error, res.Data)
			}
			if string(res.Error.Code) != c.Expect.Error {
				t.Fatalf("错误码=%s，期望 %s", res.Error.Code, c.Expect.Error)
			}
			if res.Error.Retryable != errorSpecs[res.Error.Code].Retryable {
				t.Fatalf("错误码 %s 的 retryable=%v 与契约不一致", res.Error.Code, res.Error.Retryable)
			}
			if strings.TrimSpace(res.Error.Message) == "" {
				t.Fatalf("错误响应必须带可读 message")
			}
		})
	}
}

type decodedResponse struct {
	ID    uint64         `json:"id"`
	OK    bool           `json:"ok"`
	Data  map[string]any `json:"data"`
	Error *gateway.Error `json:"error"`
}

// contractNonAdminGroupID 是权限用例约定的群 ID，契约层处理器据此模拟非管理员。
const contractNonAdminGroupID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

// registerContractDoubles 为依赖内核装配的方法补上契约层最小处理器。
//
// 裸 gateway.New() 没有群服务，但契约仍需要固定参数与权限的错误码语义；
// 真实实现由 group 包单测与 coreapp 集成测试覆盖。
func registerContractDoubles(t *testing.T, g *gateway.Gateway) {
	t.Helper()
	err := g.SetHandler("group.setAnnouncement",
		func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
			var req struct {
				GroupID      string `json:"group_id"`
				Announcement string `json:"announcement"`
			}
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"group.setAnnouncement 参数不是合法 JSON: %v", err)
			}
			if err := group.ValidateAnnouncement(req.Announcement); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "%v", err)
			}
			if req.GroupID == contractNonAdminGroupID {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "仅群管理员可设置群公告")
			}
			return map[string]any{"announcement": req.Announcement}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 group.setAnnouncement: %v", err)
	}
	err = g.SetHandler("group.setAllowFriendAdd",
		func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
			var req struct {
				GroupID string `json:"group_id"`
				Enabled *bool  `json:"enabled"`
			}
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"group.setAllowFriendAdd 参数不是合法 JSON: %v", err)
			}
			if req.Enabled == nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 enabled")
			}
			if req.GroupID == contractNonAdminGroupID {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "仅群管理员可设置加好友权限")
			}
			return map[string]any{"enabled": *req.Enabled}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 group.setAllowFriendAdd: %v", err)
	}
	err = g.SetHandler("group.setAlias",
		func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
			var req struct {
				GroupID string `json:"group_id"`
				Alias   string `json:"alias"`
			}
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"group.setAlias 参数不是合法 JSON: %v", err)
			}
			if err := group.ValidateGroupAlias(strings.TrimSpace(req.Alias)); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "%v", err)
			}
			return map[string]any{"alias": req.Alias}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 group.setAlias: %v", err)
	}
	err = g.SetHandler("contact.setGroup",
		func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
			var req struct {
				Peer  string `json:"peer"`
				Group string `json:"group"`
			}
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"contact.setGroup 参数不是合法 JSON: %v", err)
			}
			if err := contacts.ValidateContactGroup(strings.TrimSpace(req.Group)); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "%v", err)
			}
			return map[string]any{"group": strings.TrimSpace(req.Group)}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 contact.setGroup: %v", err)
	}
	// account.qrParse 的契约层最小处理器：只校验必填参数与错误码语义。
	// 真实编解码与验签由 coreapp 与 qrshare 包单测覆盖。
	err = g.SetHandler("account.qrParse",
		func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
			var req struct {
				Payload string `json:"payload"`
			}
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"account.qrParse 参数不是合法 JSON: %v", err)
			}
			if req.Payload == "" {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"account.qrParse 缺少必填参数 payload")
			}
			return map[string]any{"account_id": strings.Repeat("ab", 32)}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 account.qrParse: %v", err)
	}
	// account.qrPayload 的契约层最小处理器：返回占位名片字段，真实签名由内核装配。
	err = g.SetHandler("account.qrPayload",
		func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
			return map[string]any{
				"payload":    "nexmem://add/placeholder",
				"account_id": strings.Repeat("ab", 32),
			}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 account.qrPayload: %v", err)
	}
	// 设置快照导出/导入的契约层最小处理器：只校验参数与错误码语义。
	err = g.SetHandler("settings.exportSnapshot",
		func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
			return map[string]any{"snapshot": "settings://v1/placeholder", "count": 0}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 settings.exportSnapshot: %v", err)
	}
	err = g.SetHandler("settings.importSnapshot",
		func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
			var req struct {
				Snapshot string `json:"snapshot"`
			}
			if err := json.Unmarshal(params, &req); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"settings.importSnapshot 参数不是合法 JSON: %v", err)
			}
			if req.Snapshot == "" {
				return nil, gateway.NewError(gateway.CodeInvalidArg,
					"缺少必填参数 snapshot")
			}
			return map[string]any{"applied": 0, "dry_run": false}, nil
		})
	if err != nil {
		t.Fatalf("注册契约处理器 settings.importSnapshot: %v", err)
	}
}

// TestEveryContractMethodHasCase 保证契约里的每个方法都至少被一条用例覆盖。
// 新增方法时若只改 api.json 而漏掉用例，跨端一致性校验会静默失守，这里直接拦住。
func TestEveryContractMethodHasCase(t *testing.T) {
	cases := loadCases(t)
	api := loadAPI(t)

	covered := make(map[string]bool, len(cases))
	for _, c := range cases {
		covered[c.Request.Method] = true
	}
	var missing []string
	for _, m := range api.Methods {
		if !covered[m.Name] {
			missing = append(missing, m.Name)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Fatalf("以下方法缺少契约用例: %s", strings.Join(missing, ", "))
	}
}

func decodeResponse(t *testing.T, raw []byte) decodedResponse {
	t.Helper()
	var res decodedResponse
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&res); err != nil {
		t.Fatalf("解析响应失败: %v（%s）", err, raw)
	}
	return res
}

// checkData 校验必填字段与字段类型；类型名与 Dart 侧保持一致。
func checkData(data map[string]any, required []string, types map[string]string) error {
	for _, name := range required {
		if _, ok := data[name]; !ok {
			return fmt.Errorf("缺少字段 %s", name)
		}
	}
	for name, want := range types {
		value, ok := data[name]
		if !ok {
			return fmt.Errorf("缺少字段 %s", name)
		}
		if err := checkType(value, want); err != nil {
			return fmt.Errorf("字段 %s: %w", name, err)
		}
	}
	return nil
}

func checkType(value any, want string) error {
	switch want {
	case "bool":
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("期望 bool，实际 %T", value)
		}
	case "int":
		num, ok := value.(json.Number)
		if !ok {
			return fmt.Errorf("期望 int，实际 %T", value)
		}
		if _, err := num.Int64(); err != nil {
			return fmt.Errorf("期望 int，实际 %s", num)
		}
	case "number":
		if _, ok := value.(json.Number); !ok {
			return fmt.Errorf("期望 number，实际 %T", value)
		}
	case "string":
		if _, ok := value.(string); !ok {
			return fmt.Errorf("期望 string，实际 %T", value)
		}
	case "array":
		if _, ok := value.([]any); !ok {
			return fmt.Errorf("期望 array，实际 %T", value)
		}
	case "object":
		if _, ok := value.(map[string]any); !ok {
			return fmt.Errorf("期望 object，实际 %T", value)
		}
	default:
		return fmt.Errorf("未知类型名 %q", want)
	}
	return nil
}
