package group

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"

	pubsub "github.com/libp2p/go-libp2p-pubsub"
	pubsubpb "github.com/libp2p/go-libp2p-pubsub/pb"
	libp2pcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

// memberIDSize 是账号 ed25519 公钥长度。
const memberIDSize = 32

// maxGossipMessageSize 与 wire.MaxFrameSize 对齐，限制 GossipSub 单条消息大小。
const maxGossipMessageSize = 1 << 20

// MemberSource 提供某个群的成员账号公钥列表。
type MemberSource interface {
	Members(ctx context.Context, groupID []byte) ([][]byte, error)
}

// MemberFunc 让普通函数实现 MemberSource。
type MemberFunc func(ctx context.Context, groupID []byte) ([][]byte, error)

// Members 实现 MemberSource。
func (f MemberFunc) Members(ctx context.Context, groupID []byte) ([][]byte, error) {
	return f(ctx, groupID)
}

// Received 是一条通过校验并首次送达的群消息。
type Received struct {
	GroupID       []byte
	SenderAccount []byte
	MsgUUID       string
	SentAt        int64
	KeyVersion    uint32
	Body          []byte
	// Plaintext 是解密后的正文。已启用密钥的群缺少对应版本密钥时消息会暂存，
	// 待密钥受理后再以明文交付；从未启用密钥的群保持明文为空的原样交付。
	Plaintext []byte
	// ContentType / Inner 用于群附件（C-02/A-02）：非文本消息时携带协议类型与
	// 序列化的 InnerMessage，供上层按附件落库；文本消息保持零值以兼容旧路径。
	ContentType int32
	Inner       []byte
}

// SentEvent 是本机群消息广播成功后的结果，供上层落本地库。
type SentEvent struct {
	GroupID   []byte
	MsgUUID   string
	SentAt    int64
	Plaintext []byte
	// ContentType / Inner 语义同 Received，供群附件落库。
	ContentType int32
	Inner       []byte
}

// Options 是创建群聊传输服务的依赖。
type Options struct {
	Host    host.Host
	Account *identity.Account
	Members MemberSource
	// DeviceKey 是设备 libp2p 私钥，用于签名密钥信封的帧；留空回退到 host 自身私钥。
	DeviceKey libp2pcrypto.PrivKey
	// Keys 是群密钥环；留空时新建一个空密钥环。
	Keys *Keyring
	// DAO 用于群密钥与成员表落库；留空表示仅内存模式。
	DAO *store.DAO
	// XPub 把成员账号公钥解析为 account_x_pub，供密钥信封分发使用。
	XPub XPubResolver
	// OnGroupKey 是受理新群密钥后的回调；回调由调用协程执行，需自行保证线程安全。
	OnGroupKey func(GroupKey, GroupMeta)
	// MaxAge 是信封发送时间允许的最大偏差，留空使用 DefaultMaxAge。
	MaxAge time.Duration
	// DedupeTTL 是入站指纹去重窗口，留空使用 DefaultDedupeTTL。
	DedupeTTL time.Duration
	// DedupeCapacity 是去重窗口容量，留空使用 DefaultDedupeCapacity。
	DedupeCapacity int
	// OnMessage 是首次送达回调；回调由订阅协程调用，需自行保证线程安全。
	OnMessage func(Received)
	// OnSent 是本机群消息广播成功后的回调，供上层写入本地库；
	// 回调由发布协程调用，需自行保证线程安全。
	OnSent func(SentEvent)
	// StorageFactory 按群盘配置创建对象存储客户端；留空使用 blob.New。
	StorageFactory func(StorageConfig) (ObjectStore, error)
	// OnStorage 是群盘写入结果回调，Err 非空表示本次未落盘；由调用协程执行。
	OnStorage func(StorageEvent)
	// MetaSender 把群密钥信封经单聊通道投递（支持对端离线），
	// 直连 /nexmem/group-meta/1.0.0 失败时作为兜底（P4-08）。
	MetaSender GroupMetaSender
	// DisableAutoSubscribe 关闭“受理密钥信封后自动订阅群主题”。
	DisableAutoSubscribe bool
	// FetchInterval 为群盘后台拉取间隔；为 0 时不启动后台拉取（P4-06）。
	FetchInterval time.Duration
	// PeerResolver 把群成员账号公钥解析为 PeerID + 地址，用于入群后的地址预热（P4-02）。
	// 留空表示不预热，此时仅依赖调用方自行建立连接。
	PeerResolver PeerResolver
	// WarmupInterval 是成员地址预热的重试间隔，留空使用 DefaultWarmupInterval。
	WarmupInterval time.Duration
	// WarmupWindow 是入群后的预热窗口，留空使用 DefaultWarmupWindow。
	WarmupWindow time.Duration
	// DisableAutoWarmup 关闭「订阅群主题后自动预热成员地址」。
	DisableAutoWarmup bool
	// Params 覆盖 GossipSub 参数，留空使用库默认值。
	Params *pubsub.GossipSubParams
}

