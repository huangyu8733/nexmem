package group

// 群盘配置与写入（P4-05）。
//
// 群主为群配置一个 S3 兼容桶（R2 / MinIO 等），群消息在在线广播之外
// 额外写一份密文对象：group_offline/{base64url(group_id)}/{msg_uuid}.msg。
// 对象内容就是签名后的 GroupEnvelope，离线成员上线后按 group_cursor 拉取，
// 用对应 key_version 的群密钥解密（P4-06）。
//
// 配置本身用群密钥密封后落在 groups.storage_cfg_enc，并随 GroupMeta 分发给
// 全体成员，因此成员无需各自持有群盘凭证；轮换密钥时配置会重新密封。
// 上传失败只影响离线补齐，不影响在线广播：广播成功即返回，失败原因经
// PublishResult 与 OnStorage 回调上报，由 UI 常驻提示（P4-07）。

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/blob"
	"github.com/nexmem/core/internal/store"
)

const (
	// GroupStoragePrefixRoot 是群盘对象键根前缀，桶生命周期规则作用于该前缀。
	GroupStoragePrefixRoot = "group_offline"
	// MaxStorageObjectSize 是单个群盘对象上限，与帧上限一致。
	MaxStorageObjectSize = 1 << 20

	storageCfgDomain     = "nexmem/group-storage"
	storageAccessSuffix  = "/access-key"
	storageSecretSuffix  = "/secret-key"
	storageObjectExt     = ".msg"
	storageContentType   = "application/x-protobuf"
	defaultStorageRegion = "auto"
)

// 群盘语义错误。
var (
	// ErrStorageNotConfigured 表示该群尚未配置群盘。
	ErrStorageNotConfigured = errors.New("群未配置群盘")
	// ErrBadStorageConfig 表示群盘配置字段非法或无法解封。
	ErrBadStorageConfig = errors.New("群盘配置非法")
	// ErrStorageWrite 表示群盘对象写入失败。
	ErrStorageWrite = errors.New("群盘写入失败")
)

// StorageConfig 是群盘的 S3 连接配置，凭证只以密文形式落库与分发。
type StorageConfig struct {
	Endpoint  string
	Bucket    string
	Prefix    string
	Region    string
	AccessKey string
	SecretKey string
	// PathStyle 为 true 时使用 http://host/bucket/key（MinIO 常用）。
	PathStyle bool
}

// ObjectStore 是群盘所需的最小对象存储能力，由 *blob.Client 实现。
type ObjectStore interface {
	Put(ctx context.Context, key string, data []byte, contentType string) (blob.ObjectInfo, error)
	Get(ctx context.Context, key string) ([]byte, blob.ObjectInfo, error)
	List(ctx context.Context, prefix string) ([]blob.ObjectInfo, error)
}

// PublishResult 是一次「广播 + 群盘落盘」的结果。
// Stored 为 false 时 StorageErr 给出原因（未配置、写入失败等），广播本身已成功。
type PublishResult struct {
	MsgUUID    string
	Stored     bool
	StorageErr error
}

// StorageEvent 是群盘写入结果，供上层提示「仅在线可见」等状态。
type StorageEvent struct {
	GroupID []byte
	MsgUUID string
	Err     error
}

// StoragePrefix 返回群盘对象键前缀 group_offline/{base64url(group_id)}/。
func StoragePrefix(groupID []byte) string {
	return GroupStoragePrefixRoot + "/" + base64.RawURLEncoding.EncodeToString(groupID) + "/"
}

// StorageObjectKey 返回单条群消息的对象键。
func StorageObjectKey(groupID []byte, msgUUID string) string {
	return StoragePrefix(groupID) + msgUUID + storageObjectExt
}

