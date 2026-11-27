// Command nexmem-directory 启动 Nexmem 索引服务（P3-04）。
//
// 服务提供公开档案与上传票据池两组接口，默认监听 :8081，数据库落在 data/directory.db。
//
//	go run ./cmd/nexmem-directory -addr :8081 -db ../data/directory.db
package main

import (
	"context"
	"encoding/json"
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
	fcmAccount := flag.String("fcm-account", envOr("NEXMEM_FCM_ACCOUNT", ""), "FCM 服务账号 JSON 路径（留空关闭 Android 唤醒推送）")
	vapidKey := flag.String("vapid-key", envOr("NEXMEM_VAPID_KEY", ""), "Web Push VAPID P-256 私钥 .pem 路径（留空关闭 Web 唤醒推送）")
	vapidSubject := flag.String("vapid-subject", envOr("NEXMEM_VAPID_SUBJECT", ""), "VAPID Subject，如 mailto:admin@example.com")
	flag.Parse()

	cfg := directory.Config{}
	var apnsSender *push.Client
	if *apnsKey != "" {
		raw, err := os.ReadFile(*apnsKey)
		if err != nil {
			log.Fatalf("读取 APNs 密钥: %v", err)
		}
		apnsSender, err = push.New(push.Config{
			KeyID:         *apnsKeyID,
			TeamID:        *apnsTeamID,
			BundleID:      *apnsBundleID,
			PrivateKeyPEM: raw,
			Sandbox:       *apnsSandbox,
		})
		if err != nil {
			log.Printf("APNs 推送配置无效，已跳过：%v", err)
			apnsSender = nil
		}
	}

	var fcmSender *push.FCMClient
	if *fcmAccount != "" {
		raw, err := os.ReadFile(*fcmAccount)
		if err != nil {
			log.Printf("读取 FCM 服务账号失败，已跳过：%v", err)
		} else {
			var sa push.ServiceAccount
			if err := json.Unmarshal(raw, &sa); err != nil {
				log.Printf("FCM 服务账号 JSON 非法，已跳过：%v", err)
			} else if fcmSender, err = push.NewFCM(sa); err != nil {
				log.Printf("FCM 推送配置无效，已跳过：%v", err)
				fcmSender = nil
			}
		}
	}

	var webSender *push.WebPushClient
	if *vapidKey != "" {
		raw, err := os.ReadFile(*vapidKey)
		if err != nil {
			log.Printf("读取 VAPID 私钥失败，已跳过：%v", err)
		} else if webSender, err = push.NewWebPush(push.WebPushConfig{
			Subject:       *vapidSubject,
			PrivateKeyPEM: string(raw),
		}); err != nil {
			log.Printf("Web Push 配置无效，已跳过：%v", err)
			webSender = nil
		}
	}

	router := push.NewRouter(apnsSender, fcmSender, webSender)
	cfg.Push = router
	log.Printf("唤醒推送路由：apns=%v fcm=%v web=%v", apnsSender != nil, fcmSender != nil, webSender != nil)

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
