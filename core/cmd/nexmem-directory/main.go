// Command nexmem-directory 启动 Nexmem 索引服务（P3-04）。
//
// 服务提供公开档案与上传票据池两组接口，默认监听 :8081，数据库落在 data/directory.db。
//
//	go run ./cmd/nexmem-directory -addr :8081 -db ../data/directory.db
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nexmem/core/internal/push"
	"github.com/nexmem/core/server/directory"
)

func main() {
	addr := flag.String("addr", envOr("NEXMEM_DIRECTORY_ADDR", ":8081"), "HTTP 监听地址")
	dbPath := flag.String("db", envOr("NEXMEM_DIRECTORY_DB", "data/directory.db"), "SQLite 数据库路径")
	apnsKey := flag.String("apns-key", envOr("NEXMEM_APNS_KEY", ""), "APNs 鉴权密钥 .p8 路径（留空关闭唤醒推送）")
	apnsKeyID := flag.String("apns-key-id", envOr("NEXMEM_APNS_KEY_ID", ""), "APNs 鉴权密钥 ID")
	apnsTeamID := flag.String("apns-team-id", envOr("NEXMEM_APNS_TEAM_ID", ""), "Apple Developer 团队 ID")
	apnsBundleID := flag.String("apns-bundle-id", envOr("NEXMEM_APNS_BUNDLE_ID", ""), "应用 Bundle ID（apns-topic）")
	apnsSandbox := flag.Bool("apns-sandbox", os.Getenv("NEXMEM_APNS_SANDBOX") == "1", "使用 APNs 开发环境")
	flag.Parse()

	cfg := directory.Config{}
	if *apnsKey != "" {
		raw, err := os.ReadFile(*apnsKey)
		if err != nil {
			log.Fatalf("读取 APNs 密钥: %v", err)
		}
		client, err := push.New(push.Config{
			KeyID:         *apnsKeyID,
			TeamID:        *apnsTeamID,
			BundleID:      *apnsBundleID,
			PrivateKeyPEM: raw,
			Sandbox:       *apnsSandbox,
		})
		if err != nil {
			log.Fatalf("初始化唤醒推送: %v", err)
		}
		cfg.Push = client
		log.Printf("唤醒推送已启用（sandbox=%v）", *apnsSandbox)
	} else {
		log.Printf("唤醒推送未配置，/v1/push/wake 将返回 enabled=false")
	}

	srv, err := directory.NewWithConfig(*dbPath, cfg)
	if err != nil {
		log.Fatalf("初始化索引服务: %v", err)
	}
	defer srv.Close()

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(shutdownCtx); err != nil {
			log.Printf("索引服务关闭: %v", err)
		}
	}()

	log.Printf("nexmem-directory 监听 %s，数据库 %s", *addr, *dbPath)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("索引服务退出: %v", err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
