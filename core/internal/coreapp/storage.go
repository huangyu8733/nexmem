package coreapp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/identity"
)

// 离线存储配置落盘（P6-04）：配置页保存后，下次 core.start 在未显式传入
// storage 时自动启用。AK/SK 以 Keystore 主密钥封装后写入，明文不落盘。
const (
	offlineStorageFile       = "offline_storage.json"
	offlineStorageVersion    = 1
	offlineStorageAKPurpose  = "offline-storage-ak"
	offlineStorageSKPurpose  = "offline-storage-sk"
	offlineStorageConfigPerm = 0o600
)

// storedStorage 是 offline_storage.json 的结构；凭证字段为密文（base64 JSON 信封）。
type storedStorage struct {
	Version   int    `json:"version"`
	Enabled   bool   `json:"enabled"`
	Endpoint  string `json:"endpoint"`
	Bucket    string `json:"bucket"`
	Prefix    string `json:"prefix"`
	Region    string `json:"region"`
	PathStyle bool   `json:"path_style"`
	// Public 为 nil 表示旧版本配置未记录该字段，按「对外公开」处理。
	Public *bool `json:"public,omitempty"`
	// DeleteAfterRead 为 C-02 的显式清理开关；旧版本配置缺省时按 false（lifecycle）处理。
	DeleteAfterRead bool   `json:"delete_after_read,omitempty"`
	AKSealed        string `json:"ak_sealed"`
	SKSealed        string `json:"sk_sealed"`
}

// offlineStorageState 是解封后的离线存储配置。
type offlineStorageState struct {
	Enabled         bool
	Public          bool
	Endpoint        string
	Bucket          string
	Prefix          string
	Region          string
	PathStyle       bool
	AccessKey       string
	SecretKey       string
	DeleteAfterRead bool
}

func offlineStoragePath(dataDir string) string {
	return filepath.Join(dataDir, offlineStorageFile)
}

// readStoredStorage 读取配置文件；不存在时返回 (nil, nil)。
func readStoredStorage(dataDir string) (*storedStorage, error) {
	raw, err := os.ReadFile(offlineStoragePath(dataDir))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("读取离线存储配置: %w", err)
	}
	var rec storedStorage
	if err := json.Unmarshal(raw, &rec); err != nil {
		return nil, fmt.Errorf("解析离线存储配置: %w", err)
	}
	if rec.Version != offlineStorageVersion {
		return nil, fmt.Errorf("离线存储配置版本 %d 不支持", rec.Version)
	}
	return &rec, nil
}

// loadOfflineStorage 读取并解封离线存储配置；未配置时返回 (nil, nil)。
func loadOfflineStorage(dataDir string, ks identity.KeyStore) (*offlineStorageState, error) {
	rec, err := readStoredStorage(dataDir)
	if err != nil || rec == nil {
		return nil, err
	}
	state := &offlineStorageState{
		Enabled:         rec.Enabled,
		Public:          rec.Public == nil || *rec.Public,
		Endpoint:        rec.Endpoint,
		Bucket:          rec.Bucket,
		Prefix:          rec.Prefix,
		Region:          rec.Region,
		PathStyle:       rec.PathStyle,
		DeleteAfterRead: rec.DeleteAfterRead,
	}
	if rec.AKSealed != "" {
		ak, err := identity.OpenSecret(ks, offlineStorageAKPurpose, []byte(rec.AKSealed))
		if err != nil {
			return nil, fmt.Errorf("解封 Access Key: %w", err)
		}
		state.AccessKey = string(ak)
	}
	if rec.SKSealed != "" {
		sk, err := identity.OpenSecret(ks, offlineStorageSKPurpose, []byte(rec.SKSealed))
		if err != nil {
			return nil, fmt.Errorf("解封 Secret Key: %w", err)
		}
		state.SecretKey = string(sk)
	}
	return state, nil
}

