// Package coreapp 装配生产内核：身份、本地库、P2P 主机、单聊与网关方法。
//
// 平台层（webd / 桌面端）只需创建网关并调用 New，随后通过 core.start 启动内核；
// 所有运行期依赖都以提供者形式注入网关，未启动时方法统一返回 NOT_STARTED。
package coreapp

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	dht "github.com/libp2p/go-libp2p-kad-dht"
	lpcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/backup"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/contacts"
	"github.com/nexmem/core/internal/diag"
	"github.com/nexmem/core/internal/directory"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/expiry"
	"github.com/nexmem/core/internal/group"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/msg"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/store"
)

const (
	// DefaultUserAgent 是内核对外宣告的 libp2p 标识。
	DefaultUserAgent = "nexmem-core/0.1.0"
	// defaultResolveTimeout 是对端解析的总超时。
	defaultResolveTimeout = 12 * time.Second
	// dhtResolveAttempts 是 DHT 冷启动时 FindPeer 的重试次数。
	dhtResolveAttempts = 3
	// readReceiptTimeout 是单次已读回执发送的总超时（P6-07）。
	readReceiptTimeout = 10 * time.Second
	// recallTimeout 是单次撤回通知发送的总超时（P6-12）。
	recallTimeout = 10 * time.Second
)

// 启动参数错误。
var (
	// ErrDataDirRequired 表示未配置数据目录。
	ErrDataDirRequired = errors.New("core.start 缺少 config.data_dir")
	// ErrAlreadyStarted 预留给平台层提示；Start 幂等不会返回该错误。
	ErrAlreadyStarted = errors.New("内核已启动")
)

// Config 是 core.start 的启动配置，字段名与契约保持一致。
type Config struct {
	DataDir         string   `json:"data_dir"`
	DisplayName     string   `json:"display_name"`
	Listen          []string `json:"listen"`
	Bootstraps      []string `json:"bootstraps"`
	RelayAddrs      []string `json:"relay_addrs"`
	DirectoryURL    string   `json:"directory_url"`
	EnableHolePunch bool     `json:"enable_hole_punch"`
	EnableNAT       bool     `json:"enable_nat_service"`
	ConnLow         int      `json:"conn_low"`
	ConnHigh        int      `json:"conn_high"`
	InboxDir        string   `json:"inbox_dir"`
	// DeviceName 是设备证书中的展示名，留空使用 nexmem-device。
	DeviceName string `json:"device_name"`
	// Storage 是本机离线存储的 S3 兼容配置；非空时启用离线收发。
	Storage *StorageConfig `json:"storage"`
	// OfflineEnabled 控制是否对外声明「可接收离线消息」；留空时随 Storage 是否存在。
	OfflineEnabled *bool `json:"offline_enabled"`
}

// StorageConfig 是接收方离线存储的 S3 兼容配置（与 storage.test 表单一致）。
type StorageConfig struct {
	Endpoint  string `json:"endpoint"`
	Region    string `json:"region"`
	Bucket    string `json:"bucket"`
	AccessKey string `json:"access_key"`
	SecretKey string `json:"secret_key"`
	PathStyle bool   `json:"path_style"`
	// Public 表示是否对外公开本机存储（允许对端写入离线消息）；
	// 省略时默认公开，false 时立即在公开档案中撤回离线能力并停止交存票据。
	Public *bool `json:"public"`
	// DeleteAfterRead 开启「已读后删除 S3 密文对象」（C-02，需求 L66/L103）。
	// 默认 false = 由桶生命周期清理；多端共用同一桶时必须保持 false。
	DeleteAfterRead bool `json:"delete_after_read"`
}

// EventSink 接收内核异步事件；平台层负责补 seq / 时间戳并转发给 UI。
type EventSink interface {
	Emit(name string, data any)
}

// EventSinkFunc 把普通函数适配为 EventSink。
type EventSinkFunc func(name string, data any)

// Emit 实现 EventSink。
func (f EventSinkFunc) Emit(name string, data any) {
	if f != nil {
		f(name, data)
	}
}

// App 是生产内核装配体，可被多个网关请求并发访问。
type App struct {
	g    *gateway.Gateway
	sink EventSink
	log  *diag.Logger
	rec  *diag.Recorder

	// startMu 串行化 Start / Stop，避免重复装配。
	startMu sync.Mutex

	mu       sync.RWMutex
	cfg      Config
	started  bool
	state    string
	account  *identity.Account
	keys     identity.KeyStore
	devKey   lpcrypto.PrivKey
	db       *sql.DB
	dao      *store.DAO
	host     host.Host
	dht      *dht.IpfsDHT
	dmSvc    *dm.Service
	groupSvc *group.Service
	contacts *contacts.Service
	sm       *netnode.StateMachine
	lookup   dm.PeerResolver
	// groupTargets / groupXPub 是群密钥信封投递的目标解析器；
	// groupTargets 可由平台层注入，未注入时基于索引服务档案 + DHT 默认实现。
	groupTargets group.TargetResolver
	groupXPub    group.XPubResolver
	// offline 是公开档案与上传票据的刷新器；未接入索引服务时为 nil。
	offline *offlinePublisher
	// dir 是索引服务客户端；未配置 directory_url 时为 nil（举报等上行能力降级）。
	dir *directory.Client
	// expiryCancel / expiryDone 管理定时消息清理协程（推荐功能：定时消息）。
	expiryCancel context.CancelFunc
	expiryDone   chan struct{}
}

// expirySweepInterval 是定时消息清理扫描间隔。消息到期后最多延迟一个间隔被销毁；
// 扫描走 expires_at 索引，成本与到期消息数成正比。
const expirySweepInterval = 30 * time.Second

