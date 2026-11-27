package gateway

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func mustServe(t *testing.T, g *Gateway, raw string) map[string]any {
	t.Helper()
	var resp map[string]any
	if err := json.Unmarshal(g.Serve(context.Background(), []byte(raw)), &resp); err != nil {
		t.Fatalf("响应不是合法 JSON: %v", err)
	}
	return resp
}

func errorCode(t *testing.T, resp map[string]any) string {
	t.Helper()
	if ok, _ := resp["ok"].(bool); ok {
		t.Fatalf("期望失败响应，实际 ok=true: %v", resp)
	}
	errObj, _ := resp["error"].(map[string]any)
	code, _ := errObj["code"].(string)
	if code == "" {
		t.Fatalf("响应缺少 error.code: %v", resp)
	}
	return code
}

func TestMethodsHaveSchema(t *testing.T) {
	g := New()
	methods := g.Methods()
	if len(methods) != 97 {
		t.Fatalf("契约方法数 = %d，期望 97", len(methods))
	}
	prev := ""
	for _, m := range methods {
		if m.Name <= prev {
			t.Fatalf("方法未按名称排序: %q 在 %q 之后", m.Name, prev)
		}
		prev = m.Name
		if m.Summary == "" {
			t.Fatalf("方法 %s 缺少说明", m.Name)
		}
		var params map[string]any
		if err := json.Unmarshal(m.Params, &params); err != nil {
			t.Fatalf("方法 %s params schema 非法: %v", m.Name, err)
		}
		if params["type"] != "object" {
			t.Fatalf("方法 %s params schema 顶层必须是 object: %s", m.Name, m.Params)
		}
		var result map[string]any
		if err := json.Unmarshal(m.Result, &result); err != nil {
			t.Fatalf("方法 %s result schema 非法: %v", m.Name, err)
		}
	}
}

func TestUnknownMethodReturnsInvalidArg(t *testing.T) {
	g := New()
	if _, err := g.Handle(context.Background(), "dm.nope", nil); err == nil || err.Code != CodeInvalidArg {
		t.Fatalf("未知方法应返回 INVALID_ARG，实际 %v", err)
	}
	resp := mustServe(t, g, `{"id":9,"method":"dm.nope"}`)
	if code := errorCode(t, resp); code != string(CodeInvalidArg) {
		t.Fatalf("未知方法错误码 = %s，期望 INVALID_ARG", code)
	}
	if id, _ := resp["id"].(float64); id != 9 {
		t.Fatalf("响应未回显 id: %v", resp)
	}
}

func TestInvalidParams(t *testing.T) {
	g := New()
	cases := map[string]string{
		"缺少必填参数":     `{"id":1,"method":"dm.sendText","params":{"peer":"p"}}`,
		"参数类型错误":     `{"id":1,"method":"dm.sendText","params":{"peer":"p","text":123}}`,
		"params 非对象": `{"id":1,"method":"dm.sendText","params":[]}`,
		"必填参数为 null": `{"id":1,"method":"dm.sendText","params":{"peer":null,"text":"hi"}}`,
		"数值越界":       `{"id":1,"method":"msg.list","params":{"conversation_id":"c","limit":0}}`,
		"数组元素类型错误":   `{"id":1,"method":"group.create","params":{"title":"t","members":[1,2]}}`,
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			resp := mustServe(t, g, raw)
			if code := errorCode(t, resp); code != string(CodeInvalidArg) {
				t.Fatalf("错误码 = %s，期望 INVALID_ARG", code)
			}
		})
	}
}

// TestMessageTextMaxLength 校验聊天正文在契约层统一受限 4096 字符，
// 与 settings value 的 4 KiB 上限思路一致，避免超长请求进入业务层。
func TestMessageTextMaxLength(t *testing.T) {
	g := New()
	methods := []string{"dm.sendText", "dm.sendGroupText", "msg.edit"}
	for _, method := range methods {
		t.Run(method+"-overlong", func(t *testing.T) {
			req := map[string]any{
				"id":     1,
				"method": method,
				"params": map[string]any{
					"peer":            "p",
					"group_id":        "g",
					"conversation_id": "c",
					"msg_uuid":        "u",
					"text":            strings.Repeat("字", 4097),
				},
			}
			raw, err := json.Marshal(req)
			if err != nil {
				t.Fatalf("序列化请求: %v", err)
			}
			if code := errorCode(t, mustServe(t, g, string(raw))); code != string(CodeInvalidArg) {
				t.Fatalf("超长正文错误码 = %s，期望 INVALID_ARG", code)
			}
		})
		t.Run(method+"-boundary", func(t *testing.T) {
			req := map[string]any{
				"id":     1,
				"method": method,
				"params": map[string]any{
					"peer":            "p",
					"group_id":        "g",
					"conversation_id": "c",
					"msg_uuid":        "u",
					"text":            strings.Repeat("字", 4096),
				},
			}
			raw, err := json.Marshal(req)
			if err != nil {
				t.Fatalf("序列化请求: %v", err)
			}
			// 裸 Gateway 没有业务 handler，合法参数应走到 NOT_STARTED 而非 INVALID_ARG。
			if code := errorCode(t, mustServe(t, g, string(raw))); code != string(CodeNotStarted) {
				t.Fatalf("边界正文错误码 = %s，期望 NOT_STARTED", code)
			}
		})
	}
}

