package dm

// 离线对象丢弃与诊断（P3-08）。
//
// 接收方只接收「本账号、签名有效、未过期、在大小上限内、可解密」的对象，
// 其余一律丢弃：不写入消息表、不推进会话未读，并通过 OnOfflineReject 回调与
// 结构化诊断日志各记录一条事件，便于排障与 UI 提示。

// OfflineRejectReason 是离线对象被丢弃的原因，取值稳定，供日志与 UI 使用。
type OfflineRejectReason string

const (
	// ReasonOversize 表示对象超过单对象大小上限。
	ReasonOversize OfflineRejectReason = "oversize"
	// ReasonMalformed 表示对象无法解析或关键字段缺失。
	ReasonMalformed OfflineRejectReason = "malformed"
	// ReasonNotOwner 表示接收方账号不是本机账号。
	ReasonNotOwner OfflineRejectReason = "not_owner"
	// ReasonSelfSend 表示发送方与接收方为同一账号。
	ReasonSelfSend OfflineRejectReason = "self_send"
	// ReasonKeyAlg 表示信封密钥算法不受支持。
	ReasonKeyAlg OfflineRejectReason = "key_alg"
	// ReasonSignature 表示发送方签名校验失败。
	ReasonSignature OfflineRejectReason = "signature"
	// ReasonExpired 表示对象已超过发送方声明的 TTL。
	ReasonExpired OfflineRejectReason = "expired"
	// ReasonConversation 表示声明的会话 ID 与收发双方不符。
	ReasonConversation OfflineRejectReason = "conversation"
	// ReasonDecrypt 表示混合加解密失败。
	ReasonDecrypt OfflineRejectReason = "decrypt"
	// ReasonContent 表示解密后的正文类型或内容非法。
	ReasonContent OfflineRejectReason = "content"
	// ReasonAck 表示受理链路拒绝（例如群信封回调失败）。
	ReasonAck OfflineRejectReason = "ack_rejected"
	// ReasonBlocked 表示发送方已被本机拉黑。
	ReasonBlocked OfflineRejectReason = "blocked"
)

// OfflineRejectModule 是诊断日志模块名。
const OfflineRejectModule = "dm.offline"

// OfflineRejectEvent 描述一次离线对象丢弃。
//
// 不包含正文、密文或密钥；ObjectKey 与 MsgUUID 仅用于定位问题对象。
type OfflineRejectEvent struct {
	ObjectKey string
	Size      int64
	MsgUUID   string
	Reason    OfflineRejectReason
}

// rejectOffline 记录一次丢弃事件：先写诊断日志，再通知上层回调。
func (s *Service) rejectOffline(ev OfflineRejectEvent) {
	if s.diag != nil {
		s.diag.Warn(OfflineRejectModule, "丢弃离线对象", map[string]any{
			"object_key": ev.ObjectKey,
			"size":       ev.Size,
			"msg_uuid":   ev.MsgUUID,
			"reason":     string(ev.Reason),
		})
	}
	if s.onOfflineReject != nil {
		s.onOfflineReject(ev)
	}
}