// New 创建装配体并注册所有网关方法；此时内核尚未启动。
func New(g *gateway.Gateway, sink EventSink) (*App, error) {
	if g == nil {
		return nil, errors.New("缺少网关")
	}
	a := &App{
		g:     g,
		sink:  sink,
		log:   diag.New(diag.WithBufferSize(2048)),
		state: string(netnode.StateInit),
	}
	a.rec = diag.NewRecorder(a.log)

	binds := []struct {
		name string
		fn   func() error
	}{
		{"diag", func() error { return diag.Bind(g, a.rec) }},
		{"blob", func() error { return blob.Bind(g) }},
		{"msg", func() error {
			return msg.Bind(g, &msg.Service{
				DAO:          a.daoHandle,
				Account:      func() []byte { return a.accountPub() },
				ReadNotifier: a.notifyRead,
				OnRecalled:   a.onLocalRecall,
				OnEdited:     a.onLocalEdit,
			})
		}},
		{"backup", func() error { return backup.Bind(g, a.backupService()) }},
		{"contacts", func() error { return contacts.BindProvider(g, a.contactsService) }},
		{"dm", func() error { return dm.Bind(g, &dm.Gateway{Service: a.dmService, Resolve: a.resolvePeer}) }},
		{"group", func() error {
			return group.Bind(g, &group.Gateway{Service: a.groupService, Resolve: a.resolveGroupTarget})
		}},
	}
	for _, b := range binds {
		if err := b.fn(); err != nil {
			return nil, fmt.Errorf("注册 %s 能力: %w", b.name, err)
		}
	}
	coreHandlers := map[string]gateway.HandlerFunc{
		"core.start":        a.startHandler(),
		"core.stop":         a.stopHandler(),
		"account.devices":   a.accountDevicesHandler(),
		"account.me":        a.accountHandler(),
		"account.qrPayload": a.qrPayloadHandler(),
		"account.qrParse":   a.qrParseHandler(),
		"report.submit":     a.reportHandler(),
		"push.register":     a.pushRegisterHandler(),
		"push.unregister":   a.pushUnregisterHandler(),
		"storage.get":       a.storageGetHandler(),
		"storage.configure": a.storageConfigureHandler(),
		"settings.get":      a.settingsGetHandler(),
		"settings.set":      a.settingsSetHandler(),
		"settings.exportSnapshot": a.settingsExportHandler(),
		"settings.importSnapshot": a.settingsImportHandler(),
	}
	for method, h := range coreHandlers {
		if err := g.SetHandler(method, h); err != nil {
			return nil, fmt.Errorf("注册 %s: %w", method, err)
		}
	}
	return a, nil
}

// SetPeerResolver 注入对端账号解析器；须在 core.start 之前调用。
func (a *App) SetPeerResolver(r dm.PeerResolver) {
	a.mu.Lock()
	a.lookup = r
	a.mu.Unlock()
}

// SetGroupTargetResolver 注入群成员目标解析器；须在 core.start 之前调用。
// 未注入时使用索引服务档案 + DHT 的默认实现。
func (a *App) SetGroupTargetResolver(r group.TargetResolver) {
	a.mu.Lock()
	a.groupTargets = r
	a.mu.Unlock()
}

// State 返回当前内核状态（init/starting/online/degraded/offline/stopped）。
func (a *App) State() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.state
}

// Account 返回当前账号；未启动时为 nil。
func (a *App) Account() *identity.Account {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.account
}

// PeerID 返回当前设备 PeerID；未启动时为空串。
func (a *App) PeerID() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.host == nil {
		return ""
	}
	return a.host.ID().String()
}

// Logger 返回结构化日志器，供平台层追加记录。
func (a *App) Logger() *diag.Logger { return a.log }