func TestSchemaOnlyMethodReturnsNotStarted(t *testing.T) {
	g := New()
	_, err := g.Handle(context.Background(), "core.stop", nil)
	if err == nil || err.Code != CodeNotStarted {
		t.Fatalf("未接入方法应返回 NOT_STARTED，实际 %v", err)
	}
}

func TestCoreInfo(t *testing.T) {
	g := New()
	var resp struct {
		ID   uint64 `json:"id"`
		OK   bool   `json:"ok"`
		Data struct {
			APIVersion  string   `json:"api_version"`
			CoreVersion string   `json:"core_version"`
			Features    []string `json:"features"`
		} `json:"data"`
	}
	if err := json.Unmarshal(g.Serve(context.Background(), []byte(`{"id":7,"method":"core.info","params":null}`)), &resp); err != nil {
		t.Fatalf("解析响应: %v", err)
	}
	if resp.ID != 7 || !resp.OK {
		t.Fatalf("core.info 响应异常: %+v", resp)
	}
	if resp.Data.APIVersion != APIVersion || resp.Data.CoreVersion != CoreVersion {
		t.Fatalf("版本信息不符: %+v", resp.Data)
	}
	if len(resp.Data.Features) != 2 || resp.Data.Features[0] != "core.info" || resp.Data.Features[1] != "core.ping" {
		t.Fatalf("已接入能力 = %v，期望 core.info 与 core.ping", resp.Data.Features)
	}
}

func TestCorePing(t *testing.T) {
	resp := mustServe(t, New(), `{"id":3,"method":"core.ping"}`)
	if ok, _ := resp["ok"].(bool); !ok {
		t.Fatalf("core.ping 应成功: %v", resp)
	}
	data, _ := resp["data"].(map[string]any)
	if pong, _ := data["pong"].(bool); !pong {
		t.Fatalf("core.ping 未返回 pong=true: %v", data)
	}
	if ts, _ := data["server_ts"].(float64); ts <= 0 {
		t.Fatalf("core.ping 未返回 server_ts: %v", data)
	}
}

func TestSetHandler(t *testing.T) {
	g := New()
	if err := g.SetHandler("dm.sendText", nil); err == nil {
		t.Fatal("空 handler 应报错")
	}
	if err := g.SetHandler("dm.nope", func(context.Context, json.RawMessage) (any, *Error) {
		return nil, nil
	}); err == nil {
		t.Fatal("未注册方法应报错")
	}
	if err := g.SetHandler("dm.sendText", func(ctx context.Context, params json.RawMessage) (any, *Error) {
		return map[string]any{"msg_uuid": "u-1"}, nil
	}); err != nil {
		t.Fatalf("装配 handler: %v", err)
	}
	resp := mustServe(t, g, `{"id":4,"method":"dm.sendText","params":{"peer":"p","text":"hi"}}`)
	data, _ := resp["data"].(map[string]any)
	if data["msg_uuid"] != "u-1" {
		t.Fatalf("装配后未走 handler: %v", resp)
	}
}

func TestServeInvalidJSON(t *testing.T) {
	resp := mustServe(t, New(), `{"id":1,`)
	if code := errorCode(t, resp); code != string(CodeInvalidArg) {
		t.Fatalf("非法 JSON 错误码 = %s，期望 INVALID_ARG", code)
	}
	if id, ok := resp["id"].(float64); ok && id != 0 {
		t.Fatalf("非法 JSON 的响应 id 应为 0，实际 %v", id)
	}
}

func TestRegisterValidation(t *testing.T) {
	g := New()
	validParams := `{"type":"object"}`
	validResult := `{"type":"object"}`
	cases := []struct {
		name string
		def  Definition
	}{
		{"空方法名", Definition{Params: json.RawMessage(validParams), Result: json.RawMessage(validResult)}},
		{"重名", Definition{Name: "core.info", Params: json.RawMessage(validParams), Result: json.RawMessage(validResult)}},
		{"params 非对象", Definition{Name: "x.y", Params: json.RawMessage(`{"type":"string"}`), Result: json.RawMessage(validResult)}},
		{"params 非法 JSON", Definition{Name: "x.y", Params: json.RawMessage(`{`), Result: json.RawMessage(validResult)}},
		{"不支持的类型", Definition{Name: "x.y", Params: json.RawMessage(`{"type":"object","properties":{"a":{"type":"null"}}}`), Result: json.RawMessage(validResult)}},
		{"缺少 result", Definition{Name: "x.y", Params: json.RawMessage(validParams)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := g.Register(tc.def); err == nil {
				t.Fatalf("期望注册失败，实际成功: %+v", tc.def)
			}
		})
	}
}