// Service 是绑定在单个 libp2p host 上的群聊传输服务。
type Service struct {
	ctx          context.Context
	cancel       context.CancelFunc
	ps           *pubsub.PubSub
	host         host.Host
	account      *identity.Account
	members      MemberSource
	maxAge       time.Duration
	dedupe       *fingerprintCache
	pendingMsgs  *pendingMessages
	onMsg        func(Received)
	onSent       func(SentEvent)
	deviceKey    libp2pcrypto.PrivKey
	keys         *Keyring
	dao          *store.DAO
	xpubResolver XPubResolver
	onKey        func(GroupKey, GroupMeta)
	storageNew   func(StorageConfig) (ObjectStore, error)
	onStorage    func(StorageEvent)
	metaSender   GroupMetaSender
	noAutoSub    bool
	fetchMu      sync.Mutex
	fetchEvery   time.Duration
	peers        PeerResolver
	warmInterval time.Duration
	warmWindow   time.Duration
	noWarmup     bool
	warmups      map[string]context.CancelFunc

	mu       sync.Mutex
	closed   bool
	topics   map[string]*pubsub.Topic
	subs     map[string]*groupSub
	validity map[string]struct{}

	wait sync.WaitGroup
}

type groupSub struct {
	groupID []byte
	sub     *pubsub.Subscription
	cancel  context.CancelFunc
}

// New 创建群聊传输服务。创建的 GossipSub 实例独立于单聊流协议。
func New(opt Options) (*Service, error) {
	switch {
	case opt.Host == nil:
		return nil, errors.New("缺少 libp2p host")
	case opt.Account == nil:
		return nil, errors.New("缺少账号密钥")
	case opt.Members == nil:
		return nil, errors.New("缺少群成员来源")
	}
	maxAge := opt.MaxAge
	if maxAge <= 0 {
		maxAge = DefaultMaxAge
	}
	psOpts := []pubsub.Option{
		pubsub.WithMaxMessageSize(maxGossipMessageSize),
		pubsub.WithMessageIdFn(groupMessageID),
		pubsub.WithSeenMessagesTTL(2 * time.Minute),
	}
	if opt.Params != nil {
		psOpts = append(psOpts, pubsub.WithGossipSubParams(*opt.Params))
	}

	ctx, cancel := context.WithCancel(context.Background())
	ps, err := pubsub.NewGossipSub(ctx, opt.Host, psOpts...)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("创建 GossipSub: %w", err)
	}
	keys := opt.Keys
	if keys == nil {
		keys = NewKeyring()
	}
	warmInterval := opt.WarmupInterval
	if warmInterval <= 0 {
		warmInterval = DefaultWarmupInterval
	}
	warmWindow := opt.WarmupWindow
	if warmWindow <= 0 {
		warmWindow = DefaultWarmupWindow
	}
	s := &Service{
		ctx:          ctx,
		cancel:       cancel,
		ps:           ps,
		host:         opt.Host,
		account:      opt.Account,
		members:      opt.Members,
		maxAge:       maxAge,
		dedupe:       newFingerprintCache(opt.DedupeTTL, opt.DedupeCapacity),
		pendingMsgs:  newPendingMessages(),
		onMsg:        opt.OnMessage,
		onSent:       opt.OnSent,
		deviceKey:    deviceKeyFromHost(opt),
		keys:         keys,
		dao:          opt.DAO,
		xpubResolver: opt.XPub,
		onKey:        opt.OnGroupKey,
		storageNew:   opt.StorageFactory,
		onStorage:    opt.OnStorage,
		metaSender:   opt.MetaSender,
		noAutoSub:    opt.DisableAutoSubscribe,
		peers:        opt.PeerResolver,
		warmInterval: warmInterval,
		warmWindow:   warmWindow,
		noWarmup:     opt.DisableAutoWarmup,
		warmups:      make(map[string]context.CancelFunc),
		topics:       make(map[string]*pubsub.Topic),
		subs:         make(map[string]*groupSub),
		validity:     make(map[string]struct{}),
	}
	// 群密钥信封走独立流协议，与单聊消息通道隔离。
	opt.Host.SetStreamHandler(wire.PIDMeta, s.handleMetaStream)
	// 群盘后台拉取：启动即补齐一次，之后按间隔轮询（P4-06）。
	if opt.FetchInterval > 0 && opt.DAO != nil {
		s.fetchEvery = opt.FetchInterval
		s.wait.Add(1)
		go s.groupFetchLoop()
	}
	return s, nil
}