// normalize 校验配置并补齐默认值，prefix 固定为群盘规范前缀。
func (c StorageConfig) normalize(groupID []byte) (StorageConfig, error) {
	endpoint := strings.TrimRight(strings.TrimSpace(c.Endpoint), "/")
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return StorageConfig{}, fmt.Errorf("%w: endpoint 必须为 http/https 地址", ErrBadStorageConfig)
	}
	bucket := strings.TrimSpace(c.Bucket)
	if bucket == "" {
		return StorageConfig{}, fmt.Errorf("%w: 缺少桶名", ErrBadStorageConfig)
	}
	if c.AccessKey == "" || c.SecretKey == "" {
		return StorageConfig{}, fmt.Errorf("%w: 缺少访问凭证", ErrBadStorageConfig)
	}
	prefix := StoragePrefix(groupID)
	if c.Prefix != "" && c.Prefix != prefix {
		return StorageConfig{}, fmt.Errorf("%w: 对象前缀必须为 %s", ErrBadStorageConfig, prefix)
	}
	region := strings.TrimSpace(c.Region)
	if region == "" {
		region = defaultStorageRegion
	}
	return StorageConfig{
		Endpoint:  endpoint,
		Bucket:    bucket,
		Prefix:    prefix,
		Region:    region,
		AccessKey: c.AccessKey,
		SecretKey: c.SecretKey,
		PathStyle: c.PathStyle,
	}, nil
}

// SealStorageConfig 用群密钥密封群盘配置，输出可随 GroupMeta 分发的字节。
func SealStorageConfig(key GroupKey, cfg StorageConfig) ([]byte, error) {
	if err := key.validate(); err != nil {
		return nil, err
	}
	normalized, err := cfg.normalize(key.GroupID)
	if err != nil {
		return nil, err
	}
	accessEnc, err := sealStorageSecret(key, storageAccessSuffix, []byte(normalized.AccessKey))
	if err != nil {
		return nil, err
	}
	secretEnc, err := sealStorageSecret(key, storageSecretSuffix, []byte(normalized.SecretKey))
	if err != nil {
		return nil, err
	}
	raw, err := proto.Marshal(&nexmemv1.GroupStorageConfig{
		Endpoint:     normalized.Endpoint,
		Bucket:       normalized.Bucket,
		Prefix:       normalized.Prefix,
		Region:       normalized.Region,
		AccessKeyEnc: accessEnc,
		SecretKeyEnc: secretEnc,
		KeyVersion:   key.Version,
		PathStyle:    normalized.PathStyle,
	})
	if err != nil {
		return nil, fmt.Errorf("序列化群盘配置: %w", err)
	}
	return raw, nil
}

// OpenStorageConfig 用群密钥解封群盘配置。
// 配置被其他群或版本密封时，AAD 校验失败，返回 ErrBadStorageConfig。
func OpenStorageConfig(key GroupKey, raw []byte) (StorageConfig, error) {
	if err := key.validate(); err != nil {
		return StorageConfig{}, err
	}
	if len(raw) == 0 {
		return StorageConfig{}, ErrStorageNotConfigured
	}
	pb := &nexmemv1.GroupStorageConfig{}
	if err := proto.Unmarshal(raw, pb); err != nil {
		return StorageConfig{}, fmt.Errorf("%w: 解码失败", ErrBadStorageConfig)
	}
	if pb.GetKeyVersion() != key.Version {
		return StorageConfig{}, fmt.Errorf("%w: 密钥版本 %d 与配置 %d 不一致", ErrBadStorageConfig, key.Version, pb.GetKeyVersion())
	}
	access, err := openStorageSecret(key, storageAccessSuffix, pb.GetAccessKeyEnc())
	if err != nil {
		return StorageConfig{}, err
	}
	secret, err := openStorageSecret(key, storageSecretSuffix, pb.GetSecretKeyEnc())
	if err != nil {
		return StorageConfig{}, err
	}
	cfg := StorageConfig{
		Endpoint:  pb.GetEndpoint(),
		Bucket:    pb.GetBucket(),
		Prefix:    pb.GetPrefix(),
		Region:    pb.GetRegion(),
		AccessKey: string(access),
		SecretKey: string(secret),
		PathStyle: pb.GetPathStyle(),
	}
	if _, err := cfg.normalize(key.GroupID); err != nil {
		return StorageConfig{}, err
	}
	return cfg, nil
}

// sealStorageSecret 用群密钥加密单个凭证字段，label 做字段级域隔离。
func sealStorageSecret(key GroupKey, label string, plaintext []byte) ([]byte, error) {
	aead, err := newGroupAEAD(key.Key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("生成群盘配置 nonce: %w", err)
	}
	return aead.Seal(nonce, nonce, plaintext, groupAAD(storageCfgDomain+label, key.GroupID, key.Version)), nil
}

