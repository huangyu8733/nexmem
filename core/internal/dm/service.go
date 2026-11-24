// Package dm 实现单聊（P1-11）：基于 libp2p 直连流完成文本收发、设备签名校验、
// 应用层 ACK 与本地入库。
//
// 传输层：每条消息在 /nexmem/dm/1.0.0 上开一个流，写入一帧 MSG 并等待一帧 ACK，
// 收到 ACK 后才把这帧视为送达。发送侧全局串行，保证同一对端消息按调用顺序落库。
package dm

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	libp2pcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"

	"github.com/nexmem/core/internal/diag"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

const (
	// streamTimeout 是单个入站流的读写超时。
	streamTimeout = 30 * time.Second
	// maxClockSkew 允许的发送时间与本机时间偏差。
	maxClockSkew = 7 * 24 * time.Hour
	// readReceiptMaxFuture 允许已读回执水位不超过本机时间的安全余量。
	readReceiptMaxFuture = 5 * time.Minute
)

// ACK 错误码，与 wire.proto 的 Ack.code 对应。
const (
	AckOK     int32 = 0
	AckDup    int32 = 1
	AckReject int32 = 2
)

// 语义错误。
var (
	ErrSelfSend      = errors.New("不能给自己发送消息")
	ErrEmptyText     = errors.New("文本不能为空")
	ErrPeerRejected  = errors.New("对端拒绝接收")
	ErrPeerUnreached = errors.New("对端不可达")
	ErrInvalidTarget = errors.New("对端账号公钥非法")
	ErrAckInvalid    = errors.New("对端 ACK 非法")
	ErrPeerBlocked   = errors.New("已拉黑该联系人，无法发送消息")
)

// Blocklist 查询本机是否拉黑了某账号（P2-06），由 contacts.Service 实现。
type Blocklist interface {
	IsBlocked(ctx context.Context, accountPub []byte) (bool, error)
}

// Waker 触发接收方设备的离线唤醒推送（P6-02），由索引服务客户端实现。
type Waker interface {
	Wake(ctx context.Context, accountPub []byte) (bool, error)
}

// Target 描述单聊对端的传输地址与账号身份。
type Target struct {
	PeerID     peer.ID
	Addrs      []multiaddr.Multiaddr
	AccountPub []byte // 32 字节 ed25519 账号公钥
}

// InboundEvent 描述一条刚入库的入站消息，供上层发出 message.new 事件。
type InboundEvent struct {
	ConversationID string
	MsgUUID        string
	ContentType    int
}

// ReadEvent 描述对端回传的已读位置（P6-07），UpTo 为 Unix 毫秒时间戳。
type ReadEvent struct {
	PeerAccount    []byte
	ConversationID string
	UpTo           int64
}

