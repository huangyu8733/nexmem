package gateway

import "encoding/json"

// Contract 是 contract/api.json 的结构，也是六端对齐的唯一契约描述。
type Contract struct {
	APIVersion string          `json:"api_version"`
	Envelope   json.RawMessage `json:"envelope"`
	Errors     []ErrorSpec     `json:"errors"`
	Methods    []MethodInfo    `json:"methods"`
	Events     []EventSpec     `json:"events"`
}

// ErrorSpec 描述一个错误码及其是否可重试。
type ErrorSpec struct {
	Code        ErrorCode `json:"code"`
	Retryable   bool      `json:"retryable"`
	Description string    `json:"description"`
}

// EventSpec 描述一个单向事件及其 data schema。
type EventSpec struct {
	Type        string          `json:"type"`
	Description string          `json:"description"`
	Data        json.RawMessage `json:"data"`
}

// envelopeSpec 来自 docs/Nexmem-engineering-plan.md §6.2 的三种信封示例。
var envelopeSpec = json.RawMessage(`{
  "request": {"id": 1024, "method": "dm.sendText", "params": {"peer": "12D3Koo...", "text": "hi"}, "timeout_ms": 15000},
  "response_ok": {"id": 1024, "ok": true, "data": {"msg_uuid": "0192f3..."}},
  "response_error": {"id": 1024, "ok": false, "error": {"code": "PEER_UNREACHABLE", "message": "打洞与中继均失败", "retryable": true}},
  "event": {"seq": 87, "type": "message.new", "ts": 1730000000000, "data": {"conversation_id": "dm:...", "msg_uuid": "..."}}
}`)

// Contract 汇总当前注册表与固定错误码/事件，用于生成契约文件。
func (g *Gateway) Contract() Contract {
	errs := make([]ErrorSpec, 0, len(errorCodeOrder))
	for _, code := range errorCodeOrder {
		errs = append(errs, ErrorSpec{
			Code:        code,
			Retryable:   retryable[code],
			Description: errorDescription[code],
		})
	}
	return Contract{
		APIVersion: APIVersion,
		Envelope:   cloneRaw(envelopeSpec),
		Errors:     errs,
		Methods:    g.Methods(),
		Events:     eventSpecs(),
	}
}

// ContractJSON 输出缩进后的契约 JSON，供 cmd/nexmem-contract 落盘。
func (g *Gateway) ContractJSON() ([]byte, error) {
	return json.MarshalIndent(g.Contract(), "", "  ")
}

