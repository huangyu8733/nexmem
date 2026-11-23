package group

// 群密钥生成与分发（P4-03）。
//
// 群密钥是 32 字节对称密钥（AES-256），用于加密群消息正文与群元数据，
// P4-06 的群盘对象复用同一把密钥。分发时对每个成员的 account_x_pub 做
// X25519 + HKDF-SHA256 + AES-256-GCM 封装（crypto.WrapContentKey），
// 信封由管理员账号 ed25519 私钥签名，经 /nexmem/group-meta/1.0.0 流单播投递。
//
// 接收方用工信封内嵌的 admin_account 自洽验签，不需要提前信任传输对端；
// 解封后再校验自己确实在信封的成员表内，非成员因拿不到对应封装而必然失败。

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	libp2pcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

const (
	// GroupKeySize 群密钥长度（AES-256）。
	GroupKeySize = 32
	// KeyVersionInitial 是新建群的初始密钥版本。
	KeyVersionInitial uint32 = 1

	// KeyRoleMember / KeyRoleAdmin 与 groups.my_role、group_members.role 对应。
	KeyRoleMember = 0
	KeyRoleAdmin  = 1

	// keyEnvelopeDomain 做签名域隔离，避免信封签名被复用到其他协议。
	keyEnvelopeDomain = "nexmem/group-key-envelope/v1"
	// groupBodyDomain 是群消息正文 AES-GCM 的附加认证数据域名。
	groupBodyDomain = "nexmem/group-body/v1"
	// groupMetaDomain 是群元数据密封的附加认证数据域名。
	groupMetaDomain = "nexmem/group-meta/v1"

	// maxMetaSize 限制解密后的群元数据大小，避免恶意信封撑爆内存。
	maxMetaSize = 256 << 10
	// metaStreamTimeout 是密钥信封单次投递的流超时。
	metaStreamTimeout = 15 * time.Second

	// 密钥信封应答码，语义与 wire.proto 的 Ack.code 一致。
	metaAckOK     int32 = 0
	metaAckDup    int32 = 1
	metaAckReject int32 = 2
)

// 群密钥语义错误。
var (
	// ErrKeyEnvelopeInvalid 表示密钥信封字段非法、签名不符或解封失败。
	ErrKeyEnvelopeInvalid = errors.New("群密钥信封非法")
	// ErrNotKeyRecipient 表示密钥信封封装给了其他成员。
	ErrNotKeyRecipient = errors.New("群密钥信封不属于本机")
	// ErrGroupKeyNotFound 表示本地没有该群的可用密钥。
	ErrGroupKeyNotFound = errors.New("缺少群密钥")
	// ErrBadGroupKey 表示群密钥长度或版本非法。
	ErrBadGroupKey = errors.New("群密钥非法")
)

// GroupKey 是某个群在某一版本的对称密钥。
type GroupKey struct {
	GroupID []byte
	Version uint32
	Key     []byte
}

// NewGroupKey 生成一把新的随机群密钥。version 为 0 时使用 KeyVersionInitial。
func NewGroupKey(groupID []byte, version uint32) (GroupKey, error) {
	if len(groupID) == 0 {
		return GroupKey{}, ErrGroupIDRequired
	}
	if version == 0 {
		version = KeyVersionInitial
	}
	key := make([]byte, GroupKeySize)
	if _, err := rand.Read(key); err != nil {
		return GroupKey{}, fmt.Errorf("生成群密钥: %w", err)
	}
	return GroupKey{
		GroupID: append([]byte(nil), groupID...),
		Version: version,
		Key:     key,
	}, nil
}

// validate 校验群密钥的基本约束。
func (k GroupKey) validate() error {
	if len(k.GroupID) == 0 {
		return ErrGroupIDRequired
	}
	if k.Version == 0 {
		return fmt.Errorf("%w: 版本为 0", ErrBadGroupKey)
	}
	if len(k.Key) != GroupKeySize {
		return fmt.Errorf("%w: 长度 %d", ErrBadGroupKey, len(k.Key))
	}
	return nil
}

// Keyring 保存本机已持有的各群密钥，按群 ID 与版本索引，并发安全。
type Keyring struct {
	mu   sync.RWMutex
	keys map[string]map[uint32][]byte
}

// NewKeyring 创建空密钥环。
func NewKeyring() *Keyring {
	return &Keyring{keys: make(map[string]map[uint32][]byte)}
}

