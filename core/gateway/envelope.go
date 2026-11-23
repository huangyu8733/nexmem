package gateway

import "encoding/json"

// APIVersion 是 Request/Response/Event 契约版本，出现不兼容变更时递增。
const APIVersion = "1.0.0"

// CoreVersion 是内核实现版本，随发布产物更新。
const CoreVersion = "0.1.0-dev"

// Request 是各端发往内核的请求信封。
type Request struct {
	ID        uint64          `json:"id"`
	Method    string          `json:"method"`
	Params    json.RawMessage `json:"params,omitempty"`
	TimeoutMS int             `json:"timeout_ms,omitempty"`
}

// Response 是内核返回给各端的响应信封。
type Response struct {
	ID    uint64 `json:"id"`
	OK    bool   `json:"ok"`
	Data  any    `json:"data,omitempty"`
	Error *Error `json:"error,omitempty"`
}

// Event 是内核单向推送给各端的事件信封，Seq 由内核全局递增。
type Event struct {
	Seq  uint64          `json:"seq"`
	Type string          `json:"type"`
	TS   int64           `json:"ts"`
	Data json.RawMessage `json:"data,omitempty"`
}

// encodeResponse 序列化响应；序列化失败属于程序错误，降级为 INVALID_ARG 以避免丢包。
func encodeResponse(r Response) []byte {
	b, err := json.Marshal(r)
	if err != nil {
		return []byte(`{"id":0,"ok":false,"error":{"code":"INVALID_ARG","message":"响应序列化失败","retryable":false}}`)
	}
	return b
}
