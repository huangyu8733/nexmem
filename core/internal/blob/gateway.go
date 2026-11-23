package blob

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/nexmem/core/gateway"
)

// storageTestTimeout 是整轮自检的超时时间：写、读、列、清理共用一个上限。
const storageTestTimeout = 15 * time.Second

// errInvalidConfig 标记配置类错误，映射为 INVALID_ARG 而不是 S3_IO。
var errInvalidConfig = errors.New("配置不合法")

// SelfTestParams 是 storage.test 的入参，字段直接对应配置页表单。
type SelfTestParams struct {
	Endpoint  string `json:"endpoint"`
	Bucket    string `json:"bucket"`
	Prefix    string `json:"prefix"`
	Region    string `json:"region"`
	AccessKey string `json:"ak"`
	SecretKey string `json:"sk"`
	// PathStyle 为 true 时使用 path-style 寻址（MinIO / COS 常见）。
	PathStyle bool `json:"path_style"`
}

// SelfTestResult 是 storage.test 的结果；ok 表示写入、回读与列举全部通过。
type SelfTestResult struct {
	OK        bool  `json:"ok"`
	LatencyMS int64 `json:"latency_ms"`
	Writable  bool  `json:"writable"`
	Listable  bool  `json:"listable"`
}

// Bind 把对象存储自检接入网关的 storage.test 方法（P6-04）。
//
// 自检使用与业务相同的 S3 兼容客户端，因此 R2 / MinIO / OSS / COS / Backblaze B2 / 个人 NAS
// 共用一条代码路径，不按厂商分支。
func Bind(g *gateway.Gateway) error {
	if g == nil {
		return errors.New("缺少网关")
	}
	return g.SetHandler("storage.test", testHandler())
}

func testHandler() gateway.HandlerFunc {
	return func(ctx context.Context, params json.RawMessage) (any, *gateway.Error) {
		var p SelfTestParams
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, gateway.NewError(gateway.CodeInvalidArg, "storage.test 参数不是合法 JSON: %v", err)
		}
		cctx, cancel := context.WithTimeout(ctx, storageTestTimeout)
		defer cancel()
		result, err := SelfTest(cctx, p)
		if err != nil {
			return nil, mapSelfTestError(err)
		}
		return result, nil
	}
}

// SelfTest 对给定配置做一次写入、回读、列举与清理，返回可用性结论。
//
// 失败时返回已完成部分的标志（例如写入成功但列举失败），
// 便于客户端区分「凭证不对」与「只有写权限」。
func SelfTest(ctx context.Context, p SelfTestParams) (SelfTestResult, error) {
	prefix := strings.Trim(strings.TrimSpace(p.Prefix), "/")
	if prefix == "" {
		return SelfTestResult{}, fmt.Errorf("%w: 缺少对象前缀", errInvalidConfig)
	}
	client, err := New(Config{
		Endpoint:  p.Endpoint,
		Region:    p.Region,
		Bucket:    p.Bucket,
		AccessKey: p.AccessKey,
		SecretKey: p.SecretKey,
		PathStyle: p.PathStyle,
		Retries:   0,
	})
	if err != nil {
		return SelfTestResult{}, fmt.Errorf("%w: %v", errInvalidConfig, err)
	}

	suffix, err := randomSuffix()
	if err != nil {
		return SelfTestResult{}, err
	}
	key := prefix + "/_selftest/" + suffix + ".txt"
	payload := []byte("nexmem storage selftest " + time.Now().UTC().Format(time.RFC3339Nano))

	start := time.Now()
	result := SelfTestResult{}
	if _, err := client.Put(ctx, key, payload, "text/plain"); err != nil {
		result.LatencyMS = time.Since(start).Milliseconds()
		return result, fmt.Errorf("写入失败: %w", err)
	}
	result.Writable = true
	defer func() {
		// 清理使用独立的短超时上下文，避免调用方取消后残留测试对象。
		cctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = client.Delete(cctx, key)
	}()

	got, _, err := client.Get(ctx, key)
	if err != nil {
		result.LatencyMS = time.Since(start).Milliseconds()
		return result, fmt.Errorf("回读失败: %w", err)
	}
	if !bytes.Equal(got, payload) {
		result.LatencyMS = time.Since(start).Milliseconds()
		return result, fmt.Errorf("回读内容不一致: %w", ErrIO)
	}

	items, err := client.List(ctx, prefix+"/")
	if err != nil {
		result.LatencyMS = time.Since(start).Milliseconds()
		return result, fmt.Errorf("列举失败: %w", err)
	}
	for _, item := range items {
		if item.Key == key {
			result.Listable = true
			break
		}
	}
	if !result.Listable {
		result.LatencyMS = time.Since(start).Milliseconds()
		return result, fmt.Errorf("列举结果未包含自检对象: %w", ErrIO)
	}

	result.OK = true
	result.LatencyMS = time.Since(start).Milliseconds()
	return result, nil
}

// mapSelfTestError 把 S3 错误分类映射到契约错误码。
func mapSelfTestError(err error) *gateway.Error {
	switch {
	case errors.Is(err, errInvalidConfig):
		return gateway.NewError(gateway.CodeInvalidArg, "%v", err)
	case errors.Is(err, ErrAuth):
		return gateway.NewError(gateway.CodeS3Auth, "对象存储鉴权失败: %v", err)
	case errors.Is(err, ErrQuota):
		return gateway.NewError(gateway.CodeS3Quota, "对象存储配额或限流: %v", err)
	case errors.Is(err, ErrNotFound):
		return gateway.NewError(gateway.CodeS3IO, "桶或对象不存在: %v", err)
	default:
		return gateway.NewError(gateway.CodeS3IO, "对象存储读写失败: %v", err)
	}
}

func randomSuffix() (string, error) {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", fmt.Errorf("生成随机对象名: %w", err)
	}
	return hex.EncodeToString(buf[:]), nil
}