// groupMessageID 让 GossipSub 按 msg_uuid 去重；非群信封消息回退到库默认规则。
func groupMessageID(m *pubsubpb.Message) string {
	env := &nexmemv1.GroupEnvelope{}
	if err := proto.Unmarshal(m.GetData(), env); err != nil || len(env.GetMsgUuid()) == 0 {
		return pubsub.DefaultMsgIdFn(m)
	}
	return "nexmem-group/1:" + base64.RawURLEncoding.EncodeToString(env.GetMsgUuid())
}

// Subscribe 加入群主题并启动接收协程；重复调用幂等。
func (s *Service) Subscribe(ctx context.Context, groupID []byte) error {
	if len(groupID) == 0 {
		return ErrGroupIDRequired
	}
	name := TopicFor(groupID)

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("群聊服务已关闭")
	}
	if _, ok := s.subs[name]; ok {
		return nil
	}
	topic, err := s.ensureTopicLocked(name, groupID)
	if err != nil {
		return err
	}
	sub, err := topic.Subscribe()
	if err != nil {
		return fmt.Errorf("订阅群主题 %s: %w", name, err)
	}
	runCtx, cancel := context.WithCancel(s.ctx)
	gs := &groupSub{groupID: append([]byte(nil), groupID...), sub: sub, cancel: cancel}
	s.subs[name] = gs
	s.wait.Add(1)
	go s.readLoop(runCtx, name, gs)
	// 新成员入群后立即预热成员地址，使 mesh 尽快连通（P4-02）。
	s.startWarmupLocked(name, groupID)
	return nil
}

// Unsubscribe 取消订阅并退出接收协程；未订阅时为空操作。
func (s *Service) Unsubscribe(groupID []byte) {
	name := TopicFor(groupID)
	s.mu.Lock()
	gs, ok := s.subs[name]
	if ok {
		delete(s.subs, name)
		s.stopWarmupLocked(name)
	}
	s.mu.Unlock()
	if !ok {
		return
	}
	gs.cancel()
	gs.sub.Cancel()
}

// Publish 用本机账号签名并广播一条群消息，返回 msg_uuid（十六进制）。
func (s *Service) Publish(ctx context.Context, groupID []byte, body []byte, keyVersion uint32) (string, error) {
	env, uuid, err := s.buildEnvelope(ctx, groupID, body, keyVersion)
	if err != nil {
		return "", err
	}
	if err := s.publishEnvelope(ctx, groupID, env); err != nil {
		return "", err
	}
	return uuid, nil
}

// buildEnvelope 校验成员资格并构建签名后的群消息信封。
func (s *Service) buildEnvelope(ctx context.Context, groupID []byte, body []byte, keyVersion uint32) (*nexmemv1.GroupEnvelope, string, error) {
	if len(groupID) == 0 {
		return nil, "", ErrGroupIDRequired
	}
	if len(body) == 0 {
		return nil, "", ErrEmptyBody
	}
	if len(body) > MaxBodySize {
		return nil, "", ErrBodyTooLarge
	}
	ok, err := s.isMember(ctx, groupID, s.account.Pub())
	if err != nil {
		return nil, "", err
	}
	if !ok {
		return nil, "", ErrNotMember
	}

	uuid := make([]byte, 16)
	if _, err := rand.Read(uuid); err != nil {
		return nil, "", fmt.Errorf("生成 msg_uuid: %w", err)
	}
	env := &nexmemv1.GroupEnvelope{
		GroupId:       append([]byte(nil), groupID...),
		SenderAccount: s.account.Pub(),
		MsgUuid:       uuid,
		SentAt:        time.Now().UnixMilli(),
		KeyVersion:    keyVersion,
		Body:          append([]byte(nil), body...),
	}
	env.Signature = s.account.Sign(canonicalEnvelope(env))
	return env, hex.EncodeToString(uuid), nil
}