// Put 写入一把群密钥；同一版本重复写入会被覆盖，便于轮换后重放同一版本。
func (k *Keyring) Put(key GroupKey) error {
	if err := key.validate(); err != nil {
		return err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	id := string(key.GroupID)
	versions, ok := k.keys[id]
	if !ok {
		versions = make(map[uint32][]byte)
		k.keys[id] = versions
	}
	versions[key.Version] = append([]byte(nil), key.Key...)
	return nil
}

// Get 返回指定版本的群密钥副本。
func (k *Keyring) Get(groupID []byte, version uint32) ([]byte, bool) {
	k.mu.RLock()
	defer k.mu.RUnlock()
	versions, ok := k.keys[string(groupID)]
	if !ok {
		return nil, false
	}
	key, ok := versions[version]
	if !ok {
		return nil, false
	}
	return append([]byte(nil), key...), true
}

// Latest 返回该群最高版本的密钥副本，用于发送新消息。
func (k *Keyring) Latest(groupID []byte) (uint32, []byte, bool) {
	k.mu.RLock()
	defer k.mu.RUnlock()
	versions, ok := k.keys[string(groupID)]
	if !ok || len(versions) == 0 {
		return 0, nil, false
	}
	var latest uint32
	for v := range versions {
		if v > latest {
			latest = v
		}
	}
	return latest, append([]byte(nil), versions[latest]...), true
}

// Versions 返回该群已持有的密钥版本，升序排列。
func (k *Keyring) Versions(groupID []byte) []uint32 {
	k.mu.RLock()
	defer k.mu.RUnlock()
	versions := k.keys[string(groupID)]
	out := make([]uint32, 0, len(versions))
	for v := range versions {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// Drop 删除该群的全部密钥版本；退群或解散后调用，避免残留可解密材料。
func (k *Keyring) Drop(groupID []byte) {
	k.mu.Lock()
	defer k.mu.Unlock()
	delete(k.keys, string(groupID))
}

// SealGroupBody 用群密钥加密正文，输出 nonce(12B) || 密文。
// AAD 绑定域名、群 ID 与密钥版本，防止跨群或跨版本调包。
func SealGroupBody(key GroupKey, plaintext []byte) ([]byte, error) {
	if err := key.validate(); err != nil {
		return nil, err
	}
	if len(plaintext) == 0 {
		return nil, ErrEmptyBody
	}
	aead, err := newGroupAEAD(key.Key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("生成群消息 nonce: %w", err)
	}
	return aead.Seal(nonce, nonce, plaintext, groupAAD(groupBodyDomain, key.GroupID, key.Version)), nil
}

// OpenGroupBody 解密群消息正文。
func OpenGroupBody(key GroupKey, body []byte) ([]byte, error) {
	if err := key.validate(); err != nil {
		return nil, err
	}
	aead, err := newGroupAEAD(key.Key)
	if err != nil {
		return nil, err
	}
	ns := aead.NonceSize()
	if len(body) < ns+aead.Overhead() {
		return nil, fmt.Errorf("%w: 正文长度 %d", ErrBadEnvelope, len(body))
	}
	plaintext, err := aead.Open(nil, body[:ns], body[ns:], groupAAD(groupBodyDomain, key.GroupID, key.Version))
	if err != nil {
		return nil, fmt.Errorf("%w: 群消息解密失败", ErrBadEnvelope)
	}
	return plaintext, nil
}

// GroupMeta 是随密钥信封下发的群元数据，用当前群密钥密封。
type GroupMeta struct {
	GroupID        []byte
	Title          string
	Members        [][]byte
	KeyVersion     uint32
	OfflineEnabled bool
	// StorageCfg 是组盘配置（已用群密钥密封），随信封下发给全体成员。
	StorageCfg []byte
}

// seal 用群密钥密封元数据。
func (m GroupMeta) seal(key GroupKey) ([]byte, error) {
	if !m.hasGroup(key.GroupID) {
		return nil, fmt.Errorf("%w: 元数据缺少本群", ErrKeyEnvelopeInvalid)
	}
	raw, err := proto.Marshal(&nexmemv1.GroupMeta{
		GroupId:        m.GroupID,
		Title:          m.Title,
		Members:        cloneMembers(m.Members),
		KeyVersion:     m.KeyVersion,
		OfflineEnabled: m.OfflineEnabled,
		StorageCfg:     append([]byte(nil), m.StorageCfg...),
	})
	if err != nil {
		return nil, fmt.Errorf("序列化群元数据: %w", err)
	}
	if len(raw) > maxMetaSize {
		return nil, fmt.Errorf("%w: 元数据超过 %d 字节", ErrKeyEnvelopeInvalid, maxMetaSize)
	}
	aead, err := newGroupAEAD(key.Key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("生成元数据 nonce: %w", err)
	}
	return aead.Seal(nonce, nonce, raw, groupAAD(groupMetaDomain, key.GroupID, key.Version)), nil
}

// openGroupMeta 解封群元数据并校验与信封字段一致。
func openGroupMeta(key GroupKey, sealed []byte) (GroupMeta, error) {
	aead, err := newGroupAEAD(key.Key)
	if err != nil {
		return GroupMeta{}, err
	}
	ns := aead.NonceSize()
	if len(sealed) < ns+aead.Overhead() {
		return GroupMeta{}, fmt.Errorf("%w: 元数据长度 %d", ErrKeyEnvelopeInvalid, len(sealed))
	}
	raw, err := aead.Open(nil, sealed[:ns], sealed[ns:], groupAAD(groupMetaDomain, key.GroupID, key.Version))
	if err != nil {
		return GroupMeta{}, fmt.Errorf("%w: 元数据解密失败", ErrKeyEnvelopeInvalid)
	}
	if len(raw) > maxMetaSize {
		return GroupMeta{}, fmt.Errorf("%w: 元数据超过 %d 字节", ErrKeyEnvelopeInvalid, maxMetaSize)
	}
	pb := &nexmemv1.GroupMeta{}
	if err := proto.Unmarshal(raw, pb); err != nil {
		return GroupMeta{}, fmt.Errorf("%w: 元数据解码失败", ErrKeyEnvelopeInvalid)
	}
	meta := GroupMeta{
		GroupID:        pb.GetGroupId(),
		Title:          pb.GetTitle(),
		Members:        cloneMembers(pb.GetMembers()),
		KeyVersion:     pb.GetKeyVersion(),
		OfflineEnabled: pb.GetOfflineEnabled(),
		StorageCfg:     append([]byte(nil), pb.GetStorageCfg()...),
	}
	if !bytes.Equal(meta.GroupID, key.GroupID) {
		return GroupMeta{}, fmt.Errorf("%w: 元数据群 ID 不一致", ErrKeyEnvelopeInvalid)
	}
	if meta.KeyVersion != key.Version {
		return GroupMeta{}, fmt.Errorf("%w: 元数据密钥版本 %d 与信封 %d 不一致", ErrKeyEnvelopeInvalid, meta.KeyVersion, key.Version)
	}
	return meta, nil
}

// hasGroup 判断元数据属于指定群且成员表非空。
func (m GroupMeta) hasGroup(groupID []byte) bool {
	return len(groupID) > 0 && bytes.Equal(m.GroupID, groupID) && len(m.Members) > 0
}

// has 判断成员表是否包含指定账号。
func (m GroupMeta) has(account []byte) bool {
	for _, member := range m.Members {
		if bytes.Equal(member, account) {
			return true
		}
	}
	return false
}

// BuildKeyEnvelope 为单个成员签发群密钥信封。
// memberXPub 是该成员 account_x_pub，用于封装群密钥。
func BuildKeyEnvelope(admin *identity.Account, key GroupKey, memberAccount, memberXPub []byte, meta GroupMeta) (*nexmemv1.GroupKeyEnvelope, error) {
	if admin == nil {
		return nil, errors.New("缺少管理员账号密钥")
	}
	if err := key.validate(); err != nil {
		return nil, err
	}
	if len(memberAccount) != memberIDSize {
		return nil, fmt.Errorf("%w: 成员账号长度 %d", ErrKeyEnvelopeInvalid, len(memberAccount))
	}
	if len(memberXPub) != 32 {
		return nil, fmt.Errorf("%w: 成员 X25519 公钥长度 %d", ErrKeyEnvelopeInvalid, len(memberXPub))
	}
	if meta.KeyVersion == 0 {
		meta.KeyVersion = key.Version
	}
	if !bytes.Equal(meta.GroupID, key.GroupID) || meta.KeyVersion != key.Version {
		return nil, fmt.Errorf("%w: 元数据与群密钥不匹配", ErrKeyEnvelopeInvalid)
	}
	if !meta.has(admin.Pub()) || !meta.has(memberAccount) {
		return nil, ErrNotMember
	}

	encrypted, err := crypto.WrapContentKey(memberXPub, key.Key)
	if err != nil {
		return nil, fmt.Errorf("封装群密钥: %w", err)
	}
	sealedMeta, err := meta.seal(key)
	if err != nil {
		return nil, err
	}
	env := &nexmemv1.GroupKeyEnvelope{
		GroupId:           append([]byte(nil), key.GroupID...),
		MemberAccount:     append([]byte(nil), memberAccount...),
		KeyVersion:        key.Version,
		EncryptedGroupKey: encrypted,
		GroupMeta:         sealedMeta,
		AdminAccount:      admin.Pub(),
	}
	env.AdminSig = admin.Sign(canonicalKeyEnvelope(env))
	return env, nil
}

// OpenKeyEnvelope 校验并解封发给本机的群密钥信封。
func OpenKeyEnvelope(env *nexmemv1.GroupKeyEnvelope, self *identity.Account) (GroupKey, GroupMeta, error) {
	if env == nil || self == nil {
		return GroupKey{}, GroupMeta{}, ErrKeyEnvelopeInvalid
	}
	if len(env.GetGroupId()) == 0 {
		return GroupKey{}, GroupMeta{}, fmt.Errorf("%w: 缺少群 ID", ErrKeyEnvelopeInvalid)
	}
	if env.GetKeyVersion() == 0 {
		return GroupKey{}, GroupMeta{}, fmt.Errorf("%w: 版本为 0", ErrKeyEnvelopeInvalid)
	}
	if !bytes.Equal(env.GetMemberAccount(), self.Pub()) {
		return GroupKey{}, GroupMeta{}, ErrNotKeyRecipient
	}
	if err := identity.VerifyAccountSignature(env.GetAdminAccount(), canonicalKeyEnvelope(env), env.GetAdminSig()); err != nil {
		return GroupKey{}, GroupMeta{}, fmt.Errorf("%w: 管理员签名: %v", ErrKeyEnvelopeInvalid, err)
	}
	raw, err := crypto.UnwrapContentKey(self.XPriv(), env.GetEncryptedGroupKey())
	if err != nil {
		return GroupKey{}, GroupMeta{}, fmt.Errorf("%w: %v", ErrKeyEnvelopeInvalid, err)
	}
	key := GroupKey{
		GroupID: append([]byte(nil), env.GetGroupId()...),
		Version: env.GetKeyVersion(),
		Key:     raw,
	}
	if err := key.validate(); err != nil {
		return GroupKey{}, GroupMeta{}, err
	}
	meta, err := openGroupMeta(key, env.GetGroupMeta())
	if err != nil {
		return GroupKey{}, GroupMeta{}, err
	}
	if !meta.has(env.GetAdminAccount()) || !meta.has(self.Pub()) {
		return GroupKey{}, GroupMeta{}, fmt.Errorf("%w: 成员表不含签发方或本机", ErrKeyEnvelopeInvalid)
	}
	return key, meta, nil
}

// canonicalKeyEnvelope 生成参与签名的确定性字节，admin_sig 不参与签名。
func canonicalKeyEnvelope(env *nexmemv1.GroupKeyEnvelope) []byte {
	var buf bytes.Buffer
	writeChunk(&buf, []byte(keyEnvelopeDomain))
	writeChunk(&buf, env.GetGroupId())
	writeChunk(&buf, env.GetMemberAccount())
	writeUint32(&buf, env.GetKeyVersion())
	writeChunk(&buf, env.GetEncryptedGroupKey())
	writeChunk(&buf, env.GetGroupMeta())
	writeChunk(&buf, env.GetAdminAccount())
	return buf.Bytes()
}

func groupAAD(domain string, groupID []byte, version uint32) []byte {
	var buf bytes.Buffer
	writeChunk(&buf, []byte(domain))
	writeChunk(&buf, groupID)
	var tmp [4]byte
	binary.BigEndian.PutUint32(tmp[:], version)
	buf.Write(tmp[:])
	return buf.Bytes()
}

func writeUint32(buf *bytes.Buffer, v uint32) {
	var tmp [4]byte
	binary.BigEndian.PutUint32(tmp[:], v)
	buf.Write(tmp[:])
}

func newGroupAEAD(key []byte) (cipher.AEAD, error) {
	if len(key) != GroupKeySize {
		return nil, fmt.Errorf("%w: 长度 %d", ErrBadGroupKey, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("初始化群密钥 AES: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化群密钥 GCM: %w", err)
	}
	return aead, nil
}

func cloneMembers(members [][]byte) [][]byte {
	if len(members) == 0 {
		return nil
	}
	out := make([][]byte, 0, len(members))
	for _, m := range members {
		out = append(out, append([]byte(nil), m...))
	}
	return out
}

// XPubResolver 把成员账号 ed25519 公钥解析为 account_x_pub。
type XPubResolver interface {
	XPub(ctx context.Context, accountPub []byte) ([]byte, error)
}

// XPubFunc 让普通函数实现 XPubResolver。
type XPubFunc func(ctx context.Context, accountPub []byte) ([]byte, error)

// XPub 实现 XPubResolver。
func (f XPubFunc) XPub(ctx context.Context, accountPub []byte) ([]byte, error) {
	return f(ctx, accountPub)
}

// KeyTarget 描述一个密钥信封接收方的传输地址与账号身份。
type KeyTarget struct {
	PeerID     peer.ID
	Addrs      []multiaddr.Multiaddr
	AccountPub []byte
	// XPub 可留空；留空时用 Options.XPub 解析。
	XPub []byte
}

// KeyDelivery 是单个成员的密钥投递结果。
type KeyDelivery struct {
	AccountPub []byte
	Err        error
}

// GroupMetaSender 把群密钥信封经单聊通道投递给指定成员（P4-08）。
// *dm.Service 实现该接口；经此通道可复用 ACK 重试、离线票据与补发。
type GroupMetaSender interface {
	SendGroupMeta(ctx context.Context, accountPub []byte, peerID peer.ID, addrs []multiaddr.Multiaddr, env *nexmemv1.GroupKeyEnvelope) error
}

// DistributeKeys 生成各成员的密钥信封并逐个单播投递，同时把密钥写入本机密钥环。
// 本机账号不在 targets 内时会被自动跳过；单个成员投递失败不影响其他成员。
func (s *Service) DistributeKeys(ctx context.Context, key GroupKey, meta GroupMeta, targets []KeyTarget) ([]KeyDelivery, error) {
	if err := key.validate(); err != nil {
		return nil, err
	}
	if len(meta.GroupID) == 0 {
		meta.GroupID = append([]byte(nil), key.GroupID...)
	}
	meta.KeyVersion = key.Version
	if !meta.has(s.account.Pub()) {
		return nil, fmt.Errorf("%w: 本机不在成员表内", ErrKeyEnvelopeInvalid)
	}
	if err := s.storeKey(ctx, key, meta, s.account.Pub()); err != nil {
		return nil, err
	}

	reports := make([]KeyDelivery, 0, len(targets))
	for _, t := range targets {
		if bytes.Equal(t.AccountPub, s.account.Pub()) {
			continue
		}
		if ctx != nil {
			if err := ctx.Err(); err != nil {
				return reports, err
			}
		}
		xpub := t.XPub
		if len(xpub) == 0 {
			if s.xpubResolver == nil {
				reports = append(reports, KeyDelivery{AccountPub: t.AccountPub, Err: errors.New("缺少成员 X25519 公钥解析器")})
				continue
			}
			resolved, err := s.xpubResolver.XPub(ctx, t.AccountPub)
			if err != nil {
				reports = append(reports, KeyDelivery{AccountPub: t.AccountPub, Err: err})
				continue
			}
			xpub = resolved
		}
		env, err := BuildKeyEnvelope(s.account, key, t.AccountPub, xpub, meta)
		if err != nil {
			reports = append(reports, KeyDelivery{AccountPub: t.AccountPub, Err: err})
			continue
		}
		reports = append(reports, KeyDelivery{AccountPub: t.AccountPub, Err: s.SendKeyEnvelope(ctx, t, env)})
	}
	return reports, nil
}

// SendKeyEnvelope 把密钥信封投递给单个成员。
//
// 先走 /nexmem/group-meta/1.0.0 直连流；直连不可达（含对端离线）且配置了
// MetaSender 时改走单聊通道，从而复用离线票据与补发（P4-08）。
func (s *Service) SendKeyEnvelope(ctx context.Context, t KeyTarget, env *nexmemv1.GroupKeyEnvelope) error {
	if env == nil {
		return ErrKeyEnvelopeInvalid
	}
	if !bytes.Equal(env.GetMemberAccount(), t.AccountPub) {
		return fmt.Errorf("%w: 信封接收方与目标不一致", ErrKeyEnvelopeInvalid)
	}
	directErr := s.sendKeyEnvelopeDirect(ctx, t, env)
	if directErr == nil {
		return nil
	}
	if errors.Is(directErr, ErrPeerRejected) {
		return directErr
	}
	if s.metaSender == nil {
		return directErr
	}
	if err := s.metaSender.SendGroupMeta(ctx, t.AccountPub, t.PeerID, t.Addrs, env); err != nil {
		return fmt.Errorf("%w（单聊投递失败: %w）", directErr, err)
	}
	return nil
}

// sendKeyEnvelopeDirect 在 /nexmem/group-meta/1.0.0 上把密钥信封投递给单个成员。
func (s *Service) sendKeyEnvelopeDirect(ctx context.Context, t KeyTarget, env *nexmemv1.GroupKeyEnvelope) error {
	if t.PeerID == "" {
		return fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if s.deviceKey == nil {
		return errors.New("缺少设备私钥，无法签名密钥信封")
	}
	if err := s.connect(ctx, t.PeerID, t.Addrs); err != nil {
		return err
	}

	payload, err := proto.Marshal(env)
	if err != nil {
		return fmt.Errorf("序列化群密钥信封: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_META,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}

	streamCtx := network.WithAllowLimitedConn(ctx, "nexmem-group-meta")
	stream, err := s.host.NewStream(streamCtx, t.PeerID, wire.PIDMeta)
	if err != nil {
		return fmt.Errorf("%w: 打开群密钥流: %v", ErrPeerUnreached, err)
	}
	defer stream.Close()
	if err := stream.SetDeadline(time.Now().Add(metaStreamTimeout)); err != nil {
		return fmt.Errorf("设置群密钥流超时: %w", err)
	}
	if err := wire.WriteFrame(stream, frame); err != nil {
		return fmt.Errorf("发送群密钥信封: %w", err)
	}
	ackFrame, err := wire.ReadFrame(stream)
	if err != nil {
		return fmt.Errorf("等待群密钥 ACK: %w", err)
	}
	if err := wire.VerifyFrame(stream.Conn().RemotePublicKey(), ackFrame); err != nil {
		return fmt.Errorf("%w: 群密钥 ACK 验签: %v", ErrAckInvalid, err)
	}
	if ackFrame.Type != nexmemv1.FrameType_FRAME_TYPE_ACK {
		return fmt.Errorf("%w: 帧类型 %s", ErrAckInvalid, ackFrame.Type)
	}
	ack := &nexmemv1.Ack{}
	if err := proto.Unmarshal(ackFrame.Payload, ack); err != nil {
		return fmt.Errorf("%w: 解析群密钥 ACK: %v", ErrAckInvalid, err)
	}
	switch ack.GetCode() {
	case metaAckOK, metaAckDup:
		return nil
	case metaAckReject:
		return ErrPeerRejected
	default:
		return fmt.Errorf("%w: 错误码 %d", ErrAckInvalid, ack.GetCode())
	}
}

// AcceptKeyEnvelope 受理一个发给本机的群密钥信封：验签、解封、入环并落库。
// 默认在受理成功后自动订阅群主题，使新成员立刻能收到群消息（P4-08）。
func (s *Service) AcceptKeyEnvelope(ctx context.Context, env *nexmemv1.GroupKeyEnvelope) (GroupKey, GroupMeta, error) {
	key, meta, err := OpenKeyEnvelope(env, s.account)
	if err != nil {
		return GroupKey{}, GroupMeta{}, err
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := s.storeKey(ctx, key, meta, env.GetAdminAccount()); err != nil {
		return GroupKey{}, GroupMeta{}, err
	}
	// 密钥到达后补解此前因缺少该版本密钥而暂存的入站消息（R-15）。
	s.flushPending(key.GroupID, key.Version)
	if s.onKey != nil {
		s.onKey(key, meta)
	}
	if !s.noAutoSub {
		if err := s.Subscribe(ctx, key.GroupID); err != nil {
			return key, meta, fmt.Errorf("订阅群主题: %w", err)
		}
	}
	return key, meta, nil
}

// LatestKey 返回本群最新版本的群密钥副本，供上层诊断与发送前检查。
func (s *Service) LatestKey(groupID []byte) (uint32, []byte, bool) {
	return s.keys.Latest(groupID)
}

// PendingCount 返回尚未等到对应密钥版本的暂存入站消息数，用于诊断与测试。
func (s *Service) PendingCount() int {
	return s.pendingMsgs.Len()
}

// flushPending 用刚受理的群密钥补解暂存消息并交付给上层。
// 解密失败的消息直接丢弃；密钥仍缺失时放回暂存等待下一次受理。
func (s *Service) flushPending(groupID []byte, version uint32) {
	items := s.pendingMsgs.Take(groupID, version)
	if len(items) == 0 || s.onMsg == nil {
		return
	}
	for _, it := range items {
		raw, ok := s.keys.Get(groupID, version)
		if !ok {
			s.pendingMsgs.Add(it, time.Now())
			continue
		}
		plaintext, err := OpenGroupBody(GroupKey{GroupID: groupID, Version: version, Key: raw}, it.Body)
		if err != nil {
			continue
		}
		s.onMsg(Received{
			GroupID:       append([]byte(nil), it.GroupID...),
			SenderAccount: append([]byte(nil), it.SenderAccount...),
			MsgUUID:       it.MsgUUID,
			SentAt:        it.SentAt,
			KeyVersion:    it.KeyVersion,
			Body:          append([]byte(nil), it.Body...),
			Plaintext:     plaintext,
		})
	}
}

// Subscribed 表示本机是否已订阅指定群主题。
func (s *Service) Subscribed(groupID []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.subs[TopicFor(groupID)]
	return ok
}

// LoadKeys 从本地库重新装载群密钥，用于进程重启后继续解密群消息与群盘对象。
// 优先读取 group_keys 的全部历史版本；旧库尚未写入 history 时回退到 groups.group_key_enc。
func (s *Service) LoadKeys(ctx context.Context) error {
	if s.dao == nil {
		return errors.New("缺少本地 DAO")
	}
	groups, err := s.dao.ListGroups(ctx)
	if err != nil {
		return fmt.Errorf("读取本地群列表: %w", err)
	}
	for _, g := range groups {
		records, err := s.dao.ListGroupKeys(ctx, g.GroupID)
		if err != nil {
			return err
		}
		if len(records) == 0 {
			raw, err := crypto.UnwrapContentKey(s.account.XPriv(), g.GroupKeyEnc)
			if err != nil {
				return fmt.Errorf("解封群 %x 密钥: %w", g.GroupID, err)
			}
			if err := s.keys.Put(GroupKey{
				GroupID: g.GroupID,
				Version: uint32(g.KeyVersion),
				Key:     raw,
			}); err != nil {
				return err
			}
			continue
		}
		for _, rec := range records {
			raw, err := crypto.UnwrapContentKey(s.account.XPriv(), rec.KeyEnc)
			if err != nil {
				return fmt.Errorf("解封群 %x v%d 密钥: %w", g.GroupID, rec.Version, err)
			}
			if err := s.keys.Put(GroupKey{
				GroupID: rec.GroupID,
				Version: rec.Version,
				Key:     raw,
			}); err != nil {
				return err
			}
		}
	}
	return nil
}

// PublishEncrypted 用本群最新密钥加密正文后广播，返回 msg_uuid（十六进制）。
func (s *Service) PublishEncrypted(ctx context.Context, groupID []byte, plaintext string) (string, error) {
	if len(groupID) == 0 {
		return "", ErrGroupIDRequired
	}
	if plaintext == "" {
		return "", ErrEmptyBody
	}
	version, key, ok := s.keys.Latest(groupID)
	if !ok {
		return "", ErrGroupKeyNotFound
	}
	body, err := SealGroupBody(GroupKey{GroupID: groupID, Version: version, Key: key}, []byte(plaintext))
	if err != nil {
		return "", err
	}
	return s.Publish(ctx, groupID, body, version)
}

// handleMetaStream 处理一条入站群密钥流：读 META 帧 → 验签受理 → 回 ACK。
func (s *Service) handleMetaStream(st network.Stream) {
	defer st.Close()
	_ = st.SetDeadline(time.Now().Add(metaStreamTimeout))

	frame, err := wire.ReadFrame(st)
	if err != nil {
		return
	}
	if frame.Version != wire.Version || frame.Type != nexmemv1.FrameType_FRAME_TYPE_META {
		s.writeMetaAck(st, metaAckReject)
		return
	}
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}
	env := &nexmemv1.GroupKeyEnvelope{}
	if err := proto.Unmarshal(frame.Payload, env); err != nil {
		s.writeMetaAck(st, metaAckReject)
		return
	}
	if _, _, err := s.AcceptKeyEnvelope(context.Background(), env); err != nil {
		s.writeMetaAck(st, metaAckReject)
		return
	}
	s.writeMetaAck(st, metaAckOK)
}

func (s *Service) writeMetaAck(st network.Stream, code int32) {
	payload, err := proto.Marshal(&nexmemv1.Ack{Code: code, At: time.Now().UnixMilli()})
	if err != nil {
		return
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_ACK,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return
	}
	_ = wire.WriteFrame(st, frame)
}

// connect 确保与目标 PeerID 已建立连接。
func (s *Service) connect(ctx context.Context, id peer.ID, addrs []multiaddr.Multiaddr) error {
	if s.host.Network().Connectedness(id) == network.Connected {
		return nil
	}
	if len(addrs) == 0 {
		return fmt.Errorf("%w: 未提供对端地址", ErrPeerUnreached)
	}
	info := peer.AddrInfo{ID: id, Addrs: addrs}
	if err := s.host.Connect(ctx, info); err != nil {
		return fmt.Errorf("%w: %v", ErrPeerUnreached, err)
	}
	return nil
}

// storeKey 把群密钥写入密钥环，并在配置了 DAO 时落库（群记录 + 历史版本 + 成员表）。
//
// 版本单调保护：
//   - 收到的信封版本低于本机记录时，只把密钥放入密钥环，不覆盖群记录与成员表，
//     避免旧信封重放把成员表回退；
//   - 同版本必须是同一把密钥；若信封携带的成员表是本机成员表的真子集，
//     视为旧快照，不覆盖成员表（P4-04 踢人后旧信封重放防护）。
func (s *Service) storeKey(ctx context.Context, key GroupKey, meta GroupMeta, admin []byte) error {
	if err := key.validate(); err != nil {
		return err
	}
	if s.dao == nil {
		return s.keys.Put(key)
	}
	existing, err := s.dao.GetGroup(ctx, key.GroupID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return err
	}
	if existing != nil {
		if existing.KeyVersion > int(key.Version) {
			// 旧版本信封只补充密钥环，不覆盖更新的群状态。
			return s.keys.Put(key)
		}
		if existing.KeyVersion == int(key.Version) && len(existing.GroupKeyEnc) > 0 {
			old, derr := crypto.UnwrapContentKey(s.account.XPriv(), existing.GroupKeyEnc)
			if derr == nil && !bytes.Equal(old, key.Key) {
				// 同版本不同密钥属于异常信封，拒绝写入，避免污染密钥环。
				return fmt.Errorf("%w: 版本 %d 的群密钥与本机不一致", ErrKeyEnvelopeInvalid, key.Version)
			}
			current, lerr := s.dao.ListMembers(ctx, key.GroupID)
			if lerr != nil {
				return lerr
			}
			if len(current) > 0 && strictSubset(meta.Members, memberAccounts(current)) {
				// 同版本的旧成员快照，保留更新的成员表。
				return s.keys.Put(key)
			}
		}
	}
	if err := s.keys.Put(key); err != nil {
		return err
	}

	wrapped, err := crypto.WrapContentKey(s.account.XPub(), key.Key)
	if err != nil {
		return fmt.Errorf("封装本机群密钥: %w", err)
	}
	myRole := KeyRoleMember
	if bytes.Equal(admin, s.account.Pub()) {
		myRole = KeyRoleAdmin
	}
	g := store.Group{
		GroupID:        key.GroupID,
		Title:          meta.Title,
		MyRole:         myRole,
		KeyVersion:     int(key.Version),
		GroupKeyEnc:    wrapped,
		StorageCfgEnc:  append([]byte(nil), meta.StorageCfg...),
		OfflineEnabled: meta.OfflineEnabled,
	}
	if existing != nil {
		if len(g.StorageCfgEnc) == 0 {
			g.StorageCfgEnc = existing.StorageCfgEnc
		}
		if g.Title == "" {
			g.Title = existing.Title
		}
	}
	if err := s.dao.PutGroup(ctx, g); err != nil {
		return err
	}
	if err := s.dao.PutGroupKey(ctx, key.GroupID, key.Version, wrapped); err != nil {
		return err
	}
	now := time.Now().Unix()
	members := make([]store.GroupMember, 0, len(meta.Members))
	for _, member := range meta.Members {
		role := KeyRoleMember
		if bytes.Equal(member, admin) {
			role = KeyRoleAdmin
		}
		members = append(members, store.GroupMember{
			GroupID:    key.GroupID,
			AccountPub: member,
			Role:       role,
			JoinedAt:   now,
		})
	}
	return s.dao.ReplaceMembers(ctx, key.GroupID, members)
}

// strictSubset 判断 candidate 是否是 current 的真子集（current 含有 candidate 缺少的成员）。
func strictSubset(candidate, current [][]byte) bool {
	if len(candidate) >= len(current) {
		return false
	}
	seen := make(map[string]struct{}, len(candidate))
	for _, m := range candidate {
		seen[string(m)] = struct{}{}
	}
	for _, m := range current {
		if _, ok := seen[string(m)]; !ok {
			return true
		}
	}
	return false
}

// memberAccounts 提取成员账号列表。
func memberAccounts(members []store.GroupMember) [][]byte {
	out := make([][]byte, 0, len(members))
	for _, m := range members {
		out = append(out, m.AccountPub)
	}
	return out
}

// deviceKeyFromHost 在未显式提供设备私钥时回退到 host 自身的私钥。
func deviceKeyFromHost(opt Options) libp2pcrypto.PrivKey {
	if opt.DeviceKey != nil {
		return opt.DeviceKey
	}
	return opt.Host.Peerstore().PrivKey(opt.Host.ID())
}