// saveOfflineStorage 封装凭证后原子写入配置文件。
func saveOfflineStorage(dataDir string, ks identity.KeyStore, state offlineStorageState) error {
	akSealed, err := identity.SealSecret(ks, offlineStorageAKPurpose, []byte(state.AccessKey))
	if err != nil {
		return fmt.Errorf("封装 Access Key: %w", err)
	}
	skSealed, err := identity.SealSecret(ks, offlineStorageSKPurpose, []byte(state.SecretKey))
	if err != nil {
		return fmt.Errorf("封装 Secret Key: %w", err)
	}
	raw, err := json.MarshalIndent(storedStorage{
		Version:         offlineStorageVersion,
		Enabled:         state.Enabled,
		Endpoint:        state.Endpoint,
		Bucket:          state.Bucket,
		Prefix:          state.Prefix,
		Region:          state.Region,
		PathStyle:       state.PathStyle,
		Public:          &state.Public,
		DeleteAfterRead: state.DeleteAfterRead,
		AKSealed:        string(akSealed),
		SKSealed:        string(skSealed),
	}, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化离线存储配置: %w", err)
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return fmt.Errorf("创建数据目录: %w", err)
	}
	tmp, err := os.CreateTemp(dataDir, ".offline-storage-*.tmp")
	if err != nil {
		return fmt.Errorf("创建临时配置: %w", err)
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(offlineStorageConfigPerm); err != nil {
		tmp.Close()
		return fmt.Errorf("设置配置文件权限: %w", err)
	}
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return fmt.Errorf("写入离线存储配置: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("关闭离线存储配置: %w", err)
	}
	if err := os.Rename(name, offlineStoragePath(dataDir)); err != nil {
		return fmt.Errorf("替换离线存储配置: %w", err)
	}
	return nil
}

// applyStoredStorage 在 core.start 未显式配置存储时套用落盘配置。
//
// 解封失败（如 Keystore 条目被重建）只告警并保持离线存储关闭，
// 不阻塞内核启动；用户可在配置页重新保存凭证。
func (a *App) applyStoredStorage(dataDir string, ks identity.KeyStore, cfg *Config) {
	state, err := loadOfflineStorage(dataDir, ks)
	if err != nil {
		a.log.Warn("core", "读取离线存储配置失败，本次不启用", map[string]any{"error": err.Error()})
		return
	}
	if state == nil || !state.Enabled {
		return
	}
	if state.Endpoint == "" || state.Bucket == "" || state.AccessKey == "" || state.SecretKey == "" {
		a.log.Warn("core", "离线存储配置不完整，本次不启用", map[string]any{})
		return
	}
	public := state.Public
	cfg.Storage = &StorageConfig{
		Endpoint:        state.Endpoint,
		Region:          state.Region,
		Bucket:          state.Bucket,
		AccessKey:       state.AccessKey,
		SecretKey:       state.SecretKey,
		PathStyle:       state.PathStyle,
		Public:          &public,
		DeleteAfterRead: state.DeleteAfterRead,
	}
	a.log.Info("core", "已启用离线存储", map[string]any{"bucket": state.Bucket, "endpoint": state.Endpoint, "public": state.Public})
}

// storageConfigureParams 是 storage.configure 的入参（字段与配置页一致）。
type storageConfigureParams struct {
	Endpoint  string `json:"endpoint"`
	Bucket    string `json:"bucket"`
	Prefix    string `json:"prefix"`
	Region    string `json:"region"`
	AccessKey string `json:"ak"`
	SecretKey string `json:"sk"`
	PathStyle bool   `json:"path_style"`
	// Enabled 留空视为启用；false 表示关闭离线存储（保留其余字段便于再次启用）。
	Enabled *bool `json:"enabled"`
	// Public 控制是否对外公开存储；省略时沿用上次保存的值，首次保存默认公开。
	Public *bool `json:"public"`
	// DeleteAfterRead 开启已读后删除 S3 对象（C-02）；省略时沿用上次保存值。
	DeleteAfterRead *bool `json:"delete_after_read"`
}

// storageGetHandler 实现 storage.get：回显当前落盘配置，绝不返回 Secret Key。
func (a *App) storageGetHandler() gateway.HandlerFunc {
	return func(_ context.Context, _ json.RawMessage) (any, *gateway.Error) {
		dataDir := a.dataDir()
		if dataDir == "" {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		state, err := loadOfflineStorage(dataDir, a.keyStore(dataDir))
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "读取离线存储配置失败: %v", err)
		}
		if state == nil {
			return map[string]any{"configured": false, "enabled": false, "public": true}, nil
		}
		return map[string]any{
			"configured":        true,
			"enabled":           state.Enabled,
			"public":            state.Public,
			"endpoint":          state.Endpoint,
			"bucket":            state.Bucket,
			"prefix":            state.Prefix,
			"region":            state.Region,
			"path_style":        state.PathStyle,
			"ak":                state.AccessKey,
			"delete_after_read": state.DeleteAfterRead,
		}, nil
	}
}