// publishEnvelope 把已签名的信封序列化后广播到群主题。
func (s *Service) publishEnvelope(ctx context.Context, groupID []byte, env *nexmemv1.GroupEnvelope) error {
	raw, err := proto.Marshal(env)
	if err != nil {
		return fmt.Errorf("序列化群信封: %w", err)
	}

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errors.New("群聊服务已关闭")
	}
	topic, err := s.ensureTopicLocked(TopicFor(groupID), groupID)
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if err := topic.Publish(ctx, raw); err != nil {
		return fmt.Errorf("发布群消息: %w", err)
	}
	return nil
}

// Close 取消全部订阅并关闭 GossipSub。
func (s *Service) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	subs := make([]*groupSub, 0, len(s.subs))
	for _, gs := range s.subs {
		subs = append(subs, gs)
	}
	s.subs = make(map[string]*groupSub)
	topics := make([]*pubsub.Topic, 0, len(s.topics))
	for _, t := range s.topics {
		topics = append(topics, t)
	}
	s.topics = make(map[string]*pubsub.Topic)
	s.mu.Unlock()

	s.cancel()
	for _, gs := range subs {
		gs.sub.Cancel()
	}
	for _, t := range topics {
		_ = t.Close()
	}
	s.wait.Wait()
	if s.host != nil {
		s.host.RemoveStreamHandler(wire.PIDMeta)
	}
}

// Peers 返回当前群主题的 mesh 邻居数，用于诊断与验收。
func (s *Service) Peers(groupID []byte) int {
	s.mu.Lock()
	topic, ok := s.topics[TopicFor(groupID)]
	s.mu.Unlock()
	if !ok {
		return 0
	}
	return len(topic.ListPeers())
}

// controlFramePeerWait 是群设置控制帧等待主题邻居的上限。
const controlFramePeerWait = 1500 * time.Millisecond

// publishControlFrame 广播幂等的群设置控制帧（公告、加好友开关、等级、成员资料）。
//
// GossipSub 在主题尚无邻居时 Publish 仍会成功入队，但帧不会送达任何成员；
// 管理员操作返回成功、成员侧却始终看不到变更的窗口正是从这里产生的。
// 广播前有界等待 mesh 形成；超时仍按原有语义尽力广播，离线成员由群盘补齐。
func (s *Service) publishControlFrame(ctx context.Context, groupID []byte, plaintext string) {
	if s.Peers(groupID) == 0 {
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		deadline := time.Now().Add(controlFramePeerWait)
		for time.Now().Before(deadline) {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			if s.Peers(groupID) > 0 {
				break
			}
		}
	}
	_, _ = s.PublishEncryptedStored(ctx, groupID, plaintext)
}

// ensureTopicLocked 加入主题并注册校验器；调用方必须持有 s.mu。
func (s *Service) ensureTopicLocked(name string, groupID []byte) (*pubsub.Topic, error) {
	if t, ok := s.topics[name]; ok {
		return t, nil
	}
	topic, err := s.ps.Join(name)
	if err != nil {
		return nil, fmt.Errorf("加入群主题 %s: %w", name, err)
	}
	if _, ok := s.validity[name]; !ok {
		gid := append([]byte(nil), groupID...)
		if err := s.ps.RegisterTopicValidator(name, func(ctx context.Context, _ peer.ID, msg *pubsub.Message) bool {
			return s.validate(ctx, gid, msg)
		}); err != nil {
			_ = topic.Close()
			return nil, fmt.Errorf("注册群主题校验器 %s: %w", name, err)
		}
		s.validity[name] = struct{}{}
	}
	s.topics[name] = topic
	return topic, nil
}

