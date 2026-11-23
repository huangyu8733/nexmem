// Command nexmem-s3test 是 P3-02 的验收 CLI：
// 对同一套 S3 兼容接口执行 PUT / HEAD / GET / LIST / presign / DELETE。
// 加 -selftest 时额外执行 storage.test 自检（P6-04 配置页同一代码路径）。
//
// 示例（MinIO）：
//
//	go run ./cmd/nexmem-s3test -endpoint http://127.0.0.1:9000 -region us-east-1 \
//	  -bucket nexmem -access minioadmin -secret minioadmin -selftest
//
// 示例（Cloudflare R2）：
//
//	go run ./cmd/nexmem-s3test -endpoint https://<account>.r2.cloudflarestorage.com \
//	  -region auto -bucket nexmem -access "$R2_ACCESS_KEY" -secret "$R2_SECRET_KEY" \
//	  -path-style=false
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/nexmem/core/internal/blob"
)

func main() {
	endpoint := flag.String("endpoint", os.Getenv("S3_ENDPOINT"), "S3 Endpoint")
	region := flag.String("region", envOr("S3_REGION", "us-east-1"), "签名区域；R2 用 auto")
	bucket := flag.String("bucket", os.Getenv("S3_BUCKET"), "桶名")
	access := flag.String("access", os.Getenv("S3_ACCESS_KEY"), "Access Key")
	secret := flag.String("secret", os.Getenv("S3_SECRET_KEY"), "Secret Key")
	pathStyle := flag.Bool("path-style", envOr("S3_PATH_STYLE", "true") == "true", "是否使用 path-style 寻址（MinIO 为 true）")
	prefix := flag.String("prefix", fmt.Sprintf("p3-02/%d/", time.Now().UnixNano()), "测试对象前缀")
	withSelfTest := flag.Bool("selftest", false, "同时执行 storage.test 自检（P6-04），用于验证配置页同一代码路径")
	flag.Parse()

	if err := run(*endpoint, *region, *bucket, *access, *secret, *pathStyle, *prefix, *withSelfTest); err != nil {
		fmt.Printf("S3_RESULT=FAIL\nS3_ERROR=%v\n", err)
		os.Exit(1)
	}
}

func run(endpoint, region, bucket, access, secret string, pathStyle bool, prefix string, withSelfTest bool) error {
	client, err := blob.New(blob.Config{
		Endpoint:  endpoint,
		Region:    region,
		Bucket:    bucket,
		AccessKey: access,
		SecretKey: secret,
		PathStyle: pathStyle,
	})
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	prefix = strings.TrimSuffix(prefix, "/") + "/"
	key := prefix + "hello.txt"
	payload := []byte("nexmem p3-02 accept")

	if _, err := client.Put(ctx, key, payload, "text/plain"); err != nil {
		return fmt.Errorf("PUT: %w", err)
	}
	fmt.Printf("S3_PUT=ok key=%s\n", key)

	head, err := client.Head(ctx, key)
	if err != nil {
		return fmt.Errorf("HEAD: %w", err)
	}
	fmt.Printf("S3_HEAD_SIZE=%d\n", head.Size)

	data, _, err := client.Get(ctx, key)
	if err != nil {
		return fmt.Errorf("GET: %w", err)
	}
	if string(data) != string(payload) {
		return fmt.Errorf("GET 内容不一致: %q", data)
	}
	fmt.Println("S3_GET=ok")

	items, err := client.List(ctx, prefix)
	if err != nil {
		return fmt.Errorf("LIST: %w", err)
	}
	if len(items) != 1 || items[0].Key != key {
		return fmt.Errorf("LIST 结果不符: %+v", items)
	}
	fmt.Printf("S3_LIST=%d\n", len(items))

	presignedKey := prefix + "presigned.txt"
	raw, err := client.PresignPut(presignedKey, 5*time.Minute)
	if err != nil {
		return fmt.Errorf("presign: %w", err)
	}
	req, err := http.NewRequest(http.MethodPut, raw, strings.NewReader("presigned-body"))
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("presigned PUT: %w", err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("presigned PUT 状态 %d", resp.StatusCode)
	}
	fmt.Println("S3_PRESIGN=ok")

	if err := client.Delete(ctx, key); err != nil {
		return fmt.Errorf("DELETE: %w", err)
	}
	if err := client.Delete(ctx, presignedKey); err != nil {
		return fmt.Errorf("DELETE presigned: %w", err)
	}
	fmt.Println("S3_DELETE=ok")

	if withSelfTest {
		result, err := blob.SelfTest(ctx, blob.SelfTestParams{
			Endpoint:  endpoint,
			Bucket:    bucket,
			Prefix:    prefix,
			Region:    region,
			AccessKey: access,
			SecretKey: secret,
			PathStyle: pathStyle,
		})
		if err != nil {
			return fmt.Errorf("STORAGE.TEST: %w", err)
		}
		fmt.Printf("STORAGE_TEST=ok writable=%t listable=%t latency_ms=%d\n",
			result.Writable, result.Listable, result.LatencyMS)
	}

	fmt.Println("S3_RESULT=OK")
	return nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