// storageConfigureHandler 实现 storage.configure：保存离线存储配置，下次启动生效。
func (a *App) storageConfigureHandler() gateway.HandlerFunc {
	return func(_ context.Context, params json.RawMessage) (any, *gateway.Error) {
		var p storageConfigureParams
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "storage.configure 参数不是合法 JSON: %v", err)
		}
		dataDir := a.dataDir()
		if dataDir == "" {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		ks := a.keyStore(dataDir)
		previous, err := loadOfflineStorage(dataDir, ks)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "读取离线存储配置失败: %v", err)
		}
		// 公开开关缺省时沿用上次保存的值，首次保存默认公开。
		public := true
		if previous != nil {
			public = previous.Public
		}
		if p.Public != nil {
			public = *p.Public
		}
		// delete_after_read 省略时沿用上次保存值（C-02）。
		deleteAfterRead := false
		if previous != nil {
			deleteAfterRead = previous.DeleteAfterRead
		}
		if p.DeleteAfterRead != nil {
			deleteAfterRead = *p.DeleteAfterRead
		}
		state := offlineStorageState{
			Enabled:         p.Enabled == nil || *p.Enabled,
			Public:          public,
			Endpoint:        strings.TrimSpace(p.Endpoint),
			Bucket:          strings.TrimSpace(p.Bucket),
			Prefix:          strings.Trim(strings.TrimSpace(p.Prefix), "/"),
			Region:          strings.TrimSpace(p.Region),
			PathStyle:       p.PathStyle,
			AccessKey:       strings.TrimSpace(p.AccessKey),
			SecretKey:       p.SecretKey,
			DeleteAfterRead: deleteAfterRead,
		}
		// 只改开关时允许省略凭证，沿用上次保存的值。
		if state.AccessKey == "" && previous != nil {
			state.AccessKey = previous.AccessKey
		}
		if state.SecretKey == "" && previous != nil {
			state.SecretKey = previous.SecretKey
		}
		if state.Endpoint == "" || state.Bucket == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 endpoint 或 bucket")
		}
		if state.AccessKey == "" || state.SecretKey == "" {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "缺少 ak 或 sk")
		}
		if err := saveOfflineStorage(dataDir, ks, state); err != nil {
			return nil, gateway.NewError(gateway.CodeDBError, "保存离线存储配置失败: %v", err)
		}
		return map[string]any{
			"configured":        true,
			"enabled":           state.Enabled,
			"public":            state.Public,
			"delete_after_read": state.DeleteAfterRead,
			"restart_required":  true,
		}, nil
	}
}

// dataDir 返回当前启动配置的数据目录；未启动时为空。
func (a *App) dataDir() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return strings.TrimSpace(a.cfg.DataDir)
}

// keyStore 返回与 core.start 相同的密钥存储实现。
func (a *App) keyStore(dataDir string) identity.KeyStore {
	return identity.NewKeyStore(filepath.Join(dataDir, "keystore.master"))
}
