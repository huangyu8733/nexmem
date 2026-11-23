package gateway

import "fmt"

// ErrorCode 是与各端约定的固定错误码集合（见 docs/Nexmem-engineering-plan.md §6.4）。
type ErrorCode string

// 固定错误码。跨端契约中只允许出现这些取值。
const (
	CodeInvalidArg             ErrorCode = "INVALID_ARG"
	CodeNotStarted             ErrorCode = "NOT_STARTED"
	CodeNotOnline              ErrorCode = "NOT_ONLINE"
	CodePeerUnreachable        ErrorCode = "PEER_UNREACHABLE"
	CodeOfflineStorageDisabled ErrorCode = "OFFLINE_STORAGE_DISABLED"
	CodeS3Auth                 ErrorCode = "S3_AUTH"
	CodeS3Quota                ErrorCode = "S3_QUOTA"
	CodeS3IO                   ErrorCode = "S3_IO"
	CodeDBError                ErrorCode = "DB_ERROR"
	CodeCryptoError            ErrorCode = "CRYPTO_ERROR"
	CodeRateLimited            ErrorCode = "RATE_LIMITED"
	CodeUnsupportedVersion     ErrorCode = "UNSUPPORTED_VERSION"
	CodeResyncRequired         ErrorCode = "RESYNC_REQUIRED"
)

// errorCodeOrder 同时决定契约文件中错误码的导出顺序。
var errorCodeOrder = []ErrorCode{
	CodeInvalidArg,
	CodeNotStarted,
	CodeNotOnline,
	CodePeerUnreachable,
	CodeOfflineStorageDisabled,
	CodeS3Auth,
	CodeS3Quota,
	CodeS3IO,
	CodeDBError,
	CodeCryptoError,
	CodeRateLimited,
	CodeUnsupportedVersion,
	CodeResyncRequired,
}

// retryable 表示该错误是否为瞬时错误，Dart 侧据此决定是否提示重试。
var retryable = map[ErrorCode]bool{
	CodeInvalidArg:             false,
	CodeNotStarted:             false,
	CodeNotOnline:              true,
	CodePeerUnreachable:        true,
	CodeOfflineStorageDisabled: false,
	CodeS3Auth:                 false,
	CodeS3Quota:                false,
	CodeS3IO:                   true,
	CodeDBError:                false,
	CodeCryptoError:            false,
	CodeRateLimited:            true,
	CodeUnsupportedVersion:     false,
	CodeResyncRequired:         true,
}

// errorDescription 是契约文件中给人读的说明。
var errorDescription = map[ErrorCode]string{
	CodeInvalidArg:             "参数缺失、类型错误或 method 未知",
	CodeNotStarted:             "内核未启动，或该能力当前阶段尚未接入",
	CodeNotOnline:              "内核在线状态未就绪（degraded/offline）",
	CodePeerUnreachable:        "打洞与中继均无法连通对端",
	CodeOfflineStorageDisabled: "对端未开启离线存储",
	CodeS3Auth:                 "对象存储鉴权失败（AK/SK 或票据无效）",
	CodeS3Quota:                "对象存储配额或桶容量超限",
	CodeS3IO:                   "对象存储读写失败（可重试）",
	CodeDBError:                "本地数据库读写失败",
	CodeCryptoError:            "解密或验签失败",
	CodeRateLimited:            "触发限流，稍后重试",
	CodeUnsupportedVersion:     "端与内核的 API 版本不兼容",
	CodeResyncRequired:         "事件缓冲出现缺口，需要全量重同步",
}

// Error 是响应体中的 error 对象，也是 HandlerFunc 的统一错误出口。
type Error struct {
	Code      ErrorCode `json:"code"`
	Message   string    `json:"message"`
	Retryable bool      `json:"retryable"`
}

// Error 让 *Error 满足 error 接口，便于在上层用 errors.As 取出错误码。
func (e *Error) Error() string {
	return string(e.Code) + ": " + e.Message
}

// NewError 构造一个带固定错误码的错误；未知错误码按 INVALID_ARG 处理。
func NewError(code ErrorCode, format string, args ...any) *Error {
	if _, ok := retryable[code]; !ok {
		code = CodeInvalidArg
	}
	msg := format
	if len(args) > 0 {
		msg = fmt.Sprintf(format, args...)
	}
	return &Error{Code: code, Message: msg, Retryable: retryable[code]}
}
