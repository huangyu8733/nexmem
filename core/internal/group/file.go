package group

// 群聊附件（A-02）：把文件密文写入群盘单副本对象，附件元数据经群消息广播。
//
// 与单聊文件的 P2P 分片流不同，群文件依赖所有成员可访问的群盘：
//   - 文件用独立 AES-256 密钥经 ChunkCipher 单分片加密，密钥随 InnerMessage
//     由群密钥保护广播；
//   - 密文对象写在 group_offline/{group}/files/{msgUUID}.bin，所有成员可拉取；
//   - 受群盘单对象 1 MiB 上限约束，超过 groupFileMaxBytes 的文件明确拒绝。

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	filecrypto "github.com/nexmem/core/internal/crypto"
)

const (
	// groupFileMaxBytes 是群文件明文上限，留 GCM 标签与元数据余量后小于群盘对象上限。
	groupFileMaxBytes = MaxStorageObjectSize - 4096
	groupFileObjType  = "application/octet-stream"
)

var (
	// ErrGroupFileTooLarge 表示文件超过群盘单对象上限。
	ErrGroupFileTooLarge = errors.New("群文件超过 1 MiB 上限，请改用私聊发送")
	// ErrGroupFileInvalid 表示文件路径或对象键非法。
	ErrGroupFileInvalid = errors.New("群文件参数非法")
)

// groupFileObjectKey 返回群文件密文对象的键。
func groupFileObjectKey(groupID []byte, msgUUID string) string {
	return StoragePrefix(groupID) + "files/" + msgUUID + ".bin"
}

// SendFile 把本机文件加密写入群盘，并把附件元数据作为群消息广播。
// 返回 msg_uuid 与群盘落盘结果；广播成功即返回，群盘失败时返回错误。
func (s *Service) SendFile(ctx context.Context, groupID []byte, path, mime string) (PublishResult, error) {
	if !filepath.IsAbs(path) {
		return PublishResult{}, fmt.Errorf("群文件需要绝对路径: %w", ErrGroupFileInvalid)
	}
	info, err := os.Stat(path)
	if err != nil {
		return PublishResult{}, fmt.Errorf("读取群文件: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return PublishResult{}, fmt.Errorf("群文件不是非空普通文件: %w", ErrGroupFileInvalid)
	}
	if info.Size() > groupFileMaxBytes {
		return PublishResult{}, ErrGroupFileTooLarge
	}
	plain, err := os.ReadFile(path)
	if err != nil {
		return PublishResult{}, fmt.Errorf("读取群文件: %w", err)
	}
	if int64(len(plain)) != info.Size() {
		return PublishResult{}, fmt.Errorf("群文件读取不完整: %w", ErrGroupFileInvalid)
	}
	if ctx == nil {
		ctx = context.Background()
	}

	key, err := filecrypto.GenerateFileKey()
	if err != nil {
		return PublishResult{}, err
	}
	cc, err := filecrypto.NewChunkCipher(key)
	if err != nil {
		return PublishResult{}, err
	}
	ciphertext := cc.Seal(0, plain)
	if len(ciphertext) > MaxStorageObjectSize {
		return PublishResult{}, ErrGroupFileTooLarge
	}
	sum := sha256.Sum256(plain)
	if mime == "" {
		mime = "application/octet-stream"
	}

	// 群密钥：正文用群密钥加密，只有群成员能解出附件密钥。
	gkey, err := s.latestKey(ctx, groupID)
	if err != nil {
		return PublishResult{}, err
	}

	// 自己生成 msg_uuid，使群盘对象键与信封 msg_uuid 一致；签名绑定完整 body。
	uuidRaw := make([]byte, 16)
	if _, err := rand.Read(uuidRaw); err != nil {
		return PublishResult{}, fmt.Errorf("生成 msg_uuid: %w", err)
	}
	uuid := hex.EncodeToString(uuidRaw)
	blobRef := groupFileObjectKey(groupID, uuid)

	cfg, err := s.StorageConfigFor(ctx, groupID)
	if err != nil {
		return PublishResult{}, err
	}
	objects, err := s.objectStore(cfg)
	if err != nil {
		return PublishResult{}, err
	}
	if _, err := objects.Put(ctx, blobRef, ciphertext, groupFileObjType); err != nil {
		return PublishResult{}, fmt.Errorf("%w: %v", ErrStorageWrite, err)
	}

	innerMsg := &nexmemv1.InnerMessage{
		Attachments: []*nexmemv1.Attachment{{
			Name:    filepath.Base(path),
			Size:    uint64(info.Size()),
			Mime:    mime,
			Sha256:  sum[:],
			BlobRef: blobRef,
			Key:     key,
		}},
	}
	inner, err := proto.Marshal(innerMsg)
	if err != nil {
		return PublishResult{}, fmt.Errorf("序列化群附件元数据: %w", err)
	}
	body, err := SealGroupBody(gkey, inner)
	if err != nil {
		return PublishResult{}, err
	}
	// 校验成员资格后构造签名信封（签名绑定完整 body）。
	ok, err := s.isMember(ctx, groupID, s.account.Pub())
	if err != nil {
		return PublishResult{}, err
	}
	if !ok {
		return PublishResult{}, ErrNotMember
	}
	env := &nexmemv1.GroupEnvelope{
		GroupId:       append([]byte(nil), groupID...),
		SenderAccount: s.account.Pub(),
		MsgUuid:       uuidRaw,
		SentAt:        time.Now().UnixMilli(),
		KeyVersion:    gkey.Version,
		Body:          body,
	}
	env.Signature = s.account.Sign(canonicalEnvelope(env))
	if err := s.publishEnvelope(ctx, groupID, env); err != nil {
		return PublishResult{}, err
	}
	s.emitSent(SentEvent{
		GroupID:     append([]byte(nil), groupID...),
		MsgUUID:     uuid,
		SentAt:      env.GetSentAt(),
		ContentType: int32(nexmemv1.ContentType_CONTENT_TYPE_FILE),
		Inner:       inner,
	})
	return PublishResult{MsgUUID: uuid, Stored: true}, nil
}

// DownloadFile 从群盘取回群文件密文并用附件密钥解密，返回明文。
func (s *Service) DownloadFile(ctx context.Context, groupID []byte, blobRef string, key []byte) ([]byte, error) {
	if !strings.HasPrefix(blobRef, StoragePrefix(groupID)+"files/") {
		return nil, fmt.Errorf("群文件对象键非法: %w", ErrGroupFileInvalid)
	}
	cfg, err := s.StorageConfigFor(ctx, groupID)
	if err != nil {
		return nil, err
	}
	objects, err := s.objectStore(cfg)
	if err != nil {
		return nil, err
	}
	data, info, err := objects.Get(ctx, blobRef)
	if err != nil {
		return nil, fmt.Errorf("下载群文件: %w", err)
	}
	if info.Size > MaxStorageObjectSize || int64(len(data)) > MaxStorageObjectSize {
		return nil, ErrGroupFileTooLarge
	}
	cc, err := filecrypto.NewChunkCipher(key)
	if err != nil {
		return nil, err
	}
	plain, err := cc.Open(0, data)
	if err != nil {
		return nil, fmt.Errorf("解密群文件: %w", err)
	}
	return plain, nil
}
