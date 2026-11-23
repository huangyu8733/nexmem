package group

// 群盘拉取与群游标（P4-06）。
//
// 群盘对象是发送侧写入的单副本签名信封（group_offline/{group_id}/{msg_uuid}.msg），
// 离线成员上线后列出本群前缀，按 LastModified 升序逐条验签，再用信封声明的
// key_version 从密钥环取对应版本密钥解密，最后经 OnMessage 交付给上层，
// 与在线广播共用同一条受理路径。
//
// 每个成员各自维护一条游标（scope 为 group:{base64url(group_id)}），
// 游标保留 1 分钟重叠窗口以覆盖客户端与对象存储的时钟偏差；
// 同一 msg_uuid 的重复对象由指纹窗口短路，不会重复交付。

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"time"

	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	"github.com/nexmem/core/internal/store"
)

const (
	// GroupFetchInterval 是群盘后台拉取的推荐间隔；Options.FetchInterval 未设置时不启动后台拉取。
	GroupFetchInterval = 30 * time.Second
	// groupFetchOverlap 是游标水位向前的重叠窗口，覆盖客户端与对象存储的时钟偏差。
	groupFetchOverlap = time.Minute
	// groupFetchPassTimeout 是单次后台拉取的总超时。
	groupFetchPassTimeout = 2 * time.Minute
	// groupCursorScopePrefix 区分群游标与单聊离线游标。
	groupCursorScopePrefix = "group:"
)

// ErrGroupFetchDisabled 表示本机没有该群的群盘配置，无法拉取离线群消息。
var ErrGroupFetchDisabled = errors.New("群未配置群盘，无法拉取离线消息")

// importOutcome 是单个群盘对象的导入结果。
type importOutcome int

const (
	importSkipped importOutcome = iota
	importImported
	importDuplicate
)

// FetchReport 汇总一次群盘拉取的结果。
type FetchReport struct {
	GroupID   []byte
	Scanned   int // 本次扫描到的对象数
	Imported  int // 验签解密通过并首次交付
	Duplicate int // 已交付过（在线广播或其他拉取），本次跳过
	Skipped   int // 群号不符、验签失败、缺密钥、超限等非法对象
	Failed    int // 对象存储读取失败
}

// GroupCursorScope 返回某个群在本机的游标 scope。
func GroupCursorScope(groupID []byte) string {
	return groupCursorScopePrefix + base64.RawURLEncoding.EncodeToString(groupID)
}

// FetchGroup 拉取指定群的群盘对象并补齐离线消息。
//
// 只处理游标水位之后的对象（带 1 分钟重叠），按 LastModified 升序处理；
// 重复对象由指纹窗口短路，因此可安全地周期性调用。
func (s *Service) FetchGroup(ctx context.Context, groupID []byte) (FetchReport, error) {
	rep := FetchReport{GroupID: append([]byte(nil), groupID...)}
	if len(groupID) == 0 {
		return rep, ErrGroupIDRequired
	}
	if s.dao == nil {
		return rep, ErrGroupFetchDisabled
	}
	if ctx == nil {
		ctx = context.Background()
	}

	s.fetchMu.Lock()
	defer s.fetchMu.Unlock()

	cfg, err := s.StorageConfigFor(ctx, groupID)
	if err != nil {
		if errors.Is(err, ErrStorageNotConfigured) {
			return rep, ErrGroupFetchDisabled
		}
		return rep, err
	}
	objects, err := s.objectStore(cfg)
	if err != nil {
		return rep, err
	}

	prefix := StoragePrefix(groupID)
	list, err := objects.List(ctx, prefix)
	if err != nil {
		return rep, fmt.Errorf("列出群盘对象: %w", err)
	}

	scope := GroupCursorScope(groupID)
	cur, err := s.dao.GetCursor(ctx, scope)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return rep, err
	}
	cutoff := int64(0)
	if cur != nil && cur.SeenAt > 0 {
		cutoff = cur.SeenAt - groupFetchOverlap.Milliseconds()
	}
	lastKey, lastETag := "", ""
	if cur != nil {
		lastKey, lastETag = cur.ObjectKey, cur.ETag
	}

	sort.SliceStable(list, func(i, j int) bool {
		if !list[i].LastModified.Equal(list[j].LastModified) {
			return list[i].LastModified.Before(list[j].LastModified)
		}
		return list[i].Key < list[j].Key
	})

	scanStart := time.Now()
	for _, obj := range list {
		if !bytes.HasPrefix([]byte(obj.Key), []byte(prefix)) || len(obj.Key) <= len(prefix) {
			continue
		}
		rep.Scanned++
		if obj.Size > MaxStorageObjectSize {
			rep.Skipped++
			lastKey, lastETag = obj.Key, obj.ETag
			continue
		}
		if cutoff > 0 && !obj.LastModified.IsZero() && obj.LastModified.UnixMilli() <= cutoff {
			continue
		}

		data, info, err := objects.Get(ctx, obj.Key)
		if err != nil {
			rep.Failed++
			return rep, fmt.Errorf("拉取群盘对象 %s: %w", obj.Key, err)
		}
		if len(data) > MaxStorageObjectSize {
			rep.Skipped++
		} else {
			switch s.importGroupObject(ctx, groupID, data) {
			case importImported:
				rep.Imported++
			case importDuplicate:
				rep.Duplicate++
			default:
				rep.Skipped++
			}
		}
		lastKey, lastETag = obj.Key, info.ETag
	}

	if err := s.dao.PutCursor(ctx, store.InboxCursor{
		Scope:     scope,
		ObjectKey: lastKey,
		ETag:      lastETag,
		SeenAt:    scanStart.UnixMilli(),
	}); err != nil {
		return rep, err
	}
	return rep, nil
}