// Start 启动内核；重复调用是幂等的，直接返回当前状态。
func (a *App) Start(ctx context.Context, cfg Config) (string, error) {
	a.startMu.Lock()
	defer a.startMu.Unlock()

	if a.isStarted() {
		return a.State(), nil
	}
	if strings.TrimSpace(cfg.DataDir) == "" {
		return "", ErrDataDirRequired
	}
	cfg = cfg.withDefaults()
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return "", fmt.Errorf("创建数据目录: %w", err)
	}

	// 逐步装配；任一步失败都回滚已创建的资源，避免半启动状态。
	var cleanups []func()
	cleanup := func() {
		for i := len(cleanups) - 1; i >= 0; i-- {
			cleanups[i]()
		}
	}

	ks := identity.NewKeyStore(filepath.Join(cfg.DataDir, "keystore.master"))
	acc, err := identity.LoadOrCreateSealedAccount(filepath.Join(cfg.DataDir, "account.sealed"), ks)
	if err != nil {
		return "", fmt.Errorf("加载账号: %w", err)
	}
	// 配置页保存的离线存储配置在显式入参缺失时生效（P6-04）。
	if cfg.Storage == nil {
		a.applyStoredStorage(cfg.DataDir, ks, &cfg)
	}
	devKey, err := loadDeviceKey(cfg.DataDir, acc)
	if err != nil {
		return "", fmt.Errorf("加载设备密钥: %w", err)
	}
	db, err := store.Open(filepath.Join(cfg.DataDir, "nexmem.db"))
	if err != nil {
		return "", fmt.Errorf("打开本地库: %w", err)
	}
	cleanups = append(cleanups, func() { _ = db.Close() })
	if err := store.Migrate(ctx, db); err != nil {
		cleanup()
		return "", fmt.Errorf("执行数据库迁移: %w", err)
	}
	dao := store.NewDAO(db)
	// P6-40：从账号 x25519 私钥派生字段加密器，透明保护本地明文元数据
	// （联系人备注/分组、会话与群标题、群公告/备注）。密钥源选账号私钥而非
	// 设备 keystore 主密钥：账号随加密备份迁移，换设备恢复后仍是同一把密钥，
	// 源设备写入的字段密文因此可解封（P6-05 备份恢复 + P6-41 多端共用前提）。
	// 字段密钥经域隔离派生，与 x25519 的离线消息 ECDH 用途互不干扰。
	// 派生失败不应阻断启动——退回明文兼容模式，旧库数据仍可读（不伪造加密能力）。
	if acc != nil {
		if cipher, cipherErr := store.NewFieldCipher(acc.XPriv()); cipherErr == nil {
			dao.SetFieldCipher(cipher)
		} else {
			a.log.Debug("core", "字段加密器初始化失败，退回明文兼容模式",
				map[string]any{"error": cipherErr.Error()})
		}
	}
	// 群盘后台拉取在 group.New 内立即启动一次，回调可能早于装配收尾，
	// 因此先暴露 DAO，避免「上线补齐」的首批群消息因本地库未就绪而丢失。
	a.mu.Lock()
	a.dao = dao
	a.mu.Unlock()
	cleanups = append(cleanups, func() {
		a.mu.Lock()
		a.dao = nil
		a.mu.Unlock()
	})
	contactSvc, err := contacts.New(dao)
	if err != nil {
		cleanup()
		return "", fmt.Errorf("初始化联系人服务: %w", err)
	}
	// 中继开关与地址来自设置页（P6-20）；显式入参优先，默认保持关闭。
	a.applyStoredRelay(ctx, dao, &cfg)

	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey:       devKey,
		Listen:           cfg.Listen,
		UserAgent:        DefaultUserAgent,
		EnableNATService: cfg.EnableNAT,
		EnableHolePunch:  cfg.EnableHolePunch,
		Relay:            relayPolicy(cfg.RelayAddrs),
		ConnLow:          cfg.ConnLow,
		ConnHigh:         cfg.ConnHigh,
	})
	if err != nil {
		cleanup()
		return "", fmt.Errorf("启动 P2P 主机: %w", err)
	}
	cleanups = append(cleanups, func() { _ = h.Close() })

	bootstraps := parseAddrInfos(cfg.Bootstraps)
	var kad *dht.IpfsDHT
	if len(bootstraps) > 0 {
		kad, err = netnode.NewDHT(ctx, h, dht.ModeClient, bootstraps)
		if err != nil {
			cleanup()
			return "", fmt.Errorf("启动 DHT: %w", err)
		}
		cleanups = append(cleanups, func() { _ = kad.Close() })
	}

	lookup, xpubResolver, dirClient, err := a.buildResolvers(cfg, acc, kad)
	if err != nil {
		cleanup()
		return "", err
	}

	bucket, err := buildBucket(cfg.Storage, a.rec)
	if err != nil {
		cleanup()
		return "", err
	}

	dmOpts := dm.Options{
		Host:        h,
		DeviceKey:   devKey,
		DAO:         dao,
		Account:     acc,
		InboxDir:    cfg.InboxDir,
		Blocklist:   contactSvc,
		Diag:        a.log,
		Resolver:    lookup,
		OnDelivery:  a.onDelivery,
		OnProgress:  a.onProgress,
		OnMessage:   a.onInbound,
		OnRead:      a.onReadReceipt,
		OnRecall:    a.onRecallReceived,
		OnTyping:    a.onTypingReceived,
		OnEdit:      a.onEditReceived,
		OnRTCSignal: a.onRTCSignal,
		OnGroupMeta: a.acceptGroupMeta,
		// P3 门禁：桶用量与票据消耗经 diag.snapshot 可观测。
		OnOfflineUpload: func(bytes int64, ok bool) { a.rec.ObserveOfflineUpload(bytes, ok) },
		OnTicketTake:    func(n int) { a.rec.ObserveTicketTake(n) },
	}
	if bucket != nil {
		// 接收方收件箱拉取只依赖本机桶；发送端离线投递还需索引服务。
		dmOpts.Inbox = bucket
		dmOpts.DeleteAfterRead = cfg.Storage.DeleteAfterRead
		dmOpts.FetchInterval = dm.DefaultOfflineFetchInterval
		if dirClient != nil {
			dmOpts.Directory = dirClient
			dmOpts.Uploader = bucket
			dmOpts.Waker = dirClient
			dmOpts.OfflineTTL = dm.DefaultOfflineTTL
		}
	}
	dmSvc, err := dm.New(dmOpts)
	if err != nil {
		cleanup()
		return "", fmt.Errorf("初始化单聊服务: %w", err)
	}
	cleanups = append(cleanups, dmSvc.Close)

	groupSvc, err := group.New(group.Options{
		Host:          h,
		Account:       acc,
		Members:       group.MemberFunc(a.groupMembers),
		DeviceKey:     devKey,
		DAO:           dao,
		XPub:          xpubResolver,
		OnMessage:     a.onGroupMessage,
		OnSent:        a.onGroupSent,
		OnStorage:     a.onGroupStorage,
		OnGroupKey:    a.onGroupKey,
		MetaSender:    dmSvc,
		PeerResolver:  groupWarmupResolver{lookup: lookup},
		FetchInterval: 30 * time.Second,
	})
	if err != nil {
		cleanup()
		return "", fmt.Errorf("初始化群聊服务: %w", err)
	}
	cleanups = append(cleanups, groupSvc.Close)
	if err := groupSvc.LoadKeys(ctx); err != nil {
		cleanup()
		return "", fmt.Errorf("加载群密钥: %w", err)
	}
	if _, err := groupSvc.SubscribeAll(ctx); err != nil {
		// 单个群订阅失败不阻断启动，运行期仍可在收到消息或手动操作时重试。
		a.log.Warn("group", "恢复群订阅存在失败", map[string]any{"error": err.Error()})
	}

	sm := netnode.NewStateMachine(netnode.StateOptions{
		Probe: netnode.HostProbe(h),
		OnChange: func(s netnode.State) {
			a.setState(string(s))
			a.emit("state.changed", netnode.StateEventData{State: s})
		},
	})
	if err := sm.Start(ctx); err != nil {
		cleanup()
		return "", fmt.Errorf("启动状态机: %w", err)
	}
	cleanups = append(cleanups, sm.Stop)

	// 档案中的 device_pub 约定为 libp2p 公钥的 protobuf 编码，
	// 解析端可直接推出设备 PeerID；不能写 Raw()，否则对端无法解析。
	devPub, err := lpcrypto.MarshalPublicKey(devKey.GetPublic())
	if err != nil {
		cleanup()
		return "", fmt.Errorf("编码设备公钥: %w", err)
	}
	offline := newOfflinePublisher(dirClient, bucket, acc, devPub, h.ID().String(), cfg.DeviceName, offlineEnabled(cfg), storagePublic(cfg), a.log)
	if offline != nil {
		offline.start()
		cleanups = append(cleanups, offline.close)
	}

	a.mu.Lock()
	a.cfg = cfg
	a.keys = ks
	a.account = acc
	a.devKey = devKey
	a.db = db
	a.dao = dao
	a.host = h
	a.dht = kad
	a.dmSvc = dmSvc
	a.groupSvc = groupSvc
	a.contacts = contactSvc
	a.sm = sm
	a.offline = offline
	a.dir = dirClient
	if a.lookup == nil {
		a.lookup = lookup
	}
	if a.groupXPub == nil {
		a.groupXPub = xpubResolver
	}
	if a.groupTargets == nil && lookup != nil {
		a.groupTargets = defaultGroupTargets{peer: lookup, xpub: xpubResolver}
	}
	a.started = true
	a.state = string(sm.State())
	state := a.state
	a.mu.Unlock()

	// 定时消息清理协程：到期后物理删除本机副本并发 message.expired（七-4）。
	a.startExpirySweeper(dao)

	a.log.Info("core", "内核已启动", map[string]any{
		"account_id": acc.ID(),
		"peer_id":    h.ID().String(),
		"state":      state,
	})
	a.emit("state.changed", netnode.StateEventData{State: netnode.State(state)})
	return state, nil
}

