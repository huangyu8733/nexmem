package coreapp

// 离线通道生产装配（P3-06/P3-07）：
// 启动时把本机公开档案（含设备证书）发布到索引服务，并在开启离线存储时
// 批量签发并交存 presigned 上传票据；运行期按固定周期刷新，保证票据池不过期。
// 发送方离线投递与接收方收件箱拉取由 dm 服务在同一批依赖上完成。

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/diag"
	"github.com/nexmem/core/internal/directory"
	"github.com/nexmem/core/internal/identity"
)

const (
	// offlinePublishInterval 是公开档案与票据池的刷新周期。
	// 票据有效期 24h，6h 刷新一次可在到期前留下两轮余量。
	offlinePublishInterval = 6 * time.Hour
	// offlinePublishTimeout 是单次发布的超时时间。
	offlinePublishTimeout = 30 * time.Second
)

// offlinePublisher 负责把本机档案与上传票据同步到索引服务。
type offlinePublisher struct {
	dir        *directory.Client
	bucket     *blob.Client
	account    *identity.Account
	devicePub  []byte
	deviceID   string
	deviceName string
	// enabled 表示本机启用离线存储；关闭时不签发票据。
	enabled bool
	// public 表示是否对外公开存储（P6-25）：关闭时公开档案撤回离线能力，
	// 已交存票据不再续期，对端只能走在线直连。
	public bool
	log    *diag.Logger

	stop      chan struct{}
	done      chan struct{}
	startOnce sync.Once
	closeOnce sync.Once
}

// newOfflinePublisher 创建发布器；dir 为 nil 时返回 nil，表示未接入索引服务。
func newOfflinePublisher(dir *directory.Client, bucket *blob.Client, account *identity.Account, devicePub []byte, deviceID, deviceName string, enabled, public bool, log *diag.Logger) *offlinePublisher {
	if dir == nil || account == nil {
		return nil
	}
	if strings.TrimSpace(deviceName) == "" {
		deviceName = "nexmem-device"
	}
	return &offlinePublisher{
		dir:        dir,
		bucket:     bucket,
		account:    account,
		devicePub:  devicePub,
		deviceID:   deviceID,
		deviceName: deviceName,
		enabled:    enabled && bucket != nil,
		public:     public,
		log:        log,
	}
}

// start 启动后台刷新协程：立即发布一次，随后按周期重试；重复调用安全。
func (p *offlinePublisher) start() {
	if p == nil {
		return
	}
	p.startOnce.Do(func() {
		p.stop = make(chan struct{})
		p.done = make(chan struct{})
		go p.loop()
	})
}

// close 停止后台刷新并等待退出；重复调用安全。
func (p *offlinePublisher) close() {
	if p == nil {
		return
	}
	p.closeOnce.Do(func() {
		if p.stop == nil {
			return
		}
		close(p.stop)
		<-p.done
	})
}

func (p *offlinePublisher) loop() {
	defer close(p.done)
	p.publishOnce()
	ticker := time.NewTicker(offlinePublishInterval)
	defer ticker.Stop()
	for {
		select {
		case <-p.stop:
			return
		case <-ticker.C:
			p.publishOnce()
		}
	}
}

// publishOnce 刷新档案与票据；失败只影响本轮，等待下次重试。
// 发布失败不阻断内核：在线收发与本地功能均不依赖索引服务。
func (p *offlinePublisher) publishOnce() {
	ctx, cancel := context.WithTimeout(context.Background(), offlinePublishTimeout)
	defer cancel()
	if err := p.Publish(ctx); err != nil && p.log != nil {
		p.log.Warn("offline", "离线通道发布失败", map[string]any{"error": err.Error()})
	}
}

// profileDeviceLimit 是公开档案中保留的设备证书上限。
const profileDeviceLimit = 16