// openStorageSecret 解密单个凭证字段。
func openStorageSecret(key GroupKey, label string, sealed []byte) ([]byte, error) {
	aead, err := newGroupAEAD(key.Key)
	if err != nil {
		return nil, err
	}
	ns := aead.NonceSize()
	if len(sealed) < ns+aead.Overhead() {
		return nil, fmt.Errorf("%w: 凭证密文长度 %d", ErrBadStorageConfig, len(sealed))
	}
	out, err := aead.Open(nil, sealed[:ns], sealed[ns:], groupAAD(storageCfgDomain+label, key.GroupID, key.Version))
	if err != nil {
		return nil, fmt.Errorf("%w: 凭证解密失败", ErrBadStorageConfig)
	}
	return out, nil
}

// ConfigureStorage 由群管理员设置群盘，并把带配置的群元数据重新分发给成员。
// targets 为空时只更新本机配置；单个成员投递失败不影响本机配置生效。
func (s *Service) ConfigureStorage(ctx context.Context, groupID []byte, cfg StorageConfig, targets []KeyTarget) ([]KeyDelivery, error) {
	g, members, err := s.requireAdmin(ctx, groupID)
	if err != nil {
		return nil, err
	}
	key, err := s.latestKey(ctx, groupID)
	if err != nil {
		return nil, err
	}
	sealed, err := SealStorageConfig(key, cfg)
	if err != nil {
		return nil, err
	}
	meta := GroupMeta{
		GroupID:        groupID,
		Title:          g.Title,
		Members:        memberAccounts(members),
		KeyVersion:     key.Version,
		OfflineEnabled: true,
		StorageCfg:     sealed,
	}
	return s.DistributeKeys(ctx, key, meta, filterTargets(targets, meta.Members))
}

// StorageConfigFor 读取并解封本机的群盘配置；未配置或密钥缺失返回错误。
func (s *Service) StorageConfigFor(ctx context.Context, groupID []byte) (StorageConfig, error) {
	if s.dao == nil {
		return StorageConfig{}, ErrStorageNotConfigured
	}
	g, err := s.dao.GetGroup(ctx, groupID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && len(g.StorageCfgEnc) == 0) {
		return StorageConfig{}, ErrStorageNotConfigured
	}
	if err != nil {
		return StorageConfig{}, err
	}
	key, err := s.groupKey(ctx, groupID, uint32(g.KeyVersion))
	if err != nil {
		return StorageConfig{}, err
	}
	return OpenStorageConfig(key, g.StorageCfgEnc)
}

// groupKey 从密钥环取指定版本密钥，缺失时先从本地库重载。
func (s *Service) groupKey(ctx context.Context, groupID []byte, version uint32) (GroupKey, error) {
	if raw, ok := s.keys.Get(groupID, version); ok {
		return GroupKey{GroupID: groupID, Version: version, Key: raw}, nil
	}
	if err := s.LoadKeys(ctx); err != nil {
		return GroupKey{}, err
	}
	raw, ok := s.keys.Get(groupID, version)
	if !ok {
		return GroupKey{}, ErrGroupKeyNotFound
	}
	return GroupKey{GroupID: groupID, Version: version, Key: raw}, nil
}

// PublishEncryptedStored 加密广播后尽力写入群盘。
// 广播失败时返回错误；群盘失败只体现在 PublishResult.StorageErr 与 OnStorage 回调中。
func (s *Service) PublishEncryptedStored(ctx context.Context, groupID []byte, plaintext string) (PublishResult, error) {
	if plaintext == "" {
		return PublishResult{}, ErrEmptyBody
	}
	return s.publishEncryptedMessage(ctx, groupID, []byte(plaintext),
		&nexmemv1.InnerMessage{Text: plaintext}, int32(nexmemv1.ContentType_CONTENT_TYPE_TEXT))
}

// PublishEncryptedMessage 加密广播一条完整 InnerMessage（七-1 @成员）。
// 与 PublishEncryptedStored 的区别是正文直接来自 InnerMessage，可携带 mentions、
// reply_to、edited 等结构化字段；序列化字节同时作为广播密文与落库 Inner。
func (s *Service) PublishEncryptedMessage(ctx context.Context, groupID []byte, inner *nexmemv1.InnerMessage) (PublishResult, error) {
	if inner == nil || inner.GetText() == "" {
		return PublishResult{}, ErrEmptyBody
	}
	plain, err := EncodeInnerPlaintext(inner, inner.GetText())
	if err != nil {
		return PublishResult{}, fmt.Errorf("序列化群消息正文: %w", err)
	}
	return s.publishEncryptedMessage(ctx, groupID, plain, inner, int32(nexmemv1.ContentType_CONTENT_TYPE_TEXT))
}