// Stop 停止内核并释放 host 与数据库句柄；重复调用是幂等的。
func (a *App) Stop() error {
	a.startMu.Lock()
	defer a.startMu.Unlock()

	a.mu.Lock()
	if !a.started {
		a.mu.Unlock()
		return nil
	}
	dmSvc, groupSvc, sm, kad, h, db := a.dmSvc, a.groupSvc, a.sm, a.dht, a.host, a.db
	offline := a.offline
	expiryCancel, expiryDone := a.expiryCancel, a.expiryDone
	a.expiryCancel, a.expiryDone = nil, nil
	a.cfg = Config{}
	a.keys = nil
	a.account = nil
	a.devKey = nil
	a.db = nil
	a.dao = nil
	a.host = nil
	a.dht = nil
	a.dmSvc = nil
	a.groupSvc = nil
	a.contacts = nil
	a.sm = nil
	a.offline = nil
	a.dir = nil
	a.started = false
	a.state = string(netnode.StateStopped)
	a.mu.Unlock()

	if expiryCancel != nil {
		expiryCancel()
	}
	// 等清理协程退出后再关闭 db，避免它仍在使用数据库句柄。
	if expiryDone != nil {
		<-expiryDone
	}
	if offline != nil {
		offline.close()
	}
	if groupSvc != nil {
		groupSvc.Close()
	}
	if dmSvc != nil {
		dmSvc.Close()
	}
	if sm != nil {
		sm.Stop()
	}
	if kad != nil {
		_ = kad.Close()
	}
	if h != nil {
		_ = h.Close()
	}
	if db != nil {
		_ = db.Close()
	}
	a.log.Info("core", "内核已停止", nil)
	a.emit("state.changed", netnode.StateEventData{State: netnode.StateStopped})
	return nil
}

// Close 等价于 Stop，便于 defer 使用。
func (a *App) Close() error { return a.Stop() }

func (a *App) isStarted() bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.started
}

func (a *App) setState(s string) {
	a.mu.Lock()
	a.state = s
	a.mu.Unlock()
}

func (a *App) emit(name string, data any) {
	if a.sink != nil {
		a.sink.Emit(name, data)
	}
}

func (a *App) daoHandle() *store.DAO {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.dao
}

func (a *App) contactsService() *contacts.Service {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.contacts
}

func (a *App) dmService() *dm.Service {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.dmSvc
}

func (a *App) dbHandle() *sql.DB {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.db
}

func (a *App) accountHandle() *identity.Account {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.account
}

// accountPub 返回本机账号公钥；内核未启动时返回 nil。
func (a *App) accountPub() []byte {
	acc := a.accountHandle()
	if acc == nil {
		return nil
	}
	return acc.Pub()
}

func (a *App) backupService() *backup.Service {
	return &backup.Service{
		DB:      a.dbHandle,
		Account: a.accountHandle,
		OnRestoredAccount: func(acc *identity.Account) error {
			a.mu.RLock()
			keys := a.keys
			cfg := a.cfg
			a.mu.RUnlock()
			if keys == nil {
				return errors.New("内核尚未启动")
			}
			if err := identity.SaveSealedAccount(filepath.Join(cfg.DataDir, "account.sealed"), acc, keys); err != nil {
				return err
			}
			// 账号被替换后旧设备密钥无法解封，需清理以便重启时重建，否则恢复后无法启动。
			return rotateDeviceKeyIfStale(cfg.DataDir, acc)
		},
	}
}

// resolvePeer 把对端账号解析为可直连地址；未注入解析器时返回不可达，
// 由单聊层决定是否改走离线投递。
func (a *App) resolvePeer(ctx context.Context, accountPub []byte) (dm.Target, error) {
	a.mu.RLock()
	lookup := a.lookup
	a.mu.RUnlock()
	if lookup == nil {
		return dm.Target{}, fmt.Errorf("%w: 未配置对端解析器", dm.ErrPeerUnreached)
	}
	t, err := lookup.ResolvePeer(ctx, accountPub)
	if err != nil {
		return dm.Target{}, err
	}
	t.AccountPub = accountPub
	return t, nil
}

// buildResolvers 优先使用平台注入的解析器；否则在配置了索引服务时
// 用目录档案中的设备公钥 + DHT 定位对端，并用同一档案解析账号 X25519 公钥。
// 索引服务客户端独立创建：即使没有 DHT，也能发布档案与走离线通道。
func (a *App) buildResolvers(cfg Config, acc *identity.Account, kad *dht.IpfsDHT) (dm.PeerResolver, group.XPubResolver, *directory.Client, error) {
	a.mu.RLock()
	injected := a.lookup
	injectedXPub := a.groupXPub
	a.mu.RUnlock()

	var client *directory.Client
	if strings.TrimSpace(cfg.DirectoryURL) != "" {
		c, err := directory.New(directory.Config{BaseURL: cfg.DirectoryURL, Signer: acc})
		if err != nil {
			return nil, nil, nil, fmt.Errorf("初始化索引服务客户端: %w", err)
		}
		client = c
	}

	if injected != nil {
		xpub := injectedXPub
		if xpub == nil && client != nil {
			xpub = directoryXPub{client: client}
		}
		return injected, xpub, client, nil
	}
	if client == nil || kad == nil {
		xpub := injectedXPub
		if xpub == nil && client != nil {
			xpub = directoryXPub{client: client}
		}
		return nil, xpub, client, nil
	}
	return newDirectoryResolver(client, kad), directoryXPub{client: client}, client, nil
}

// buildBucket 按启动配置创建本机离线存储客户端；未配置时返回 nil。
func buildBucket(sc *StorageConfig, rec *diag.Recorder) (*blob.Client, error) {
	if sc == nil {
		return nil, nil
	}
	if strings.TrimSpace(sc.Endpoint) == "" || strings.TrimSpace(sc.Bucket) == "" {
		return nil, errors.New("离线存储配置缺少 endpoint 或 bucket")
	}
	var onResponse func(string, int)
	if rec != nil {
		onResponse = rec.ObserveS3
	}
	client, err := blob.New(blob.Config{
		Endpoint:   sc.Endpoint,
		Region:     sc.Region,
		Bucket:     sc.Bucket,
		AccessKey:  sc.AccessKey,
		SecretKey:  sc.SecretKey,
		PathStyle:  sc.PathStyle,
		OnResponse: onResponse,
	})
	if err != nil {
		return nil, fmt.Errorf("初始化离线存储客户端: %w", err)
	}
	return client, nil
}

// offlineEnabled 判断是否对外声明可接收离线消息；未显式配置时随存储配置。
func offlineEnabled(cfg Config) bool {
	if cfg.OfflineEnabled != nil {
		return *cfg.OfflineEnabled
	}
	return cfg.Storage != nil
}

