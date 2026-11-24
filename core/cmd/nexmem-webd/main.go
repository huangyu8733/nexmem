// Command nexmem-webd 启动自托管 Web 网关（P1-15）。
//
// 浏览器经 WebSocket 复用 Request/Response/Event 契约，内核运行在服务端；
// 所有连接必须携带访问令牌，未认证握手直接返回 401。
//
//	go run ./cmd/nexmem-webd -addr :8082 -token <token> -static ../web
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/coreapp"
	"github.com/nexmem/core/server/webd"
)

func main() {
	addr := flag.String("addr", envOr("NEXMEM_WEB_ADDR", ":8082"), "HTTP/WebSocket 监听地址")
	token := flag.String("token", envOr("NEXMEM_WEB_TOKEN", ""), "访问令牌（留空则随机生成并打印）")
	tokenFile := flag.String("token-file", envOr("NEXMEM_WEB_TOKEN_FILE", ""), "访问令牌文件（优先于 -token，修改后自动热轮换）")
	tlsCert := flag.String("tls-cert", envOr("NEXMEM_WEB_TLS_CERT", ""), "TLS 证书路径（PEM），与 -tls-key 同时提供时启用 HTTPS")
	tlsKey := flag.String("tls-key", envOr("NEXMEM_WEB_TLS_KEY", ""), "TLS 私钥路径（PEM）")
	static := flag.String("static", envOr("NEXMEM_WEB_STATIC", "web"), "Flutter Web 构建产物目录")
	origins := flag.String("origins", envOr("NEXMEM_WEB_ORIGINS", ""), "允许的 Origin 白名单，逗号分隔（留空只允许同源）")
	dataDir := flag.String("data-dir", envOr("NEXMEM_DATA_DIR", ""), "内核数据目录；非空时随进程自动启动内核")
	bootstraps := flag.String("bootstraps", envOr("NEXMEM_BOOTSTRAPS", ""), "DHT bootstrap 节点地址，逗号分隔")
	directoryURL := flag.String("directory", envOr("NEXMEM_DIRECTORY_URL", ""), "索引服务地址；配置后发布本机公开档案并支持按账号解析对端")
	relayAddrs := flag.String("relay", envOr("NEXMEM_RELAY_ADDRS", ""), "中继节点多地址，逗号分隔（每条须含 /p2p/<PeerID>）；浏览器端共享此配置")
	enableMDNS := flag.Bool("mdns", envOr("NEXMEM_MDNS", "") == "true", "开启局域网 mDNS 发现（三种发现源之一）")
	publicDHT := flag.Bool("public-dht", envOr("NEXMEM_PUBLIC_DHT", "") == "true", "开启公共 IPFS DHT 兜底寻址")
	manualAddrs := flag.String("manual-addrs", envOr("NEXMEM_MANUAL_ADDRS", ""), "手动导入的对端 multiaddr，逗号分隔")
	displayName := flag.String("display-name", envOr("NEXMEM_DISPLAY_NAME", ""), "本机展示名（写入设备证书）")
	timeout := flag.Duration("timeout", 30*time.Second, "单条请求处理上限")
	flag.Parse()

	if (*tlsCert == "") != (*tlsKey == "") {
		log.Fatalf("TLS 需要同时提供 -tls-cert 与 -tls-key")
	}

	secret := strings.TrimSpace(*token)
	if strings.TrimSpace(*tokenFile) == "" && secret == "" {
		generated, err := randomToken()
		if err != nil {
			log.Fatalf("生成访问令牌: %v", err)
		}
		secret = generated
		log.Printf("未提供令牌，本次使用：%s（重启后失效）", secret)
	}

	gw := gateway.New()
	srv, err := webd.New(webd.Config{
		Token:          secret,
		TokenFile:      strings.TrimSpace(*tokenFile),
		Gateway:        gw,
		StaticDir:      *static,
		AllowedOrigins: splitList(*origins),
		RequestTimeout: *timeout,
	})
	if err != nil {
		log.Fatalf("初始化 Web 网关: %v", err)
	}
	defer srv.Close()

	app, err := coreapp.New(gw, coreapp.EventSinkFunc(func(eventType string, data any) {
		if _, err := srv.Broadcast(eventType, data); err != nil {
			log.Printf("广播事件 %s 失败: %v", eventType, err)
		}
	}))
	if err != nil {
		log.Fatalf("装配内核: %v", err)
	}
	defer app.Close()

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if dir := strings.TrimSpace(*dataDir); dir != "" {
		if _, err := app.Start(ctx, coreapp.Config{
			DataDir:      dir,
			DisplayName:  strings.TrimSpace(*displayName),
			Bootstraps:   splitList(*bootstraps),
			DirectoryURL: strings.TrimSpace(*directoryURL),
			RelayAddrs:   splitList(*relayAddrs),
			EnableMDNS:   *enableMDNS,
			PublicDHT:    *publicDHT,
			ManualAddrs:  splitList(*manualAddrs),
		}); err != nil {
			log.Fatalf("自动启动内核: %v", err)
		}
	}

	if path := strings.TrimSpace(*tokenFile); path != "" {
		go watchTokenFile(ctx, srv, path)
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(shutdownCtx); err != nil {
			log.Printf("Web 网关关闭: %v", err)
		}
	}()

	methods := gw.Methods()
	implemented := 0
	for _, m := range methods {
		if m.Implemented {
			implemented++
		}
	}
	scheme := "http"
	if *tlsCert != "" {
		scheme = "https"
	}
	log.Printf("nexmem-webd 监听 %s://%s，静态目录 %s，契约方法 %d 个（已接入 %d 个）", scheme, *addr, *static, len(methods), implemented)
	if *tlsCert != "" {
		err = httpSrv.ListenAndServeTLS(*tlsCert, *tlsKey)
	} else {
		err = httpSrv.ListenAndServe()
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("Web 网关退出: %v", err)
	}
}

// watchTokenFile 每 2s 检查令牌文件是否变化；变化后热轮换并断开旧连接，
// 使令牌泄露时可以不停机撤销。文件暂时不可读（如原子替换瞬间）保留旧令牌。
func watchTokenFile(ctx context.Context, srv *webd.Server, path string) {
	var lastMod time.Time
	var lastSize int64
	if fi, err := os.Stat(path); err == nil {
		lastMod, lastSize = fi.ModTime(), fi.Size()
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fi, err := os.Stat(path)
			if err != nil || (fi.ModTime().Equal(lastMod) && fi.Size() == lastSize) {
				continue
			}
			lastMod, lastSize = fi.ModTime(), fi.Size()
			changed, err := srv.ReloadTokenFile()
			if err != nil {
				log.Printf("重新加载令牌文件失败，继续使用旧令牌: %v", err)
				continue
			}
			if changed {
				log.Printf("访问令牌已轮换，旧连接已断开")
			}
		}
	}
}

func randomToken() (string, error) {
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func splitList(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if v := strings.TrimSpace(p); v != "" {
			out = append(out, v)
		}
	}
	return out
}
