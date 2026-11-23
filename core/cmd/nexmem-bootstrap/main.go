package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"

	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/nexmem/core/internal/netnode"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	var (
		listen       = flag.String("listen", "/ip4/0.0.0.0/tcp/4001,/ip4/0.0.0.0/udp/4001/quic-v1", "监听地址，逗号分隔")
		announce     = flag.String("announce", "", "对外宣告地址，逗号分隔；留空则使用监听地址")
		idPath       = flag.String("id", "data/bootstrap.key", "节点私钥文件")
		runDHT       = flag.Bool("dht", true, "运行私有 DHT 服务端")
		relay        = flag.Bool("relay", false, "同时提供 Circuit Relay v2 服务")
		allowPrivate = flag.Bool("allow-private", false, "允许为中继预约接受内网地址（仅本地联调）")
	)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	priv, err := netnode.LoadOrCreateKey(*idPath)
	if err != nil {
		log.Fatalf("加载私钥失败: %v", err)
	}

	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey:       priv,
		Listen:           splitCSV(*listen),
		Announce:         splitCSV(*announce),
		UserAgent:        "nexmem-bootstrap/0.1.0",
		EnableNATService: true,
		EnableHolePunch:  true,
		RelayService: netnode.RelayServicePolicy{
			Enabled:      *relay,
			AllowPrivate: *allowPrivate,
		},
		ForcePublic: *relay,
		ConnLow:     128,
		ConnHigh:    1024,
	})
	if err != nil {
		log.Fatalf("启动 host 失败: %v", err)
	}
	defer h.Close()

	if *runDHT {
		if _, err := netnode.NewDHT(ctx, h, dht.ModeServer, nil); err != nil {
			log.Fatalf("启动 DHT 失败: %v", err)
		}
	}

	addrs := make([]string, 0, len(h.Addrs()))
	for _, a := range h.Addrs() {
		addrs = append(addrs, a.String()+"/p2p/"+h.ID().String())
	}

	// stdout 只输出一行 JSON，便于脚本解析；日志一律走 stderr。
	out := map[string]any{
		"peer_id": h.ID().String(),
		"addrs":   addrs,
		"dht":     *runDHT,
		"relay":   *relay,
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		log.Fatalf("输出节点信息失败: %v", err)
	}

	log.Printf("节点已就绪 peer_id=%s relay=%v", h.ID(), *relay)
	<-ctx.Done()
	log.Printf("收到退出信号，正在关闭")
}

func splitCSV(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
