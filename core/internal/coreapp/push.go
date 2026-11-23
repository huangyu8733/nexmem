package coreapp

// 客户端推送令牌上报（C-07）。
//
// Go 内核不直接对接 APNs/FCM：设备令牌由客户端从宿主获取，经 gateway 的
// push.register / push.unregister 上报，内核签名后转交索引服务
// （POST/DELETE /v1/push/token）落 push_tokens 表。真正的静默推送由索引服务的
// push.Client 在离线投递时触发；iOS 宿主与 APNs 凭证属 R-16。

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"

	"github.com/nexmem/core/gateway"
)

// pushTokenPattern 与服务端 server/directory/push.go 保持一致，提前在客户端侧拒绝非法令牌。
var pushTokenPattern = regexp.MustCompile(`^[A-Za-z0-9:_\-\.]{16,512}$`)

// pushEnvAllowed 是合法的推送环境取值；留空由服务端按默认处理。
var pushEnvAllowed = map[string]bool{
	"":            true,
	"production":  true,
	"development": true,
	"sandbox":     true,
}

type pushTokenParams struct {
	Token string `json:"token"`
	Env   string `json:"env"`
}

func (p *pushTokenParams) validate() (token, env string, ok bool) {
	token = strings.TrimSpace(p.Token)
	env = strings.ToLower(strings.TrimSpace(p.Env))
	if !pushTokenPattern.MatchString(token) {
		return "", "", false
	}
	if !pushEnvAllowed[env] {
		return "", "", false
	}
	return token, env, true
}

// pushRegisterHandler 处理 push.register：校验设备令牌后转交索引服务登记。
func (a *App) pushRegisterHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		if !a.isStarted() {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核未启动")
		}
		var in pushTokenParams
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "push.register 参数 JSON 非法")
		}
		token, env, ok := in.validate()
		if !ok {
			return nil, gateway.NewError(gateway.CodeInvalidArg,
				"设备令牌格式非法或 env 不支持（需 16-512 字符，env 为 production/development/sandbox）")
		}
		a.mu.RLock()
		client := a.dir
		a.mu.RUnlock()
		if client == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "未配置索引服务，推送令牌无法上报")
		}
		total, err := client.RegisterPushToken(ctx, token, env)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeNotOnline, "上报推送令牌失败: %s", err.Error())
		}
		a.log.Info("push", "推送令牌已登记", map[string]any{"tokens": total, "env": env})
		return map[string]any{"registered": true, "tokens": total}, nil
	}
}

// pushUnregisterHandler 处理 push.unregister：注销一个设备令牌。
func (a *App) pushUnregisterHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		if !a.isStarted() {
			return nil, gateway.NewError(gateway.CodeNotStarted, "内核未启动")
		}
		var in pushTokenParams
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "push.unregister 参数 JSON 非法")
		}
		token, env, ok := in.validate()
		if !ok {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "设备令牌格式非法或 env 不支持")
		}
		a.mu.RLock()
		client := a.dir
		a.mu.RUnlock()
		if client == nil {
			return nil, gateway.NewError(gateway.CodeNotStarted, "未配置索引服务，推送令牌无法注销")
		}
		removed, err := client.DeletePushToken(ctx, token, env)
		if err != nil {
			return nil, gateway.NewError(gateway.CodeNotOnline, "注销推送令牌失败: %s", err.Error())
		}
		return map[string]any{"removed": removed}, nil
	}
}