// publishEncryptedMessage 是群文本/结构化消息的公共发布路径。
// plaintext 是加密广播的字节，inner 是本方落库用的 InnerMessage。
func (s *Service) publishEncryptedMessage(ctx context.Context, groupID []byte, plaintext []byte, inner *nexmemv1.InnerMessage, contentType int32) (PublishResult, error) {
	key, err := s.latestKey(ctx, groupID)
	if err != nil {
		return PublishResult{}, err
	}
	body, err := SealGroupBody(key, plaintext)
	if err != nil {
		return PublishResult{}, err
	}
	env, uuid, err := s.buildEnvelope(ctx, groupID, body, key.Version)
	if err != nil {
		return PublishResult{}, err
	}
	if err := s.publishEnvelope(ctx, groupID, env); err != nil {
		return PublishResult{}, err
	}
	innerBytes, err := proto.Marshal(inner)
	if err != nil {
		return PublishResult{}, err
	}
	// 广播成功后由上层（coreapp）把本方消息写入本地库，
	// 使 msg.list / conversation.list 能读到群消息（P1-20 / P4）。
	s.emitSent(SentEvent{
		GroupID:     append([]byte(nil), groupID...),
		MsgUUID:     uuid,
		SentAt:      env.GetSentAt(),
		Plaintext:   plaintext,
		ContentType: contentType,
		Inner:       innerBytes,
	})

	result := PublishResult{MsgUUID: uuid}
	result.StorageErr = s.storeGroupMessage(ctx, groupID, uuid, env)
	result.Stored = result.StorageErr == nil
	s.emitStorage(StorageEvent{
		GroupID: append([]byte(nil), groupID...),
		MsgUUID: uuid,
		Err:     result.StorageErr,
	})
	return result, nil
}

// storeGroupMessage 把签名信封写成群盘单副本对象。
func (s *Service) storeGroupMessage(ctx context.Context, groupID []byte, msgUUID string, env *nexmemv1.GroupEnvelope) error {
	cfg, err := s.StorageConfigFor(ctx, groupID)
	if err != nil {
		return err
	}
	raw, err := proto.Marshal(env)
	if err != nil {
		return fmt.Errorf("%w: 序列化群信封: %v", ErrStorageWrite, err)
	}
	if len(raw) > MaxStorageObjectSize {
		return fmt.Errorf("%w: 对象 %d 字节超过上限", ErrStorageWrite, len(raw))
	}
	objects, err := s.objectStore(cfg)
	if err != nil {
		return err
	}
	if _, err := objects.Put(ctx, StorageObjectKey(groupID, msgUUID), raw, storageContentType); err != nil {
		return fmt.Errorf("%w: %v", ErrStorageWrite, err)
	}
	return nil
}

// objectStore 按配置创建对象存储客户端，默认使用 blob 客户端。
func (s *Service) objectStore(cfg StorageConfig) (ObjectStore, error) {
	if s.storageNew != nil {
		return s.storageNew(cfg)
	}
	client, err := blob.New(blob.Config{
		Endpoint:  cfg.Endpoint,
		Region:    cfg.Region,
		Bucket:    cfg.Bucket,
		AccessKey: cfg.AccessKey,
		SecretKey: cfg.SecretKey,
		PathStyle: cfg.PathStyle,
	})
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrBadStorageConfig, err)
	}
	return client, nil
}

// emitStorage 触发群盘结果回调。
func (s *Service) emitStorage(ev StorageEvent) {
	if s.onStorage != nil {
		s.onStorage(ev)
	}
}

// emitSent 触发本机群消息落库回调。
func (s *Service) emitSent(ev SentEvent) {
	if s.onSent != nil {
		s.onSent(ev)
	}
}

// resealStorageCfg 在密钥轮换时用新版本密钥重新密封群盘配置；无配置时返回 nil。
func resealStorageCfg(raw []byte, from, to GroupKey) ([]byte, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	cfg, err := OpenStorageConfig(from, raw)
	if err != nil {
		return nil, err
	}
	cfg.Prefix = ""
	return SealStorageConfig(to, cfg)
}
