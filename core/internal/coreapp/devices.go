package coreapp

// 设备列表查询（P6-21，ui-spec.md §4/§7）：
// 「我的设备」与好友资料页都从索引服务的公开档案里读设备证书，
// 不新增本地上行报文，也不改动档案格式。

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	lpcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/contacts"
	"github.com/nexmem/core/internal/directory"
)

// devicesQueryTimeout 是单次档案查询的超时时间。
const devicesQueryTimeout = 10 * time.Second

// accountDevicesHandler 返回账号（缺省本机）已发布的设备证书列表。
//
// 契约 `account.devices`：peer 为空表示本机账号；档案不存在时返回
// found=false 的空列表，让界面区分「未发布」与「发布但没有设备」。
func (a *App) accountDevicesHandler() gateway.HandlerFunc {
	type params struct {
		Peer string `json:"peer"`
	}
	return func(ctx context.Context, raw json.RawMessage) (any, *gateway.Error) {
		var in params
		if len(raw) > 0 {
			if err := json.Unmarshal(raw, &in); err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "params 解析失败")
			}
		}
		a.mu.RLock()
		acc, devKey, dir, started := a.account, a.devKey, a.dir, a.started
		a.mu.RUnlock()
		if !started || acc == nil || devKey == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核尚未启动")
		}
		if dir == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "未配置索引服务，无法查询设备列表")
		}

		owner := acc.Pub()
		self := true
		if arg := strings.TrimSpace(in.Peer); arg != "" {
			pub, err := contacts.ParseAccountID(arg)
			if err != nil {
				return nil, gateway.NewError(gateway.CodeInvalidArg, "peer 不是合法的账号公钥")
			}
			if !bytes.Equal(pub, owner) {
				owner, self = pub, false
			}
		}

		ctx, cancel := context.WithTimeout(ctx, devicesQueryTimeout)
		defer cancel()
		profile, err := dir.GetProfile(ctx, owner)
		if errors.Is(err, directory.ErrProfileNotFound) {
			return map[string]any{"items": []any{}, "found": false, "self": self}, nil
		}
		if err != nil {
			return nil, gateway.NewError(gateway.CodeNotOnline, "查询公开档案失败: %v", err)
		}

		localPub, err := lpcrypto.MarshalPublicKey(devKey.GetPublic())
		if err != nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "读取本机设备公钥失败")
		}
		// 复用合并逻辑做去重、过期剔除与按签发时间倒序，展示与发布口径一致。
		certs := mergeProfileDevices(profile, nil, time.Now())
		items := make([]map[string]any, 0, len(certs))
		for _, cert := range certs {
			items = append(items, map[string]any{
				"device_name": cert.DeviceName,
				"device_id":   devicePeerID(cert.DevicePub),
				"issued_at":   cert.IssuedAt,
				"not_after":   cert.NotAfter,
				"current":     self && bytes.Equal(cert.DevicePub, localPub),
			})
		}
		return map[string]any{"items": items, "found": true, "self": self}, nil
	}
}

// devicePeerID 把证书里的设备公钥转成 PeerID 字符串；编码非法时返回空串。
func devicePeerID(raw []byte) string {
	pub, err := lpcrypto.UnmarshalPublicKey(raw)
	if err != nil {
		return ""
	}
	id, err := peer.IDFromPublicKey(pub)
	if err != nil {
		return ""
	}
	return id.String()
}