// readLoop 持续消费主题消息，去重后交给回调。
func (s *Service) readLoop(ctx context.Context, name string, gs *groupSub) {
	defer s.wait.Done()
	for {
		msg, err := gs.sub.Next(ctx)
		if err != nil {
			return
		}
		if msg.Local {
			continue
		}
		env := &nexmemv1.GroupEnvelope{}
		if err := proto.Unmarshal(msg.Data, env); err != nil {
			continue
		}
		// 本机发出的消息由发送侧自行入库，这里统一跳过，
		// 包括从 mesh 邻居回环回来的副本。
		if bytes.Equal(env.GetSenderAccount(), s.account.Pub()) {
			continue
		}
		if !bytes.Equal(env.GetGroupId(), gs.groupID) {
			continue
		}
		// 校验器已保证签名与成员资格；这里再做一次时间与签名复核，
		// 避免校验器被绕过或参数在运行期变化时投递非法消息。
		if err := VerifyEnvelope(env, time.Now(), s.maxAge); err != nil {
			continue
		}
		key := hex.EncodeToString(env.GetMsgUuid())
		if !s.dedupe.Add(key) {
			continue
		}
		if s.onMsg == nil {
			continue
		}
		raw, ok := s.keys.Get(env.GetGroupId(), env.GetKeyVersion())
		if !ok {
			// 本群已持有其他版本密钥时，说明是轮换信封晚于加密消息到达：
			// 先暂存，密钥受理后补解交付，否则消息会被静默丢弃且指纹已占位。
			// 本群从未启用密钥（旧测试与兼容路径）仍按原样交付。
			if _, _, encrypted := s.keys.Latest(env.GetGroupId()); encrypted {
				s.pendingMsgs.Add(pendingEnvelope{
					GroupID:       append([]byte(nil), env.GetGroupId()...),
					SenderAccount: append([]byte(nil), env.GetSenderAccount()...),
					MsgUUID:       key,
					SentAt:        env.GetSentAt(),
					KeyVersion:    env.GetKeyVersion(),
					Body:          append([]byte(nil), env.GetBody()...),
					Since:         time.Now(),
				}, time.Now())
				continue
			}
			s.onMsg(Received{
				GroupID:       append([]byte(nil), env.GetGroupId()...),
				SenderAccount: append([]byte(nil), env.GetSenderAccount()...),
				MsgUUID:       key,
				SentAt:        env.GetSentAt(),
				KeyVersion:    env.GetKeyVersion(),
				Body:          append([]byte(nil), env.GetBody()...),
			})
			continue
		}
		// 持有对应版本群密钥时顺带解密，上层无需再关心密码学细节。
		plaintext, err := OpenGroupBody(GroupKey{
			GroupID: env.GetGroupId(),
			Version: env.GetKeyVersion(),
			Key:     raw,
		}, env.GetBody())
		if err != nil {
			continue
		}
		s.onMsg(Received{
			GroupID:       append([]byte(nil), env.GetGroupId()...),
			SenderAccount: append([]byte(nil), env.GetSenderAccount()...),
			MsgUUID:       key,
			SentAt:        env.GetSentAt(),
			KeyVersion:    env.GetKeyVersion(),
			Body:          append([]byte(nil), env.GetBody()...),
			Plaintext:     plaintext,
		})
	}
}

// validate 是 GossipSub 主题校验器。
func (s *Service) validate(ctx context.Context, groupID []byte, msg *pubsub.Message) bool {
	env := &nexmemv1.GroupEnvelope{}
	if err := proto.Unmarshal(msg.Data, env); err != nil {
		return false
	}
	if !bytes.Equal(env.GetGroupId(), groupID) {
		return false
	}
	if err := VerifyEnvelope(env, time.Now(), s.maxAge); err != nil {
		return false
	}
	ok, err := s.isMember(ctx, groupID, env.GetSenderAccount())
	return err == nil && ok
}

// isMember 判断账号公钥是否属于该群。
func (s *Service) isMember(ctx context.Context, groupID, accountPub []byte) (bool, error) {
	if len(accountPub) != memberIDSize {
		return false, nil
	}
	list, err := s.members.Members(ctx, groupID)
	if err != nil {
		return false, fmt.Errorf("读取群成员: %w", err)
	}
	for _, m := range list {
		if bytes.Equal(m, accountPub) {
			return true, nil
		}
	}
	return false, nil
}