func eventSpecs() []EventSpec {
	return []EventSpec{
		{
			Type:        "state.changed",
			Description: "内核连接状态变化",
			Data:        json.RawMessage(`{"type":"object","properties":{"state":{"type":"string","enum":["init","starting","online","degraded","offline","stopped"]}},"required":["state"]}`),
		},
		{
			Type:        "message.new",
			Description: "新消息入库，只给指针，正文由 msg.listSince 拉取",
			Data:        json.RawMessage(`{"type":"object","properties":{"conversation_id":{"type":"string"},"msg_uuid":{"type":"string"},"direction":{"type":"string","enum":["in","out"]}},"required":["conversation_id","msg_uuid"]}`),
		},
		{
			Type:        "message.updated",
			Description: "消息发送状态变化；read 由对端已读回执推进，reason 仅确定性失败时出现（如 OFFLINE_STORAGE_DISABLED）",
			Data:        json.RawMessage(`{"type":"object","properties":{"conversation_id":{"type":"string"},"msg_uuid":{"type":"string"},"state":{"type":"string","enum":["pending","sent","acked","failed","received","read"]},"offline":{"type":"boolean"},"reason":{"type":"string"}},"required":["msg_uuid","state"]}`),
		},
		{
			Type:        "message.recalled",
			Description: "消息被本机或对端撤回，客户端按 msg_uuid 移除气泡",
			Data:        json.RawMessage(`{"type":"object","properties":{"conversation_id":{"type":"string"},"msg_uuid":{"type":"string"}},"required":["conversation_id","msg_uuid"]}`),
		},
		{
			Type:        "message.edited",
			Description: "消息正文被本机或对端编辑，客户端按 msg_uuid 更新气泡并标记「已编辑」",
			Data:        json.RawMessage(`{"type":"object","properties":{"conversation_id":{"type":"string"},"msg_uuid":{"type":"string"},"text":{"type":"string"},"edited_at":{"type":"integer"}},"required":["conversation_id","msg_uuid","text"]}`),
		},
		{
			Type:        "message.expired",
			Description: "定时消息到期被本机物理销毁，客户端按 msg_uuid 移除气泡（双方各自触发）",
			Data:        json.RawMessage(`{"type":"object","properties":{"conversation_id":{"type":"string"},"msg_uuid":{"type":"string"}},"required":["conversation_id","msg_uuid"]}`),
		},
		{
			Type:        "typing",
			Description: "对端单聊输入状态变化（瞬时，不落库）；typing=false 表示停止输入",
			Data:        json.RawMessage(`{"type":"object","properties":{"peer":{"type":"string"},"typing":{"type":"boolean"}},"required":["peer","typing"]}`),
		},
		{
			Type:        "conversation.changed",
			Description: "未读数或标题变化，100ms 合并",
			Data:        json.RawMessage(`{"type":"object","properties":{"conversation_ids":{"type":"array","items":{"type":"string"}}},"required":["conversation_ids"]}`),
		},
		{
			Type:        "ack",
			Description: "应用层回执",
			Data:        json.RawMessage(`{"type":"object","properties":{"msg_uuid":{"type":"string"},"code":{"type":"integer"}},"required":["msg_uuid","code"]}`),
		},
		{
			Type:        "transfer.progress",
			Description: "文件传输进度，200ms 节流",
			Data:        json.RawMessage(`{"type":"object","properties":{"msg_uuid":{"type":"string"},"done":{"type":"integer"},"total":{"type":"integer"}},"required":["msg_uuid","done","total"]}`),
		},
		{
			Type:        "fs.progress",
			Description: "P2P 文件共享下载进度，200ms 节流，done==total 表示完成",
			Data:        json.RawMessage(`{"type":"object","properties":{"share_id":{"type":"string"},"path":{"type":"string"},"done":{"type":"integer"},"total":{"type":"integer"}},"required":["share_id","done","total"]}`),
		},
		{
			Type:        "rtc.signal",
			Description: "对端 RTC 信令",
			Data:        json.RawMessage(`{"type":"object","properties":{"peer":{"type":"string"},"payload_b64":{"type":"string"}},"required":["peer","payload_b64"]}`),
		},
		{
			Type:        "error",
			Description: "非请求上下文的异步错误",
			Data:        json.RawMessage(`{"type":"object","properties":{"code":{"type":"string"},"message":{"type":"string"},"retryable":{"type":"boolean"}},"required":["code","message","retryable"]}`),
		},
		{
			Type:        "resync_required",
			Description: "事件缺口或缓冲溢出，需要全量重同步",
			Data:        json.RawMessage(`{"type":"object","properties":{"reason":{"type":"string"}},"required":["reason"]}`),
		},
		{
			Type:        "group.dissolved",
			Description: "群被管理员解散，成员按 group_id 清理本机群状态（不产生气泡）",
			Data:        json.RawMessage(`{"type":"object","properties":{"conversation_id":{"type":"string"},"group_id":{"type":"string"}},"required":["group_id"]}`),
		},
		{
			Type:        "group.announcement",
			Description: "管理员更新群公告，成员按 group_id 刷新本机公告（不产生气泡）",
			Data:        json.RawMessage(`{"type":"object","properties":{"group_id":{"type":"string"},"announcement":{"type":"string"}},"required":["group_id","announcement"]}`),
		},
		{
			Type:        "group.storageRemoved",
			Description: "管理员移除群盘，成员按 group_id 清本机群盘配置（不产生气泡）",
			Data:        json.RawMessage(`{"type":"object","properties":{"group_id":{"type":"string"}},"required":["group_id"]}`),
		},
		{
			Type:        "group.allowFriendAddChanged",
			Description: "管理员开关群成员互加好友权限，成员按 group_id 刷新本机设置（不产生气泡）",
			Data:        json.RawMessage(`{"type":"object","properties":{"group_id":{"type":"string"},"enabled":{"type":"boolean"}},"required":["group_id","enabled"]}`),
		},
		{
			Type:        "group.levelsChanged",
			Description: "管理员更新群等级配置（含开关），成员按 group_id 通过 group.members 刷新本机等级列表（不产生气泡）",
			Data:        json.RawMessage(`{"type":"object","properties":{"group_id":{"type":"string"}},"required":["group_id"]}`),
		},
		{
			Type:        "group.memberProfileChanged",
			Description: "群成员本群称呼或等级变化，UI 按 group_id/account 刷新成员展示（不产生气泡）",
			Data:        json.RawMessage(`{"type":"object","properties":{"group_id":{"type":"string"},"account":{"type":"string"},"nickname":{"type":"string"},"level_id":{"type":"string"}},"required":["group_id","account","nickname","level_id"]}`),
		},
		{
			Type:        "friend.request.new",
			Description: "收到新的好友申请，UI 刷新申请列表与角标",
			Data:        json.RawMessage(`{"type":"object","properties":{"id":{"type":"string"},"peer":{"type":"string"},"message":{"type":"string"}},"required":["id","peer"]}`),
		},
		{
			Type:        "friend.request.resolved",
			Description: "好友申请被同意或拒绝，UI 刷新申请状态",
			Data:        json.RawMessage(`{"type":"object","properties":{"id":{"type":"string"},"accepted":{"type":"boolean"}},"required":["id","accepted"]}`),
		},
		{
			Type:        "group.joinRequested",
			Description: "收到入群申请，管理员 UI 刷新审批列表",
			Data:        json.RawMessage(`{"type":"object","properties":{"id":{"type":"string"},"group_id":{"type":"string"},"peer":{"type":"string"}},"required":["id","group_id","peer"]}`),
		},
		{
			Type:        "group.joinResolved",
			Description: "入群申请被同意或拒绝",
			Data:        json.RawMessage(`{"type":"object","properties":{"id":{"type":"string"},"group_id":{"type":"string"},"accepted":{"type":"boolean"}},"required":["id","group_id","accepted"]}`),
		},
		{
			Type:        "moment.new",
			Description: "好友发布新动态",
			Data:        json.RawMessage(`{"type":"object","properties":{"id":{"type":"string"},"peer":{"type":"string"}},"required":["id"]}`),
		},
		{
			Type:        "poll.updated",
			Description: "群投票有新投票，UI 刷新结果",
			Data:        json.RawMessage(`{"type":"object","properties":{"poll_id":{"type":"string"}},"required":["poll_id"]}`),
		},
	}
}
