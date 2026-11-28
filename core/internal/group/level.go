package group

// 群等级配置（本群称呼与等级功能）。
//
// 等级配置只由管理员修改，保存在本机 groups.levels_enabled / levels_json，
// 并通过加密群控制帧同步给成员；成员侧校验发送方为管理员后才更新本机记录。
// 控制帧与聊天正文共用加密群主题，不落消息库、不生成聊天气泡。

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/png" // 注册 PNG 解码器，供 image.DecodeConfig 使用
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/nexmem/core/internal/store"
)

const (
	// MaxLevels 是群等级配置允许的最大等级数。
	MaxLevels = 12
	// MaxLevelNameRunes 是等级名称允许的最大 UTF-8 字符数。
	MaxLevelNameRunes = 16
	// LevelIconSize 是等级图标的边长（像素）。
	LevelIconSize = 64
	// MaxLevelIconBytes 是图标解码后的最大字节数（16 KiB）。
	MaxLevelIconBytes = 16 * 1024
)

var (
	// ErrLevelConfigInvalid 是等级配置非法的总类错误，其余校验错误均可 errors.Is 到它。
	ErrLevelConfigInvalid = errors.New("群等级配置非法")
	// ErrLevelConfigTooMany 表示等级数量超过上限。
	ErrLevelConfigTooMany = errors.New("群等级最多 12 项")
	// ErrLevelIDInvalid 表示等级 ID 为空或含逗号/控制字符。
	ErrLevelIDInvalid = errors.New("群等级 ID 非法")
	// ErrLevelIDDuplicate 表示等级 ID 重复。
	ErrLevelIDDuplicate = errors.New("群等级 ID 重复")
	// ErrLevelNameTooLong 表示等级名称超过 16 字。
	ErrLevelNameTooLong = errors.New("群等级名称最多 16 字")
	// ErrLevelIconInvalid 表示图标不是合法的 64x64 PNG。
	ErrLevelIconInvalid = errors.New("群等级图标必须是 64x64 PNG")
	// ErrLevelIconTooLarge 表示图标解码后超过 16 KiB。
	ErrLevelIconTooLarge = errors.New("群等级图标不能超过 16 KiB")
	// ErrLevelNotFound 表示指定的等级 ID 不在当前配置中。
	ErrLevelNotFound = errors.New("群等级不存在")
)

// GroupLevel 是一个群等级；IconB64 为空表示无图标。
type GroupLevel struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	IconB64 string `json:"icon_b64"`
}

// LevelConfig 是群等级配置总览。
type LevelConfig struct {
	Enabled bool         `json:"enabled"`
	Levels  []GroupLevel `json:"levels"`
}

// pngMagic 是 PNG 文件头魔数。
var pngMagic = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// ValidateLevelConfig 校验等级数量、ID 唯一性与合法性、名称长度与图标内容。
// icon_b64 为空允许；非空必须能被 base64.StdEncoding 解码、带 PNG 魔数、
// image.DecodeConfig 识别出 64x64，且解码后不超过 16 KiB。
func ValidateLevelConfig(cfg LevelConfig) error {
	if len(cfg.Levels) > MaxLevels {
		return fmt.Errorf("%w: %w", ErrLevelConfigInvalid, ErrLevelConfigTooMany)
	}
	seen := make(map[string]struct{}, len(cfg.Levels))
	for _, lv := range cfg.Levels {
		if lv.ID == "" || strings.ContainsRune(lv.ID, ',') || containsControlRune(lv.ID) {
			return fmt.Errorf("%w: %w", ErrLevelConfigInvalid, ErrLevelIDInvalid)
		}
		if _, dup := seen[lv.ID]; dup {
			return fmt.Errorf("%w: %w（%s）", ErrLevelConfigInvalid, ErrLevelIDDuplicate, lv.ID)
		}
		seen[lv.ID] = struct{}{}
		if utf8.RuneCountInString(lv.Name) > MaxLevelNameRunes {
			return fmt.Errorf("%w: %w", ErrLevelConfigInvalid, ErrLevelNameTooLong)
		}
		if err := validateLevelIcon(lv.IconB64); err != nil {
			return err
		}
	}
	return nil
}

