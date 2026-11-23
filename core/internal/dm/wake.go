package dm

// 离线唤醒推送触发（P6-02）。
//
// 离线投递成功后，发送方异步通知索引服务向接收方的已登记设备发送静默推送。
// 推送只是"有离线消息"的指针，不包含正文；接收方被唤醒后再经离线通道拉取。
// 每条消息都推送会打爆 APNs，因此按对端节流；推送失败只记诊断，不影响投递结果。

import (
	"context"
	"encoding/base64"
	"time"
)

const (
	// wakeThrottle 是同一对端两次唤醒推送的最小间隔。
	wakeThrottle = 10 * time.Second
	// wakeTimeout 是单次唤醒请求的超时。
	wakeTimeout = 5 * time.Second
	// wakeEntries 是节流表上限，超过后整体重置，避免长期运行无限增长。
	wakeEntries = 512
	// wakeModule 是唤醒推送诊断日志模块名。
	wakeModule = "dm.wake"
)

// notifyWake 按对端节流地触发一次唤醒推送，不阻塞发送路径。
func (s *Service) notifyWake(receiver []byte) {
	if s.waker == nil || len(receiver) == 0 {
		return
	}
	key := string(receiver)
	now := time.Now()

	s.wakeMu.Lock()
	if last, ok := s.wakeLast[key]; ok && now.Sub(last) < wakeThrottle {
		s.wakeMu.Unlock()
		return
	}
	if len(s.wakeLast) >= wakeEntries {
		s.wakeLast = make(map[string]time.Time)
	}
	s.wakeLast[key] = now
	s.wakeMu.Unlock()

	account := append([]byte(nil), receiver...)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), wakeTimeout)
		defer cancel()
		if _, err := s.waker.Wake(ctx, account); err != nil && s.diag != nil {
			s.diag.Warn(wakeModule, "离线唤醒推送失败", map[string]any{
				"account": base64.RawURLEncoding.EncodeToString(account),
				"error":   err.Error(),
			})
		}
	}()
}