// storagePublic 返回本机离线存储是否对外公开；未显式配置时默认公开。
// 关闭后公开档案撤回离线能力，对端只会走在线直连。
func storagePublic(cfg Config) bool {
	if cfg.Storage != nil && cfg.Storage.Public != nil {
		return *cfg.Storage.Public
	}
	return true
}

// groupService 返回群聊服务；未启动时为 nil。
func (a *App) groupService() *group.Service {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.groupSvc
}

// groupMembers 是群聊服务的成员来源：始终以本地库为准，
// 保证入群、踢人、密钥轮换后成员校验立即生效。
func (a *App) groupMembers(ctx context.Context, groupID []byte) ([][]byte, error) {
	dao := a.daoHandle()
	if dao == nil {
		return nil, errors.New("本地库尚未就绪")
	}
	rows, err := dao.ListMembers(ctx, groupID)
	if err != nil {
		return nil, err
	}
	out := make([][]byte, 0, len(rows))
	for _, m := range rows {
		out = append(out, append([]byte(nil), m.AccountPub...))
	}
	return out, nil
}

// resolveGroupTarget 把成员账号解析为群密钥信封投递目标。
func (a *App) resolveGroupTarget(ctx context.Context, accountPub []byte) (group.KeyTarget, error) {
	a.mu.RLock()
	r := a.groupTargets
	a.mu.RUnlock()
	if r == nil {
		return group.KeyTarget{}, errors.New("未配置群成员目标解析器")
	}
	t, err := r.ResolveTarget(ctx, accountPub)
	if err != nil {
		return group.KeyTarget{}, err
	}
	t.AccountPub = accountPub
	return t, nil
}

// acceptGroupMeta 受理经单聊通道到达的群密钥信封（P4-08）。
func (a *App) acceptGroupMeta(env *nexmemv1.GroupKeyEnvelope) error {
	svc := a.groupService()
	if svc == nil {
		return errors.New("群聊服务尚未启动")
	}
	_, _, err := svc.AcceptKeyEnvelope(context.Background(), env)
	return err
}

// onGroupMessage 把入站群消息写入本地库并转发为 message.new 事件。
// 群撤回控制帧不落库，只删除本机命中的原消息并发出 message.recalled（P6-14）；
// 群解散控制帧校验发送方为管理员后清理本地群并发出 group.dissolved（P4-12）；
// 群公告控制帧校验发送方为管理员后更新本机公告并发出 group.announcement（P6-26）。
func (a *App) onGroupMessage(ev group.Received) {
	if group.IsDissolveNotice(ev.Plaintext) {
		a.handleGroupDissolved(ev)
		return
	}
	if text, ok := group.ParseAnnouncementNotice(ev.Plaintext); ok {
		a.handleGroupAnnouncement(ev, text)
		return
	}
	if target, ok := group.ParseRecallNotice(ev.Plaintext); ok {
		ok, err := applyGroupRecall(context.Background(), a.daoHandle(), ev, target)
		if err != nil {
			a.log.Warn("group", "群撤回本地处理失败", map[string]any{
				"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
				"msg_uuid": target,
				"error":    err.Error(),
			})
		}
		if ok {
			a.emit("message.recalled", map[string]any{
				"conversation_id": groupConversationID(ev.GroupID),
				"msg_uuid":        target,
			})
		}
		return
	}
	if err := a.persistInboundGroupMessage(context.Background(), ev); err != nil {
		a.log.Warn("group", "群消息本地入库失败", map[string]any{
			"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
			"msg_uuid": ev.MsgUUID,
			"error":    err.Error(),
		})
	}
	a.emit("message.new", map[string]any{
		"conversation_id": groupConversationID(ev.GroupID),
		"msg_uuid":        ev.MsgUUID,
		"direction":       "in",
	})
}

// handleGroupDissolved 处理入站群解散帧（P4-12）：只有本地成员表登记为
// 管理员的账号才能解散；校验通过后清理本地群、密钥与会话条目，并发出事件。
func (a *App) handleGroupDissolved(ev group.Received) {
	svc := a.groupService()
	if svc == nil {
		return
	}
	ctx := context.Background()
	admin, err := svc.IsGroupAdmin(ctx, ev.GroupID, ev.SenderAccount)
	if err != nil || !admin {
		a.log.Warn("group", "忽略非管理员解散通知", map[string]any{
			"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
			"sender":   base64.RawURLEncoding.EncodeToString(ev.SenderAccount),
			"error":    errString(err),
		})
		return
	}
	if err := svc.LeaveGroup(ctx, ev.GroupID); err != nil {
		a.log.Warn("group", "群解散本地清理失败", map[string]any{
			"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
			"error":    err.Error(),
		})
		return
	}
	convID := groupConversationID(ev.GroupID)
	if dao := a.daoHandle(); dao != nil {
		if err := dao.DeleteConversation(ctx, convID); err != nil && !errors.Is(err, store.ErrNotFound) {
			a.log.Warn("group", "删除已解散群的会话失败", map[string]any{
				"conversation_id": convID,
				"error":           err.Error(),
			})
		}
	}
	a.emit("group.dissolved", map[string]any{
		"conversation_id": convID,
		"group_id":        base64.RawURLEncoding.EncodeToString(ev.GroupID),
	})
}

// handleGroupAnnouncement 处理入站群公告帧（P6-26）：仅接受本地成员表里登记的
// 管理员发来的公告；更新本机 groups.announcement 后发出 group.announcement。
// 公告正文属于加密正文的一部分，日志只记录群 ID 与发送方，不打印明文。
func (a *App) handleGroupAnnouncement(ev group.Received, text string) {
	svc := a.groupService()
	if svc == nil {
		return
	}
	ctx := context.Background()
	applied, err := svc.ApplyAnnouncement(ctx, ev.GroupID, ev.SenderAccount, text)
	if err != nil {
		a.log.Warn("group", "群公告本地处理失败", map[string]any{
			"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
			"sender":   base64.RawURLEncoding.EncodeToString(ev.SenderAccount),
			"error":    err.Error(),
		})
		return
	}
	if !applied {
		a.log.Warn("group", "忽略非管理员群公告", map[string]any{
			"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
			"sender":   base64.RawURLEncoding.EncodeToString(ev.SenderAccount),
		})
		return
	}
	a.emit("group.announcement", map[string]any{
		"group_id":     base64.RawURLEncoding.EncodeToString(ev.GroupID),
		"announcement": text,
	})
}