// mergeProfileDevices 合并本机设备证书与既有档案里的其它设备证书（P6-21）：
// 同一设备只保留本机新签发的证书，丢弃已过期或验签失败的证书，
// 按签发时间倒序截断到 profileDeviceLimit 台。
//
// 多设备账号共用一份公开档案，若每次发布只写本机证书，同账号其它设备会被抹掉，
// 设备列表与发送方解析都会失准；这里把可用的历史证书原样带回。
func mergeProfileDevices(existing *nexmemv1.PublicProfile, own *nexmemv1.DeviceCert, now time.Time) []*nexmemv1.DeviceCert {
	byPub := make(map[string]*nexmemv1.DeviceCert, profileDeviceLimit)
	if own != nil && len(own.DevicePub) > 0 {
		byPub[string(own.DevicePub)] = own
	}
	if existing != nil {
		for _, cert := range existing.Devices {
			if cert == nil || len(cert.DevicePub) == 0 {
				continue
			}
			if _, ok := byPub[string(cert.DevicePub)]; ok {
				continue
			}
			if err := identity.VerifyDeviceCert(cert, now); err != nil {
				continue
			}
			byPub[string(cert.DevicePub)] = cert
		}
	}
	out := make([]*nexmemv1.DeviceCert, 0, len(byPub))
	for _, cert := range byPub {
		out = append(out, cert)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IssuedAt != out[j].IssuedAt {
			return out[i].IssuedAt > out[j].IssuedAt
		}
		return bytes.Compare(out[i].DevicePub, out[j].DevicePub) < 0
	})
	if len(out) > profileDeviceLimit {
		out = out[:profileDeviceLimit]
	}
	return out
}

// Publish 上传公开档案，并在启用且对外公开时补一批票据。
func (p *offlinePublisher) Publish(ctx context.Context) error {
	now := time.Now()
	var own *nexmemv1.DeviceCert
	if len(p.devicePub) > 0 {
		cert, err := p.account.IssueDeviceCert(p.devicePub, p.deviceName, identity.DefaultDeviceCertTTL)
		if err != nil {
			return fmt.Errorf("签发设备证书: %w", err)
		}
		own = cert
	}
	// 读回既有档案用于合并；读不到（首次发布或索引服务抖动）时只发布本机证书，
	// 不阻断在线收发与后续周期刷新。
	existing, err := p.dir.GetProfile(ctx, p.account.Pub())
	if err != nil {
		if !errors.Is(err, directory.ErrProfileNotFound) && p.log != nil {
			p.log.Warn("offline", "读取既有公开档案失败", map[string]any{"error": err.Error()})
		}
		existing = nil
	}
	profile := &nexmemv1.PublicProfile{
		OfflineEnabled: p.enabled && p.public,
		UpdatedAt:      now.Unix(),
	}
	if existing != nil {
		// 离线能力是账号级声明：任一设备开启即保持开启，避免本机关闭时撤回；
		// 但本机显式关闭「对外公开」时必须强制撤回，阻断新的外部写入。
		if p.public {
			profile.OfflineEnabled = profile.OfflineEnabled || existing.OfflineEnabled
		}
		// 索引服务按 updated_at 单调递增接收，时钟回拨时以既有档案为准前进一格。
		if existing.UpdatedAt >= profile.UpdatedAt {
			profile.UpdatedAt = existing.UpdatedAt + 1
		}
	}
	profile.Devices = mergeProfileDevices(existing, own, now)
	if err := p.account.SignProfile(profile); err != nil {
		return fmt.Errorf("签发公开档案: %w", err)
	}
	if err := p.dir.PutProfile(ctx, profile); err != nil {
		return fmt.Errorf("上传公开档案: %w", err)
	}
	if !p.enabled || !p.public {
		return nil
	}
	return p.depositTickets(ctx)
}

// depositTickets 生成一批票据并交存到索引服务。
func (p *offlinePublisher) depositTickets(ctx context.Context) error {
	issuer, err := blob.NewTicketIssuer(p.bucket, blob.DefaultTicketTTL)
	if err != nil {
		return fmt.Errorf("创建票据生成器: %w", err)
	}
	batch, err := issuer.IssueBatch(p.account.Pub(), p.deviceID, blob.TicketBatchSize)
	if err != nil {
		return fmt.Errorf("生成离线票据: %w", err)
	}
	if err := p.dir.DepositTickets(ctx, batch); err != nil {
		return fmt.Errorf("交存离线票据: %w", err)
	}
	return nil
}
