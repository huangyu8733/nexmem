package blob

// 一次性票据上传（P3-06）。
//
// 发送方离线投递时只持有接收方生成的 presigned PUT URL，不接触接收方任何
// S3 凭证；上传失败由调用方换一张票据重试。

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// ValidateTicketURL 校验票据 URL 形态：http(s)、有主机且带签名参数。
func ValidateTicketURL(raw string) error {
	return validTicketURL(raw)
}

// PutPresigned 用一次性票据把 data 直接 PUT 到对象存储。
//
// 票据只签了 host，因此这里不额外设置会被纳入签名的请求头。
// 返回的错误按 S3 分类包装：401/403 → ErrAuth，429 → ErrQuota，
// 404 → ErrNotFound，5xx/网络错误 → ErrIO。
func PutPresigned(ctx context.Context, client *http.Client, rawURL string, data []byte) error {
	if err := validTicketURL(rawURL); err != nil {
		return err
	}
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidTicket, err)
	}
	if client == nil {
		client = &http.Client{Timeout: 60 * time.Second}
	}
	if ctx == nil {
		ctx = context.Background()
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, u.String(), bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("%w: 构造上传请求: %v", ErrIO, err)
	}
	req.ContentLength = int64(len(data))
	req.Header.Set("Content-Type", "application/octet-stream")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: 上传请求: %v", ErrIO, err)
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		drainClose(resp)
		return nil
	}
	return readError(resp)
}

// PutPresigned 使用客户端自带的连接池上传票据对象。
func (c *Client) PutPresigned(ctx context.Context, rawURL string, data []byte) error {
	return PutPresigned(ctx, c.httpClient, rawURL, data)
}