// errString 把可能为 nil 的错误转为日志字段值。
func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// onGroupSent 把本机发出的群消息写入本地库（P1-20 / P4 本地持久化）。
// 群控制帧只用于通知群成员，不在本机生成聊天气泡。
// 失败只记录告警，不影响已经成功的广播。
func (a *App) onGroupSent(ev group.SentEvent) {
	if group.IsControlFrame(ev.Plaintext) {
		return
	}
	if err := a.persistOutboundGroupMessage(context.Background(), ev); err != nil {
		a.log.Warn("group", "群消息本地入库失败", map[string]any{
			"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
			"msg_uuid": ev.MsgUUID,
			"error":    err.Error(),
		})
	}
}

// persistInboundGroupMessage 幂等写入入站群消息；没有对应版本密钥时跳过。
func (a *App) persistInboundGroupMessage(ctx context.Context, ev group.Received) error {
	if len(ev.Plaintext) == 0 {
		return nil
	}
	dao := a.daoHandle()
	if dao == nil {
		return errors.New("本地库尚未就绪")
	}
	// A-02：群消息正文是 InnerMessage 序列化字节。若能解出附件元数据则按附件消息
	// 落库；七-1/七-2：带 \x02 前缀的结构化正文含 mentions / edited 字段，原样还原。
	// 普通文本消息回退 InnerMessage{Text: plaintext}（兼容历史消息）。
	var inner nexmemv1.InnerMessage
	isFile := ev.ContentType == int32(nexmemv1.ContentType_CONTENT_TYPE_FILE) ||
		(proto.Unmarshal(ev.Plaintext, &inner) == nil && len(inner.GetAttachments()) > 0)
	bodyEnc := ev.Plaintext
	bodyText := string(ev.Plaintext)
	contentType := int(nexmemv1.ContentType_CONTENT_TYPE_TEXT)
	if isFile {
		contentType = int(nexmemv1.ContentType_CONTENT_TYPE_FILE)
		if len(ev.Inner) > 0 {
			bodyEnc = ev.Inner
		}
	} else if structured, ok := group.DecodeInnerPlaintext(ev.Plaintext); ok {
		// 结构化正文：mentions / reply_to / edited 随 InnerMessage 原样落库。
		bodyText = structured.GetText()
		encoded, err := proto.Marshal(structured)
		if err != nil {
			return err
		}
		bodyEnc = encoded
	} else {
		encoded, err := proto.Marshal(&nexmemv1.InnerMessage{Text: bodyText})
		if err != nil {
			return err
		}
		bodyEnc = encoded
	}
	_, err := dao.AcceptInboundMessage(ctx, store.ConversationKindGroup, store.Message{
		MsgUUID:        ev.MsgUUID,
		ConversationID: groupConversationID(ev.GroupID),
		SenderAccount:  ev.SenderAccount,
		SentAt:         ev.SentAt,
		Direction:      store.DirectionIn,
		ContentType:    contentType,
		BodyEnc:        bodyEnc,
		State:          store.MessageStateReceived,
		ExpiresAt:      groupExpiry(bodyEnc, ev.SentAt),
		Body:           bodyText,
	})
	return err
}

// groupExpiry 从群消息正文 InnerMessage.ttl_hours 计算本机销毁时间；
// 正文无法解析或 TTL 越界时按永不过期处理。
func groupExpiry(bodyEnc []byte, sentAt int64) int64 {
	var inner nexmemv1.InnerMessage
	if proto.Unmarshal(bodyEnc, &inner) != nil {
		return 0
	}
	hours := inner.GetTtlHours()
	if expiry.Validate(hours) != nil {
		return 0
	}
	return expiry.ExpiresAt(sentAt, hours)
}

// startExpirySweeper 启动定时消息清理协程：启动即扫一次（清理重启前到期的消息），
// 之后每 expirySweepInterval 扫描一次。每条被删消息发一个 message.expired 事件，
// 客户端据此移除气泡。协程随 Stop 取消，退出时关闭 expiryDone。
func (a *App) startExpirySweeper(dao *store.DAO) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	a.mu.Lock()
	a.expiryCancel = cancel
	a.expiryDone = done
	a.mu.Unlock()

	go func() {
		defer close(done)
		sweep := func() {
			expired, err := dao.DeleteExpiredMessages(ctx, time.Now().UnixMilli())
			if err != nil {
				a.log.Debug("core", "定时消息清理失败", map[string]any{"error": err.Error()})
				return
			}
			for _, e := range expired {
				a.emit("message.expired", map[string]any{
					"conversation_id": e.ConversationID,
					"msg_uuid":        e.MsgUUID,
				})
			}
		}
		sweep()
		ticker := time.NewTicker(expirySweepInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				sweep()
			}
		}
	}()
}

// persistOutboundGroupMessage 写入本方群消息并推进会话时间与群标题。
func (a *App) persistOutboundGroupMessage(ctx context.Context, ev group.SentEvent) error {
	dao := a.daoHandle()
	if dao == nil {
		return errors.New("本地库尚未就绪")
	}
	convID := groupConversationID(ev.GroupID)
	bodyEnc := ev.Inner
	contentType := int(nexmemv1.ContentType_CONTENT_TYPE_TEXT)
	if len(bodyEnc) == 0 {
		encoded, err := proto.Marshal(&nexmemv1.InnerMessage{Text: string(ev.Plaintext)})
		if err != nil {
			return err
		}
		bodyEnc = encoded
	} else {
		contentType = int(ev.ContentType)
	}
	title := ""
	if g, gerr := dao.GetGroup(ctx, ev.GroupID); gerr == nil {
		title = g.Title
	}
	if err := dao.EnsureConversation(ctx, store.Conversation{
		ID:    convID,
		Kind:  store.ConversationKindGroup,
		Title: title,
	}); err != nil {
		return err
	}
	if err := dao.PutMessage(ctx, store.Message{
		MsgUUID:        ev.MsgUUID,
		ConversationID: convID,
		SenderAccount:  a.accountPub(),
		SentAt:         ev.SentAt,
		Direction:      store.DirectionOut,
		ContentType:    contentType,
		BodyEnc:        bodyEnc,
		State:          store.MessageStateSent,
		ExpiresAt:      groupExpiry(bodyEnc, ev.SentAt),
		Body:           string(ev.Plaintext),
	}); err != nil {
		return err
	}
	return dao.TouchConversation(ctx, convID, ev.SentAt)
}

// onGroupStorage 在群盘未落盘时记录告警，便于上层提示「仅在线可见」。
func (a *App) onGroupStorage(ev group.StorageEvent) {
	if ev.Err == nil {
		return
	}
	a.log.Warn("group", "群消息未写入群盘", map[string]any{
		"group_id": base64.RawURLEncoding.EncodeToString(ev.GroupID),
		"msg_uuid": ev.MsgUUID,
		"error":    ev.Err.Error(),
	})
}