// Options 是创建单聊服务的依赖。
type Options struct {
	Host      host.Host
	DeviceKey libp2pcrypto.PrivKey
	DAO       *store.DAO
	Account   *identity.Account
	// AckTimeout 留空使用 DefaultAckTimeout。
	AckTimeout time.Duration
	// MaxAttempts 留空使用 DefaultMaxAttempts。
	MaxAttempts int
	// Resolver 把离线队列中的对端账号解析为可直连地址；为 nil 时后台补发跳过。
	Resolver PeerResolver
	// ResumeInterval 是后台补发扫描间隔，留空使用 DefaultResumeInterval。
	ResumeInterval time.Duration
	// ResumeRetryDelay 是单条补发失败后的退避，留空使用 DefaultResumeRetryDelay。
	ResumeRetryDelay time.Duration
	// DisableAutoResume 关闭后台补发协程，仅用于测试等需要完全手动控制的场景。
	DisableAutoResume bool
	// InboxDir 是接收文件的落盘目录，留空使用系统缓存目录下的 nexmem/inbox。
	InboxDir string
	// ChunkSize 是文件分片大小，留空使用 DefaultChunkSize。
	ChunkSize int
	// ProgressInterval 是文件传输进度的最小上报间隔，留空使用 DefaultProgressInterval。
	ProgressInterval time.Duration
	// OnProgress 接收文件传输进度回调；回调由传输协程调用，需自行保证线程安全。
	OnProgress func(TransferProgress)
	// Directory 是索引服务客户端；与 Uploader 同时非空时启用离线投递（P3-06）。
	Directory OfflineDirectory
	// Uploader 用 presigned 票据上传离线对象。
	Uploader PresignedUploader
	// OfflineTTL 是离线对象的保留时长，留空使用 DefaultOfflineTTL（1h～7d）。
	OfflineTTL time.Duration
	// OnDelivery 上报发送状态变化（含离线投递成功）；回调可能来自任意协程。
	OnDelivery func(DeliveryEvent)
	// Inbox 是接收方自己桶的只读客户端；非空时启用离线拉取（P3-07）。
	Inbox OfflineStore
	// ReadSyncStore 是可写的同账号共用收件箱，用于发布/拉取跨设备已读水位（C-04）。
	// 留空则关闭跨设备已读同步；*blob.Client 同时满足 Inbox 与本接口。
	ReadSyncStore ReadSyncStore
	// DeleteAfterRead 开启「已读后删除 S3 密文对象」（C-02）。默认 false，即由桶
	// 生命周期规则清理；仅当 Inbox 实现 OfflineObjectDeleter 时生效。多端共用桶
	// 必须保持 false，否则一台设备删除会导致其他设备拉不到消息。
	DeleteAfterRead bool
	// FetchInterval 是后台离线拉取间隔，留空使用 DefaultOfflineFetchInterval。
	FetchInterval time.Duration
	// DisableAutoFetch 关闭后台离线拉取协程，仅用于测试等需要手动拉取的场景。
	DisableAutoFetch bool
	// OnGroupMeta 处理经单聊通道收到的群密钥信封（P4-08）。
	// 返回错误时对端会收到 ACK 拒收；回调在接收协程执行，需自行保证线程安全。
	OnGroupMeta GroupMetaHook
	// OnControlText 在入站文本落库前回调，用于拦截社交控制帧（好友申请/入群审批等）。
	// 返回 true 表示该文本已被消费为控制帧：不落消息表、不产生聊天气泡。
	// 回调在接收协程执行，需自行保证线程安全。
	OnControlText func(ctx context.Context, sender []byte, text string) bool
	// OnMessage 在入站消息落库成功后回调（P1-20），用于上层发出 message.new；
	// 回调在接收协程执行，需自行保证线程安全。
	OnMessage func(InboundEvent)
	// OnOfflineReject 上报被丢弃的离线对象（P3-08）；回调可能来自任意协程。
	OnOfflineReject func(OfflineRejectEvent)
	// OnRead 处理对端回传的已读回执（P6-07）；回调在接收协程执行，
	// 由上层把本机出站消息推进到已读并发出 message.updated。
	OnRead func(ReadEvent)
	// OnReadSync 在跨设备已读水位应用后通知上层刷新会话（C-04）；
	// 参数为被推进的会话 ID 列表，回调在离线拉取协程执行。
	OnReadSync func(conversationIDs []string)
	// OnRecall 处理对端撤回通知（P6-12）；回调在接收协程执行，
	// 由上层发出 message.recalled。消息本身已在回调前从本地库删除。
	OnRecall func(RecallEvent)
	// OnTyping 处理对端输入状态（七-3）；回调在接收协程执行，由上层发出 typing 事件。
	OnTyping func(TypingEvent)
	// OnEdit 处理对端编辑通知（七-2）；回调在接收协程执行，
	// 由上层更新本机消息并发出 message.edited。
	OnEdit func(EditEvent)
	// OnRTCSignal 处理经 /nexmem/rtc/1.0.0 收到的 RTC 信令；回调在接收协程执行，
	// 由上层发出 rtc.signal 事件。
	OnRTCSignal func(RTCSignalEvent)
	// Blocklist 提供本机黑名单查询（P2-06）；为 nil 时不做拉黑校验。
	Blocklist Blocklist
	// Waker 在离线投递成功后触发接收方唤醒（P6-02）；为 nil 时跳过。
	Waker Waker
	// Diag 是结构化日志器，非空时记录离线对象丢弃事件。
	Diag *diag.Logger
	// OnOfflineUpload 上报一次离线对象上传结果（bytes=载荷字节数，ok=是否成功），
	// 供 P3 门禁的桶用量指标采集；回调可能来自任意协程。
	OnOfflineUpload func(bytes int64, ok bool)
	// OnTicketTake 上报一次离线上传票据领取数量（0 表示对方票据池为空），
	// 供 P3 门禁的票据消耗指标采集；回调可能来自任意协程。
	OnTicketTake func(n int)
	// fileInterrupt 仅用于测试：返回 true 时模拟断流，保留半成品供续传复用。
	fileInterrupt func(chunkIndex int) bool
}

