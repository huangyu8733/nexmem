// nexmem-relay 是官方兜底 Circuit Relay v2 节点：默认关闭 DHT，只提供中继服务，
// 并对单节点每个统计窗口内的转发流量设置上限，超限后拒绝新的预约与中继连接。
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
	"time"

	"github.com/nexmem/core/internal/netnode"
	nrelay "github.com/nexmem/core/server/relay"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	var (
		listen       = flag.String("listen", "/ip4/0.0.0.0/tcp/4001,/ip4/0.0.0.0/udp/4001/quic-v1", "监听地址，逗号分隔")
		announce     = flag.String("announce", "", "对外宣告地址，逗号分隔；留空则使用监听地址")
		idPath       = flag.String("id", "data/relay.key", "节点私钥文件")
		allowPrivate = flag.Bool("allow-private", false, "允许为内网地址的节点保留槽位（仅本地联调）")
		bandwidth    = flag.Int64("bandwidth", 1<<30, "单节点每个窗口的转发字节上限；<=0 表示不限额")
		window       = flag.Duration("window", time.Hour, "带宽统计窗口")
		warnRatio    = flag.Float64("warn-ratio", 0.8, "告警阈值比例，取值 (0,1)")
	)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	priv, err := netnode.LoadOrCreateKey(*idPath)
	if err != nil {
		log.Fatalf("加载私钥失败: %v", err)
	}

	policy := netnode.RelayServicePolicy{
		Enabled:            true,
		AllowPrivate:       *allowPrivate,
		BandwidthLimit:     *bandwidth,
		BandwidthWindow:    *window,
		BandwidthWarnRatio: *warnRatio,
		OnAlert:            logAlert,
	}

	h, err := netnode.NewHost(ctx, netnode.Config{
		PrivateKey:   priv,
		Listen:       splitCSV(*listen),
		Announce:     splitCSV(*announce),
		UserAgent:    "nexmem-relay/0.1.0",
		RelayService: policy,
		ForcePublic:  true,
		ConnLow:      128,
		ConnHigh:     2048,
	})
	if err != nil {
		log.Fatalf("启动中继 host 失败: %v", err)
	}
	defer h.Close()

	addrs := make([]string, 0, len(h.Addrs()))
	for _, a := range h.Addrs() {
		addrs = append(addrs, a.String()+"/p2p/"+h.ID().String())
	}

	out := map[string]any{
		"peer_id":        h.ID().String(),
		"addrs":          addrs,
		"relay":          true,
		"bandwidth":      *bandwidth,
		"window_seconds": int64((*window).Seconds()),
		"warn_ratio":     *warnRatio,
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		log.Fatalf("输出节点信息失败: %v", err)
	}

	log.Printf("中继节点已就绪 peer_id=%s bandwidth=%d window=%s", h.ID(), *bandwidth, *window)
	<-ctx.Done()
	log.Printf("收到退出信号，正在关闭")
}

// logAlert 把限额告警写入结构化日志。
func logAlert(a nrelay.Alert) {
	log.Printf("RELAY_QUOTA_ALERT level=%s used=%d limit=%d window_start=%s reservations=%d circuits=%d",
		a.Level, a.Used, a.Limit, a.WindowStart.Format(time.RFC3339), a.Reservations, a.Circuits)
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