// FetchAll 拉取本机全部已配置群盘的群，单个群失败不影响其他群。
// 未配置群盘或缺少群密钥的群会被静默跳过。
func (s *Service) FetchAll(ctx context.Context) ([]FetchReport, error) {
	if s.dao == nil {
		return nil, ErrGroupFetchDisabled
	}
	if ctx == nil {
		ctx = context.Background()
	}
	groups, err := s.dao.ListGroups(ctx)
	if err != nil {
		return nil, fmt.Errorf("读取本地群列表: %w", err)
	}
	if len(groups) == 0 {
		return nil, nil
	}

	reports := make([]FetchReport, 0, len(groups))
	var errs []error
	for _, g := range groups {
		rep, ferr := s.FetchGroup(ctx, g.GroupID)
		if ferr != nil {
			if errors.Is(ferr, ErrGroupFetchDisabled) || errors.Is(ferr, ErrGroupKeyNotFound) {
				continue
			}
			errs = append(errs, fmt.Errorf("群 %x: %w", g.GroupID, ferr))
			continue
		}
		reports = append(reports, rep)
	}
	return reports, errors.Join(errs...)
}

// importGroupObject 校验一个群盘对象并交付给上层。
//
// 顺序：解析 → 群号/发送方校验 → 签名与时间校验 → 按 key_version 取密钥
// → 解密正文 → 指纹去重 → OnMessage。任一环节不合法都返回 importSkipped。
func (s *Service) importGroupObject(ctx context.Context, groupID, data []byte) importOutcome {
	env := &nexmemv1.GroupEnvelope{}
	if err := proto.Unmarshal(data, env); err != nil {
		return importSkipped
	}
	if !bytes.Equal(env.GetGroupId(), groupID) {
		return importSkipped
	}
	if len(env.GetSenderAccount()) != memberIDSize {
		return importSkipped
	}
	// 本机发出的消息在发送侧已处理，拉取时直接跳过。
	if bytes.Equal(env.GetSenderAccount(), s.account.Pub()) {
		return importSkipped
	}
	if err := VerifyEnvelope(env, time.Now(), s.maxAge); err != nil {
		return importSkipped
	}

	key, ok := s.keyForVersion(ctx, groupID, env.GetKeyVersion())
	if !ok {
		// 缺少对应版本密钥（未轮换到或尚未收到信封）时不能解密，跳过。
		return importSkipped
	}
	plaintext, err := OpenGroupBody(key, env.GetBody())
	if err != nil {
		return importSkipped
	}

	uuid := hex.EncodeToString(env.GetMsgUuid())
	if !s.dedupe.Add(uuid) {
		return importDuplicate
	}
	if s.onMsg != nil {
		s.onMsg(Received{
			GroupID:       append([]byte(nil), env.GetGroupId()...),
			SenderAccount: append([]byte(nil), env.GetSenderAccount()...),
			MsgUUID:       uuid,
			SentAt:        env.GetSentAt(),
			KeyVersion:    env.GetKeyVersion(),
			Body:          append([]byte(nil), env.GetBody()...),
			Plaintext:     plaintext,
		})
	}
	return importImported
}

// keyForVersion 取指定版本的群密钥，密钥环缺失时先从本地库重载。
func (s *Service) keyForVersion(ctx context.Context, groupID []byte, version uint32) (GroupKey, bool) {
	if raw, ok := s.keys.Get(groupID, version); ok {
		return GroupKey{GroupID: groupID, Version: version, Key: raw}, true
	}
	if s.dao == nil {
		return GroupKey{}, false
	}
	if err := s.LoadKeys(ctx); err != nil {
		return GroupKey{}, false
	}
	raw, ok := s.keys.Get(groupID, version)
	if !ok {
		return GroupKey{}, false
	}
	return GroupKey{GroupID: groupID, Version: version, Key: raw}, true
}

// groupFetchLoop 启动时立即拉取一次，之后按间隔轮询，实现“上线后补齐”。
func (s *Service) groupFetchLoop() {
	defer s.wait.Done()
	s.runGroupFetch()

	ticker := time.NewTicker(s.fetchEvery)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.runGroupFetch()
		}
	}
}

func (s *Service) runGroupFetch() {
	ctx, cancel := context.WithTimeout(s.ctx, groupFetchPassTimeout)
	defer cancel()
	_, _ = s.FetchAll(ctx)
}