// Service 是单聊的服务入口，绑定在一个 libp2p host 上。
type Service struct {
	host        host.Host
	deviceKey   libp2pcrypto.PrivKey
	dao         *store.DAO
	account     *identity.Account
	ackTimeout  time.Duration
	maxAttempts int

	// sendMu 串行化发送，确保同一发送进程写出的消息按调用顺序入库、按时间排序。
	sendMu sync.Mutex
	lastTS int64

	// replay 是入站消息的重放防护窗口（P2-02）。
	replay *replayGuard

	// 断线重连补发（P2-03）：后台按间隔扫描离线队列，连接事件也会立即触发一次。
	resolverMu  sync.RWMutex
	resolver    PeerResolver
	resumeEvery time.Duration
	resumeDelay time.Duration
	resumeCh    chan struct{}
	stopCh      chan struct{}
	stopOnce    sync.Once
	closeWait   sync.WaitGroup
	notifiee    peerNotifiee

	// 文件传输（P2-04）。
	inboxDir      string
	chunkSize     int
	progressEvery time.Duration
	onProgress    func(TransferProgress)
	// fileInterrupt 仅用于测试断点续传，见 Options.fileInterrupt。
	fileInterrupt func(chunkIndex int) bool

	// 离线投递（P3-06）。
	directory  OfflineDirectory
	uploader   PresignedUploader
	offlineTTL time.Duration
	onDelivery func(DeliveryEvent)

	// 离线通道指标（P3 门禁）。
	onOfflineUpload func(bytes int64, ok bool)
	onTicketTake    func(n int)

	// 离线拉取（P3-07）。
	inbox           OfflineStore
	readSyncStore   ReadSyncStore
	deleteAfterRead bool
	fetchEvery      time.Duration
	fetchMu         sync.Mutex

	// 群密钥信封（P4-08）。
	onGroupMeta GroupMetaHook
	// 入站文本控制帧回调（社交信令）。
	onControlText func(ctx context.Context, sender []byte, text string) bool
	// 入站消息回调（P1-20）。
	onMessage func(InboundEvent)
	// 已读回执回调（P6-07）。
	onRead func(ReadEvent)
	// 跨设备已读同步回调（C-04）。
	onReadSync func([]string)
	// 撤回通知回调（P6-12）。
	onRecall func(RecallEvent)
	// 输入状态回调（七-3）。
	onTyping func(TypingEvent)
	// 编辑通知回调（七-2）。
	onEdit func(EditEvent)
	// RTC 信令回调。
	onRTCSignal func(RTCSignalEvent)

	// 离线对象丢弃诊断（P3-08）。
	onOfflineReject func(OfflineRejectEvent)
	// 黑名单（P2-06）。
	blocklist Blocklist
	// 唤醒推送（P6-02）；按对端节流，避免每条离线消息都打一次索引服务。
	waker    Waker
	wakeMu   sync.Mutex
	wakeLast map[string]time.Time
	diag     *diag.Logger
}