func containsControlRune(s string) bool {
	for _, r := range s {
		if unicode.IsControl(r) {
			return true
		}
	}
	return false
}

func validateLevelIcon(iconB64 string) error {
	if iconB64 == "" {
		return nil
	}
	raw, err := base64.StdEncoding.DecodeString(iconB64)
	if err != nil || !bytes.HasPrefix(raw, pngMagic) {
		return fmt.Errorf("%w: %w: base64 解码或 PNG 魔数校验失败", ErrLevelConfigInvalid, ErrLevelIconInvalid)
	}
	if len(raw) > MaxLevelIconBytes {
		return fmt.Errorf("%w: %w", ErrLevelConfigInvalid, ErrLevelIconTooLarge)
	}
	decoded, _, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil || decoded.Width != LevelIconSize || decoded.Height != LevelIconSize {
		return fmt.Errorf("%w: %w", ErrLevelConfigInvalid, ErrLevelIconInvalid)
	}
	return nil
}

// parseLevelConfig 解封后的 levels_json 解析为等级数组；空串表示未配置。
func parseLevelConfig(levelsJSON string) ([]GroupLevel, error) {
	if strings.TrimSpace(levelsJSON) == "" {
		return nil, nil
	}
	var levels []GroupLevel
	if err := json.Unmarshal([]byte(levelsJSON), &levels); err != nil {
		return nil, fmt.Errorf("%w: 解析 levels_json: %v", ErrLevelConfigInvalid, err)
	}
	return levels, nil
}

// SetLevelConfig 由管理员设置或关闭群等级；关闭时清空全部成员的等级 ID。
// 先落本机记录再尽力广播；广播失败不回滚本地结果，与群公告语义一致。
func (s *Service) SetLevelConfig(ctx context.Context, groupID []byte, cfg LevelConfig) (LevelConfig, error) {
	if _, _, err := s.requireAdmin(ctx, groupID); err != nil {
		return LevelConfig{}, err
	}
	if err := ValidateLevelConfig(cfg); err != nil {
		return LevelConfig{}, err
	}
	if s.dao == nil {
		return LevelConfig{}, errors.New("缺少本地 DAO，无法保存群等级配置")
	}
	if cfg.Levels == nil {
		cfg.Levels = []GroupLevel{}
	}
	raw, err := json.Marshal(cfg.Levels)
	if err != nil {
		return LevelConfig{}, fmt.Errorf("编码群等级配置: %w", err)
	}
	if err := s.dao.SetGroupLevels(ctx, groupID, cfg.Enabled, string(raw)); err != nil {
		return LevelConfig{}, err
	}
	if !cfg.Enabled {
		if err := s.dao.ClearMemberLevels(ctx, groupID); err != nil {
			return LevelConfig{}, err
		}
	}
	if frame, err := EncodeLevelsNotice(cfg); err == nil {
		s.publishControlFrame(ctx, groupID, frame)
	}
	return cfg, nil
}

// ApplyLevelConfig 应用入站群等级控制帧：仅接受本地成员表登记的管理员发来的配置。
// 返回 false 表示发送方不是管理员，帧应被丢弃；写库失败返回错误。
func (s *Service) ApplyLevelConfig(ctx context.Context, groupID, senderAccount []byte, cfg LevelConfig) (bool, error) {
	admin, err := s.IsGroupAdmin(ctx, groupID, senderAccount)
	if err != nil {
		return false, err
	}
	if !admin {
		return false, nil
	}
	if err := ValidateLevelConfig(cfg); err != nil {
		return false, err
	}
	if s.dao == nil {
		return false, errors.New("缺少本地 DAO，无法保存群等级配置")
	}
	if cfg.Levels == nil {
		cfg.Levels = []GroupLevel{}
	}
	raw, err := json.Marshal(cfg.Levels)
	if err != nil {
		return false, fmt.Errorf("编码群等级配置: %w", err)
	}
	if err := s.dao.SetGroupLevels(ctx, groupID, cfg.Enabled, string(raw)); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return false, ErrGroupKeyNotFound
		}
		return false, err
	}
	if !cfg.Enabled {
		if err := s.dao.ClearMemberLevels(ctx, groupID); err != nil {
			return false, err
		}
	}
	return true, nil
}
