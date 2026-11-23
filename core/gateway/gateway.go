// Package gateway 是六端共用的语义层：统一完成 Request → Response 分发与参数校验，
// 移动端（gomobile）与桌面端（c-shared）只负责字节搬运，不复制业务逻辑。
package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
)

// HandlerFunc 处理单个方法。返回 (data, nil) 表示成功，返回 (nil, err) 表示业务失败。
type HandlerFunc func(ctx context.Context, params json.RawMessage) (any, *Error)

// Definition 是方法的完整定义：契约 schema + 实现（Handler 为 nil 表示尚未接入）。
type Definition struct {
	Name    string
	Summary string
	Params  json.RawMessage
	Result  json.RawMessage
	Handler HandlerFunc
}

// MethodInfo 是方法注册表对外暴露的只读视图，也是契约文件的生成来源。
type MethodInfo struct {
	Name        string          `json:"name"`
	Summary     string          `json:"summary"`
	Params      json.RawMessage `json:"params"`
	Result      json.RawMessage `json:"result"`
	Implemented bool            `json:"implemented"`
}

// Gateway 持有全部方法定义，是并发安全的。
type Gateway struct {
	mu      sync.RWMutex
	methods map[string]*Definition
}

// New 创建注册表并装入内置方法定义。
func New() *Gateway {
	g := &Gateway{methods: make(map[string]*Definition)}
	g.mustRegister(builtinDefinitions(g)...)
	return g
}

// Register 注册方法；重名、schema 缺失或非法都会返回错误。
func (g *Gateway) Register(def Definition) error {
	if def.Name == "" {
		return fmt.Errorf("方法名不能为空")
	}
	params, err := parseSchema(def.Params)
	if err != nil {
		return fmt.Errorf("方法 %s params: %w", def.Name, err)
	}
	if params.Type != "object" {
		return fmt.Errorf("方法 %s params schema 顶层必须是 object", def.Name)
	}
	if err := validateSchemaNode(params, "params"); err != nil {
		return fmt.Errorf("方法 %s params: %w", def.Name, err)
	}
	result, err := parseSchema(def.Result)
	if err != nil {
		return fmt.Errorf("方法 %s result: %w", def.Name, err)
	}
	if err := validateSchemaNode(result, "result"); err != nil {
		return fmt.Errorf("方法 %s result: %w", def.Name, err)
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	if _, exists := g.methods[def.Name]; exists {
		return fmt.Errorf("方法 %s 重复注册", def.Name)
	}
	copied := def
	copied.Params = cloneRaw(def.Params)
	copied.Result = cloneRaw(def.Result)
	g.methods[def.Name] = &copied
	return nil
}

func (g *Gateway) mustRegister(defs ...Definition) {
	for _, def := range defs {
		if err := g.Register(def); err != nil {
			panic("gateway: " + err.Error())
		}
	}
}

// Methods 按名称字典序返回已注册方法，调用方可以安全修改返回的切片。
func (g *Gateway) Methods() []MethodInfo {
	g.mu.RLock()
	defer g.mu.RUnlock()
	out := make([]MethodInfo, 0, len(g.methods))
	for _, def := range g.methods {
		out = append(out, MethodInfo{
			Name:        def.Name,
			Summary:     def.Summary,
			Params:      cloneRaw(def.Params),
			Result:      cloneRaw(def.Result),
			Implemented: def.Handler != nil,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Lookup 返回方法定义，未知方法返回 nil。
func (g *Gateway) Lookup(method string) *Definition {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.methods[method]
}

// SetHandler 把已注册方法接入实现，供运行期装配（如 core.start）使用；
// 方法未注册或 handler 为空时返回错误，方法 schema 不受影响。
func (g *Gateway) SetHandler(method string, h HandlerFunc) error {
	if h == nil {
		return fmt.Errorf("方法 %s 的 handler 不能为空", method)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	def, ok := g.methods[method]
	if !ok {
		return fmt.Errorf("方法 %s 未注册", method)
	}
	def.Handler = h
	return nil
}

// Handle 按方法名分发请求：未知方法返回 INVALID_ARG，参数不合法返回 INVALID_ARG，
// 方法已定义但未接入实现返回 NOT_STARTED。
func (g *Gateway) Handle(ctx context.Context, method string, params json.RawMessage) (any, *Error) {
	if ctx == nil {
		ctx = context.Background()
	}
	g.mu.RLock()
	def := g.methods[method]
	g.mu.RUnlock()
	if def == nil {
		return nil, NewError(CodeInvalidArg, "未知方法 %q", method)
	}
	if err := validateParams(def.Params, params); err != nil {
		return nil, NewError(CodeInvalidArg, "%s 参数不合法: %v", method, err)
	}
	if def.Handler == nil {
		return nil, NewError(CodeNotStarted, "方法 %s 当前阶段尚未接入", method)
	}
	return def.Handler(ctx, params)
}

// Serve 处理一条完整的请求信封并返回响应信封字节。
// 无论请求是否合法都只返回响应，不向调用方抛 error，便于导出层直接回传。
func (g *Gateway) Serve(ctx context.Context, raw []byte) []byte {
	var req Request
	if err := json.Unmarshal(raw, &req); err != nil {
		return encodeResponse(Response{Error: NewError(CodeInvalidArg, "请求不是合法 JSON: %v", err)})
	}
	data, gerr := g.Handle(ctx, req.Method, req.Params)
	if gerr != nil {
		return encodeResponse(Response{ID: req.ID, Error: gerr})
	}
	return encodeResponse(Response{ID: req.ID, OK: true, Data: data})
}

// implementedMethods 供 core.info 上报当前可用能力。
func (g *Gateway) implementedMethods() []string {
	methods := g.Methods()
	out := make([]string, 0, len(methods))
	for _, m := range methods {
		if m.Implemented {
			out = append(out, m.Name)
		}
	}
	return out
}

func cloneRaw(raw json.RawMessage) json.RawMessage {
	if raw == nil {
		return nil
	}
	return append(json.RawMessage(nil), raw...)
}