// New 创建单聊服务并注册入站流处理器。
func New(opt Options) (*Service, error) {
	switch {
	case opt.Host == nil:
		return nil, errors.New("缺少 libp2p host")
	case opt.DeviceKey == nil:
		return nil, errors.New("缺少设备私钥")
	case opt.DAO == nil:
		return nil, errors.New("缺少本地 DAO")
	case opt.Account == nil:
		return nil, errors.New("缺少账号密钥")
	}
	timeout := opt.AckTimeout
	if timeout <= 0 {
		timeout = DefaultAckTimeout
	}
	attempts := opt.MaxAttempts
	if attempts <= 0 {
		attempts = DefaultMaxAttempts
	}
	resumeEvery := opt.ResumeInterval
	if resumeEvery <= 0 {
		resumeEvery = DefaultResumeInterval
	}
	resumeDelay := opt.ResumeRetryDelay
	if resumeDelay <= 0 {
		resumeDelay = DefaultResumeRetryDelay
	}
	chunkSize := opt.ChunkSize
	if chunkSize <= 0 {
		chunkSize = DefaultChunkSize
	}
	progressEvery := opt.ProgressInterval
	if progressEvery <= 0 {
		progressEvery = DefaultProgressInterval
	}
	inboxDir := opt.InboxDir
	if inboxDir == "" {
		inboxDir = defaultInboxDir()
	}
	offlineTTL := opt.OfflineTTL
	if offlineTTL <= 0 {
		offlineTTL = DefaultOfflineTTL
	}
	if offlineTTL < minOfflineTTL || offlineTTL > maxOfflineTTL {
		return nil, fmt.Errorf("离线保留时长 %s 超出 1h～7d", offlineTTL)
	}
	fetchEvery := opt.FetchInterval
	if fetchEvery <= 0 {
		fetchEvery = DefaultOfflineFetchInterval
	}
	s := &Service{
		host:            opt.Host,
		deviceKey:       opt.DeviceKey,
		dao:             opt.DAO,
		account:         opt.Account,
		ackTimeout:      timeout,
		maxAttempts:     attempts,
		replay:          newReplayGuard(replayTTL, replayCapacity),
		resolver:        opt.Resolver,
		resumeEvery:     resumeEvery,
		resumeDelay:     resumeDelay,
		resumeCh:        make(chan struct{}, 1),
		stopCh:          make(chan struct{}),
		inboxDir:        inboxDir,
		chunkSize:       chunkSize,
		progressEvery:   progressEvery,
		onProgress:      opt.OnProgress,
		directory:       opt.Directory,
		uploader:        opt.Uploader,
		offlineTTL:      offlineTTL,
		onDelivery:      opt.OnDelivery,
		onOfflineUpload: opt.OnOfflineUpload,
		onTicketTake:    opt.OnTicketTake,
		inbox:           opt.Inbox,
		readSyncStore:   opt.ReadSyncStore,
		deleteAfterRead: opt.DeleteAfterRead,
		fetchEvery:      fetchEvery,
		onGroupMeta:     opt.OnGroupMeta,
		onControlText:   opt.OnControlText,
		onMessage:       opt.OnMessage,
		onRead:          opt.OnRead,
		onReadSync:      opt.OnReadSync,
		onRecall:        opt.OnRecall,
		onTyping:        opt.OnTyping,
		onEdit:          opt.OnEdit,
		onRTCSignal:     opt.OnRTCSignal,
		onOfflineReject: opt.OnOfflineReject,
		blocklist:       opt.Blocklist,
		waker:           opt.Waker,
		diag:            opt.Diag,
		fileInterrupt:   opt.fileInterrupt,
	}
	s.notifiee = peerNotifiee{svc: s}
	if s.waker != nil {
		s.wakeLast = make(map[string]time.Time)
	}
	s.host.SetStreamHandler(wire.PIDDM, s.handleStream)
	s.host.SetStreamHandler(wire.PIDFile, s.handleFileStream)
	s.host.SetStreamHandler(wire.PIDRTC, s.handleRTCStream)

	// 对端重新连上时立即补发一次，避免等到下一个扫描周期。
	s.host.Network().Notify(s.notifiee)
	if !opt.DisableAutoResume {
		s.closeWait.Add(1)
		go s.resumeLoop()
	}
	if s.inbox != nil && !opt.DisableAutoFetch {
		s.closeWait.Add(1)
		go s.offlineFetchLoop()
	}
	return s, nil
}

// Close 注销流处理器与补发协程；不影响 host 本身的生命周期。
func (s *Service) Close() {
	s.host.RemoveStreamHandler(wire.PIDDM)
	s.host.RemoveStreamHandler(wire.PIDFile)
	s.host.RemoveStreamHandler(wire.PIDRTC)
	s.host.Network().StopNotify(s.notifiee)
	s.stopOnce.Do(func() { close(s.stopCh) })
	s.closeWait.Wait()
}

// AccountPub 返回本机账号 ed25519 公钥副本。
func (s *Service) AccountPub() []byte {
	return s.account.Pub()
}

// nextTimestamp 返回严格单调递增的 Unix 毫秒时间戳。
func (s *Service) nextTimestamp() int64 {
	now := time.Now().UnixMilli()
	if now <= s.lastTS {
		now = s.lastTS + 1
	}
	s.lastTS = now
	return now
}
