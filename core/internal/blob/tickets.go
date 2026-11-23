package blob

// 上传票据池（P3-03）。
//
// 接收方用自己的 S3 凭证批量生成 presigned PUT URL（票据），交给索引服务保管；
// 发送方离线投递时只领取票据，不接触接收方凭证。票据一次性、带有效期，
// 对象键固定落在 im_offline/{account}/inbox/ 下，便于桶生命周期统一清理。

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"
)

const (
	// OfflineObjectPrefix 是离线消息对象键前缀，桶生命周期规则作用于该前缀。
	OfflineObjectPrefix = "im_offline"
	// TicketBatchSize 是接收方单次交存的票据数（方案固定 512 张）。
	TicketBatchSize = 512
	// DefaultTicketTTL 是票据默认有效期，与票据池 24h TTL 保持一致。
	DefaultTicketTTL = 24 * time.Hour
	// AccountPubSize 是账号 ed25519 公钥长度。
	AccountPubSize = 32

	minTicketTTL = time.Minute
	maxTicketTTL = 24 * time.Hour
	// maxTicketBatch 限制单次生成数量，避免误用导致批量签名拖垮客户端。
	maxTicketBatch = 4096
	ticketRandSize = 16
)

// ErrInvalidTicket 表示票据生成入参或产物不合法。
var ErrInvalidTicket = errors.New("票据不合法")

// Ticket 是一张一次性上传票据：只含对象键、presigned PUT URL 与过期时间。
type Ticket struct {
	Key       string `json:"key"`
	URL       string `json:"url"`
	ExpiresAt int64  `json:"expires_at"` // Unix 秒
}

// Expired 判断票据在 now 时点是否已过期。
func (t Ticket) Expired(now time.Time) bool {
	return now.Unix() >= t.ExpiresAt
}

// TicketBatch 是接收方交存到索引服务的一批票据。
type TicketBatch struct {
	// AccountPub 为账号 ed25519 公钥的 base64url（无填充）编码。
	AccountPub string `json:"account_pub"`
	// DeviceID 标识生成该批票据的设备，索引服务按设备分桶消耗。
	DeviceID  string   `json:"device_id"`
	IssuedAt  int64    `json:"issued_at"`
	ExpiresAt int64    `json:"expires_at"`
	Tickets   []Ticket `json:"tickets"`
}

// Presigner 生成 presigned PUT URL，由 *Client 实现。
type Presigner interface {
	PresignPut(key string, ttl time.Duration) (string, error)
}

// InboxPrefix 返回账号离线收件箱的对象键前缀。
// 发送方上传与接收方拉取必须使用同一前缀。
func InboxPrefix(accountPub []byte) string {
	return OfflineObjectPrefix + "/" + base64.RawURLEncoding.EncodeToString(accountPub) + "/inbox/"
}

// TicketIssuer 按接收方账号批量生成上传票据。
type TicketIssuer struct {
	presigner Presigner
	ttl       time.Duration
	now       func() time.Time
	rand      io.Reader
}

// NewTicketIssuer 创建票据生成器，ttl 取值 1 分钟～24 小时。
func NewTicketIssuer(presigner Presigner, ttl time.Duration) (*TicketIssuer, error) {
	if presigner == nil {
		return nil, fmt.Errorf("%w: 缺少 presigner", ErrInvalidTicket)
	}
	if ttl <= 0 {
		ttl = DefaultTicketTTL
	}
	if ttl < minTicketTTL || ttl > maxTicketTTL {
		return nil, fmt.Errorf("%w: 有效期 %s 超出 1m～24h", ErrInvalidTicket, ttl)
	}
	return &TicketIssuer{
		presigner: presigner,
		ttl:       ttl,
		now:       time.Now,
		rand:      rand.Reader,
	}, nil
}

// TTL 返回票据有效期。
func (i *TicketIssuer) TTL() time.Duration { return i.ttl }

// IssueBatch 为 accountPub 生成 count 张票据并返回带元数据的批次。
func (i *TicketIssuer) IssueBatch(accountPub []byte, deviceID string, count int) (*TicketBatch, error) {
	if len(accountPub) != AccountPubSize {
		return nil, fmt.Errorf("%w: 账号公钥长度 %d，期望 %d", ErrInvalidTicket, len(accountPub), AccountPubSize)
	}
	if count <= 0 || count > maxTicketBatch {
		return nil, fmt.Errorf("%w: 数量 %d 超出 1～%d", ErrInvalidTicket, count, maxTicketBatch)
	}
	if strings.TrimSpace(deviceID) == "" {
		return nil, fmt.Errorf("%w: 缺少设备 ID", ErrInvalidTicket)
	}

	issuedAt := i.now().UTC()
	expiresAt := issuedAt.Add(i.ttl)
	prefix := InboxPrefix(accountPub)

	tickets := make([]Ticket, 0, count)
	seen := make(map[string]struct{}, count)
	for len(tickets) < count {
		suffix := make([]byte, ticketRandSize)
		if _, err := io.ReadFull(i.rand, suffix); err != nil {
			return nil, fmt.Errorf("生成票据随机串: %w", err)
		}
		key := prefix + hex.EncodeToString(suffix) + ".msg"
		if _, dup := seen[key]; dup {
			continue
		}

		raw, err := i.presigner.PresignPut(key, i.ttl)
		if err != nil {
			return nil, fmt.Errorf("生成票据 %s: %w", key, err)
		}
		if err := validTicketURL(raw); err != nil {
			return nil, fmt.Errorf("票据 %s: %w", key, err)
		}
		seen[key] = struct{}{}
		tickets = append(tickets, Ticket{Key: key, URL: raw, ExpiresAt: expiresAt.Unix()})
	}

	return &TicketBatch{
		AccountPub: base64.RawURLEncoding.EncodeToString(accountPub),
		DeviceID:   deviceID,
		IssuedAt:   issuedAt.Unix(),
		ExpiresAt:  expiresAt.Unix(),
		Tickets:    tickets,
	}, nil
}

// Issue 是 IssueBatch 的简化形式，只返回票据列表。
func (i *TicketIssuer) Issue(accountPub []byte, count int) ([]Ticket, error) {
	batch, err := i.IssueBatch(accountPub, "default", count)
	if err != nil {
		return nil, err
	}
	return batch.Tickets, nil
}

// validTicketURL 校验 presigned URL 的基本形态。
func validTicketURL(raw string) error {
	if strings.TrimSpace(raw) == "" {
		return fmt.Errorf("%w: 票据 URL 为空", ErrInvalidTicket)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("%w: 解析票据 URL: %v", ErrInvalidTicket, err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("%w: 票据 URL 协议 %q", ErrInvalidTicket, u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("%w: 票据 URL 缺少主机", ErrInvalidTicket)
	}
	if u.Query().Get("X-Amz-Signature") == "" {
		return fmt.Errorf("%w: 票据 URL 缺少签名", ErrInvalidTicket)
	}
	return nil
}