// onGroupKey 记录入群/轮换事件；订阅由群聊服务自动完成。
func (a *App) onGroupKey(key group.GroupKey, meta group.GroupMeta) {
	a.log.Info("group", "受理群密钥", map[string]any{
		"group_id":    base64.RawURLEncoding.EncodeToString(key.GroupID),
		"key_version": key.Version,
		"title":       meta.Title,
	})
}

// groupConversationID 是群会话在 message.new 中的稳定标识。
func groupConversationID(groupID []byte) string {
	return "group:" + base64.RawURLEncoding.EncodeToString(groupID)
}

// onDelivery 把发送状态变化翻译为 message.updated 事件。
// reason 仅在确定性失败时出现（如对端未开启离线存储），供 UI 展示降级提示。
func (a *App) onDelivery(ev dm.DeliveryEvent) {
	data := map[string]any{
		"conversation_id": ev.ConversationID,
		"msg_uuid":        ev.MsgUUID,
		"state":           messageStateName(ev.State),
		"offline":         ev.Offline,
	}
	if ev.Reason != "" {
		data["reason"] = ev.Reason
	}
	a.emit("message.updated", data)
}

// onReadReceipt 把对端已读水位应用到本机出站消息，并逐条发出 message.updated（P6-07）。
func (a *App) onReadReceipt(ev dm.ReadEvent) {
	dao := a.daoHandle()
	if dao == nil {
		return
	}
	changed, err := dao.MarkConversationRead(context.Background(), ev.ConversationID, ev.UpTo)
	if err != nil {
		a.log.Warn("dm", "推进已读失败", map[string]any{
			"conversation_id": ev.ConversationID,
			"error":           err.Error(),
		})
		return
	}
	for _, id := range changed {
		a.emit("message.updated", map[string]any{
			"conversation_id": ev.ConversationID,
			"msg_uuid":        id,
			"state":           messageStateName(store.MessageStateRead),
		})
	}
}

// onRTCSignal 把收到的 RTC 信令转成 rtc.signal 事件（SDP / ICE 透传）。
func (a *App) onRTCSignal(ev dm.RTCSignalEvent) {
	a.emit("rtc.signal", map[string]any{
		"peer":        base64.RawURLEncoding.EncodeToString(ev.PeerAccount),
		"payload_b64": base64.StdEncoding.EncodeToString(ev.Payload),
	})
}

// onLocalRecall 在本机撤回成功后发出 message.recalled，并异步通知对端或群成员
// （P6-12 / P6-14）。
//
// 通知失败不影响本地撤回，也不阻塞请求；对端下次上线不会补发撤回，
// 与「撤回是尽力而为的在线能力」的语义一致。
func (a *App) onLocalRecall(conversationID, msgUUID string) {
	a.emit("message.recalled", map[string]any{
		"conversation_id": conversationID,
		"msg_uuid":        msgUUID,
	})
	if strings.HasPrefix(conversationID, "group:") {
		go a.notifyGroupRecall(conversationID, msgUUID)
		return
	}
	go a.notifyRecall(conversationID, msgUUID)
}

// onRecallReceived 处理对端撤回通知；消息已由 dm 层删除，这里只发事件（P6-12）。
func (a *App) onRecallReceived(ev dm.RecallEvent) {
	a.emit("message.recalled", map[string]any{
		"conversation_id": ev.ConversationID,
		"msg_uuid":        ev.MsgUUID,
	})
}

// onLocalEdit 在本机编辑成功后发出 message.edited，并异步通知对端/群成员（七-2）。
func (a *App) onLocalEdit(conversationID, msgUUID, text string, editedAt int64) {
	a.emit("message.edited", map[string]any{
		"conversation_id": conversationID,
		"msg_uuid":        msgUUID,
		"text":            text,
		"edited_at":       editedAt,
	})
	if strings.HasPrefix(conversationID, "group:") {
		// 群消息的编辑元数据已随结构化 InnerMessage 落库；在线成员通过 message.new
		// 增量拉取拿到更新。跨设备的群编辑广播作为尽力而为能力暂不实现（见文档口径）。
		return
	}
	go a.notifyEdit(conversationID, msgUUID, text, editedAt)
}

// onEditReceived 处理对端编辑通知：更新本机入站消息正文后发 message.edited（七-2）。
func (a *App) onEditReceived(ev dm.EditEvent) {
	if dao := a.daoHandle(); dao != nil {
		if msg, err := dao.GetMessage(context.Background(), ev.MsgUUID); err == nil {
			inner := &nexmemv1.InnerMessage{}
			if proto.Unmarshal(msg.BodyEnc, inner) != nil {
				inner = &nexmemv1.InnerMessage{}
			}
			inner.Text = ev.Text
			inner.Edited = true
			inner.EditedAt = ev.EditedAt
			if bodyEnc, err := proto.Marshal(inner); err == nil {
				_ = dao.UpdateMessageBody(context.Background(), ev.MsgUUID, ev.Text, bodyEnc)
			}
		}
	}
	a.emit("message.edited", map[string]any{
		"conversation_id": ev.ConversationID,
		"msg_uuid":        ev.MsgUUID,
		"text":            ev.Text,
		"edited_at":       ev.EditedAt,
	})
}

// onTypingReceived 处理对端输入状态并发 typing 事件（七-3）。
func (a *App) onTypingReceived(ev dm.TypingEvent) {
	a.emit("typing", map[string]any{
		"peer":   base64.RawURLEncoding.EncodeToString(ev.PeerAccount),
		"typing": ev.Typing,
	})
}

// notifyEdit 把编辑通知经单聊通道发给对端（七-2）。
func (a *App) notifyEdit(conversationID, msgUUID, text string, editedAt int64) {
	peerPub, ok := peerFromDMConversation(conversationID, a.accountPub())
	if !ok {
		return
	}
	svc := a.dmService()
	if svc == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), recallTimeout)
	defer cancel()
	target, err := a.resolvePeer(ctx, peerPub)
	if err != nil {
		return
	}
	_ = svc.SendEdit(ctx, target, msgUUID, text, editedAt)
}

