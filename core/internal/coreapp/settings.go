package coreapp

// 本机键值设置（P6-15）。
//
// 界面偏好（外观主题等）需要跨六端持久化，而 Flutter 侧无法引入插件型依赖
// （见 R-18），因此复用内核的 `kv` 表：客户端只搬运 key/value，落盘、备份与
// 恢复沿用既有链路。键与值都有上限，避免把设置表当作大对象存储。

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/settingsync"
	"github.com/nexmem/core/internal/store"
)

const (
	// maxSettingKeyLen 是设置键长度上限，与契约描述一致。
	maxSettingKeyLen = 64
	// maxSettingValueBytes 是单个设置值上限，超出返回 INVALID_ARG。
	maxSettingValueBytes = 4096
)

// settingKeyPattern 限制键字符集：小写字母/数字，允许 . 与 _ 分隔。
var settingKeyPattern = regexp.MustCompile(`^[a-z0-9]+(?:[._][a-z0-9]+)*$`)

type settingParams struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// settingsGetHandler 实现 settings.get：读取本机设置，未设置时 found=false。
func (a *App) settingsGetHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		dao, gerr := a.settingsDAO()
		if gerr != nil {
			return nil, gerr
		}
		var in settingParams
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "设置参数 JSON 非法")
		}
		key, err := normalizeSettingKey(in.Key)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", err.Error())
		}
		raw, err := dao.GetKV(ctx, key)
		if errors.Is(err, store.ErrNotFound) {
			return map[string]any{"key": key, "value": "", "found": false}, nil
		}
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取设置失败: %v", err)
		}
		return map[string]any{"key": key, "value": string(raw), "found": true}, nil
	}
}

// settingsSetHandler 实现 settings.set：写入设置，value 为空串时清除。
func (a *App) settingsSetHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		dao, gerr := a.settingsDAO()
		if gerr != nil {
			return nil, gerr
		}
		var in settingParams
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "设置参数 JSON 非法")
		}
		key, err := normalizeSettingKey(in.Key)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "%s", err.Error())
		}
		if len(in.Value) > maxSettingValueBytes {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "设置值超过 %d 字节", maxSettingValueBytes)
		}
		if in.Value == "" {
			if err := dao.DeleteKV(ctx, key); err != nil && !errors.Is(err, store.ErrNotFound) {
				return nil, gateway.NewError(gateway.CodeDBError, "清除设置失败: %v", err)
			}
			return map[string]any{}, nil
		}
		if err := dao.SetKV(ctx, key, []byte(in.Value)); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "写入设置失败: %v", err)
		}
		return map[string]any{}, nil
	}
}

// settingsExportHandler 实现 settings.exportSnapshot：把本机 kv 设置编码为校验文本。
func (a *App) settingsExportHandler() gateway.HandlerFunc {
	return func(ctx context.Context, _ json.RawMessage) (any, *gateway.Error) {
		dao, gerr := a.settingsDAO()
		if gerr != nil {
			return nil, gerr
		}
		pairs, err := dao.ListKV(ctx)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "读取设置快照失败: %v", err)
		}
		entries := make([]settingsync.Entry, 0, len(pairs))
		for _, p := range pairs {
			entries = append(entries, settingsync.Entry{Key: p.Key, Value: string(p.Value)})
		}
		snapshot, err := settingsync.Produce(entries)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "生成设置快照失败: %v", err)
		}
		return map[string]any{"snapshot": snapshot, "count": len(entries)}, nil
	}
}

// settingsImportHandler 实现 settings.importSnapshot：校验并合并快照，冲突以导入值覆盖。
func (a *App) settingsImportHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		dao, gerr := a.settingsDAO()
		if gerr != nil {
			return nil, gerr
		}
		var in struct {
			Snapshot string `json:"snapshot"`
			DryRun   bool   `json:"dry_run"`
		}
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "设置快照参数 JSON 非法")
		}
		if in.Snapshot == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少必填参数 snapshot")
		}
		entries, err := settingsync.Consume(in.Snapshot)
		if err != nil {
			switch {
			case errors.Is(err, settingsync.ErrChecksum):
				return nil, gateway.NewError(gateway.CodeInvalidArg, "设置快照校验和错误，可能被篡改")
			case errors.Is(err, settingsync.ErrVersion):
				return nil, gateway.NewError(gateway.CodeInvalidArg, "设置快照版本不支持")
			default:
				return nil, gateway.NewError(gateway.CodeInvalidArg, "设置快照格式非法: %v", err)
			}
		}
		if in.DryRun {
			return map[string]any{"applied": 0, "dry_run": true}, nil
		}
		applied := 0
		for _, e := range entries {
			if err := dao.SetKV(ctx, e.Key, []byte(e.Value)); err != nil {
				return nil, gateway.NewError(gateway.CodeDBError, "导入设置 %s 失败: %v", e.Key, err)
			}
			applied++
		}
		return map[string]any{"applied": applied, "dry_run": false}, nil
	}
}

// settingsDAO 返回已启动内核的 DAO，未就绪时给出 NOT_STARTED。
func (a *App) settingsDAO() (*store.DAO, *gateway.Error) {
	if !a.isStarted() {
		return nil, gateway.NewError(gateway.CodeNotStarted, "内核未启动")
	}
	dao := a.daoHandle()
	if dao == nil {
		return nil, gateway.NewError(gateway.CodeNotStarted, "本地库未就绪")
	}
	return dao, nil
}

// normalizeSettingKey 校验并裁剪设置键。
func normalizeSettingKey(raw string) (string, error) {
	key := strings.TrimSpace(raw)
	if key == "" {
		return "", errors.New("设置键不能为空")
	}
	if len(key) > maxSettingKeyLen {
		return "", errors.New("设置键超过 64 字符")
	}
	if !settingKeyPattern.MatchString(key) {
		return "", errors.New("设置键只能包含小写字母、数字、. 与 _")
	}
	return key, nil
}