// applyGroupRecall 按群撤回帧删除本机命中的原消息（P6-14）。
//
// 只接受「撤回帧发送者本人发出」且属于该群会话的入站消息，避免成员借撤回
// 控制帧删除他人的消息；目标消息不存在时返回 false，调用方无需提示。
func applyGroupRecall(ctx context.Context, dao *store.DAO, ev group.Received, target string) (bool, error) {
	if dao == nil {
		return false, errors.New("本地库尚未就绪")
	}
	msg, err := dao.GetMessage(ctx, target)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	if msg.ConversationID != groupConversationID(ev.GroupID) {
		return false, nil
	}
	if msg.Direction != store.DirectionIn || !bytes.Equal(msg.SenderAccount, ev.SenderAccount) {
		return false, nil
	}
	if err := dao.DeleteMessage(ctx, target); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// notifyGroupRecall 把撤回控制帧广播到群，并写入群盘供离线成员补收（P6-14）。
func (a *App) notifyGroupRecall(conversationID, msgUUID string) {
	groupID, ok := groupIDFromConversation(conversationID)
	if !ok {
		return
	}
	svc := a.groupService()
	if svc == nil {
		return
	}
	notice, err := group.EncodeRecallNotice(msgUUID)
	if err != nil {
		a.log.Warn("group", "群撤回帧编码失败", map[string]any{
			"conversation_id": conversationID,
			"msg_uuid":        msgUUID,
			"error":           err.Error(),
		})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), recallTimeout)
	defer cancel()
	if _, err := svc.PublishEncryptedStored(ctx, groupID, notice); err != nil {
		a.log.Warn("group", "群撤回通知广播失败", map[string]any{
			"conversation_id": conversationID,
			"msg_uuid":        msgUUID,
			"error":           err.Error(),
		})
	}
}

// groupIDFromConversation 从群会话标识还原群 ID。
func groupIDFromConversation(conversationID string) ([]byte, bool) {
	raw, ok := strings.CutPrefix(conversationID, "group:")
	if !ok || raw == "" {
		return nil, false
	}
	groupID, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil || len(groupID) == 0 {
		return nil, false
	}
	return groupID, true
}

// notifyRecall 把撤回通知经单聊通道发给对端（P6-12）。
func (a *App) notifyRecall(conversationID, msgUUID string) {
	peerPub, ok := peerFromDMConversation(conversationID, a.accountPub())
	if !ok {
		return
	}
	svc := a.dmService()
	if svc == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), recallTimeout)
	defer cancel()
	target, err := a.resolvePeer(ctx, peerPub)
	if err != nil {
		return
	}
	_ = svc.SendRecall(ctx, target, msgUUID)
}

// notifyRead 在已读位置推进后异步回传已读回执（P6-07）。
// 回执尽力而为：对端不可达只记日志，不回滚本地已读。
func (a *App) notifyRead(conversationID string, upTo int64) {
	if upTo <= 0 {
		return
	}
	peerPub, ok := peerFromDMConversation(conversationID, a.accountPub())
	if !ok {
		return
	}
	svc := a.dmService()
	if svc == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), readReceiptTimeout)
		defer cancel()
		target, err := a.resolvePeer(ctx, peerPub)
		if err != nil {
			a.log.Debug("dm", "已读回执解析对端失败", map[string]any{
				"conversation_id": conversationID,
				"error":           err.Error(),
			})
			return
		}
		if err := svc.SendReadReceipt(ctx, target, upTo); err != nil {
			a.log.Debug("dm", "已读回执发送失败", map[string]any{
				"conversation_id": conversationID,
				"error":           err.Error(),
			})
		}
	}()
}

// peerFromDMConversation 从 `dm:<hex>|<hex>` 反解对端账号公钥。
func peerFromDMConversation(conversationID string, self []byte) ([]byte, bool) {
	if len(self) == 0 || !strings.HasPrefix(conversationID, "dm:") {
		return nil, false
	}
	parts := strings.Split(strings.TrimPrefix(conversationID, "dm:"), "|")
	if len(parts) != 2 {
		return nil, false
	}
	a, err := hex.DecodeString(parts[0])
	if err != nil {
		return nil, false
	}
	b, err := hex.DecodeString(parts[1])
	if err != nil {
		return nil, false
	}
	if bytes.Equal(a, self) {
		return b, true
	}
	if bytes.Equal(b, self) {
		return a, true
	}
	return nil, false
}

// onProgress 转发文件传输进度。
func (a *App) onProgress(p dm.TransferProgress) {
	a.emit("transfer.progress", map[string]any{
		"msg_uuid": p.MsgUUID,
		"done":     p.Done,
		"total":    p.Total,
	})
}

// onInbound 转发入站消息（只给指针，正文由 UI 按需拉取）。
func (a *App) onInbound(ev dm.InboundEvent) {
	a.emit("message.new", map[string]any{
		"conversation_id": ev.ConversationID,
		"msg_uuid":        ev.MsgUUID,
		"direction":       "in",
	})
}

func messageStateName(state int) string {
	switch state {
	case store.MessageStatePending:
		return "pending"
	case store.MessageStateSent:
		return "sent"
	case store.MessageStateAcked:
		return "acked"
	case store.MessageStateFailed:
		return "failed"
	case store.MessageStateReceived:
		return "received"
	case store.MessageStateRead:
		return "read"
	default:
		return "unknown"
	}
}

// withDefaults 填充启动配置默认值。
func (c Config) withDefaults() Config {
	if len(c.Listen) == 0 {
		c.Listen = []string{"/ip4/0.0.0.0/tcp/0", "/ip4/0.0.0.0/udp/0/quic-v1"}
	}
	if strings.TrimSpace(c.InboxDir) == "" {
		c.InboxDir = filepath.Join(c.DataDir, "inbox")
	}
	// 打洞是连通率的关键能力（project-memory：直连率 ≥60%），默认开启。
	c.EnableHolePunch = true
	return c
}

// relayPolicy 把中继地址列表翻译为 AutoRelay 策略。
func relayPolicy(addrs []string) netnode.RelayPolicy {
	infos := parseAddrInfos(addrs)
	if len(infos) == 0 {
		return netnode.RelayPolicy{}
	}
	return netnode.RelayPolicy{Enabled: true, Relays: infos}
}

// parseAddrInfos 解析 multiaddr 形式的节点地址；非法条目被忽略并记录日志。
func parseAddrInfos(addrs []string) []peer.AddrInfo {
	out := make([]peer.AddrInfo, 0, len(addrs))
	for _, raw := range addrs {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		ai, err := peer.AddrInfoFromString(raw)
		if err != nil {
			continue
		}
		out = append(out, *ai)
	}
	return out
}

// resolveAttempts 是 DHT 解析冷启动重试间隔（index 0 立即执行）。
var resolveAttempts = []time.Duration{0, 500 * time.Millisecond, 1500 * time.Millisecond}
