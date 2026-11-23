package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	"github.com/nexmem/core/internal/diag"
	"github.com/nexmem/core/internal/metrics"
	"github.com/nexmem/core/internal/netnode"
	"github.com/nexmem/core/internal/spike"
)

var (
	role        = flag.String("role", "echo", "角色：echo | dial")
	listen      = flag.String("listen", "/ip4/0.0.0.0/tcp/0,/ip4/0.0.0.0/udp/0/quic-v1", "监听地址，逗号分隔")
	idPath      = flag.String("id", "", "节点私钥文件（留空则每次生成临时身份）")
	bootstrap   = flag.String("bootstrap", "", "bootstrap 节点地址（multiaddr，含 /p2p/<id>）")
	relayAddr   = flag.String("relay", "", "中继节点地址（multiaddr，含 /p2p/<id>）")
	targetPeer  = flag.String("peer", "", "dial 目标 PeerID")
	via         = flag.String("via", "dht", "dial 寻址方式：dht | circuit")
	scenario    = flag.String("scenario", "local", "场景名称，写入 CSV")
	iterations  = flag.Int("iter", 1, "dial 重复次数")
	csvPath     = flag.String("csv", "", "CSV 输出路径（留空则不写文件）")
	diagPath    = flag.String("diag", "", "脱敏诊断日志导出路径（留空则不导出）")
	timeout     = flag.Duration("timeout", 20*time.Second, "单次连接/寻址超时")
	upgradeWait = flag.Duration("upgrade-wait", 10*time.Second, "中继连接后等待打洞升级为直连的时长")
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	switch *role {
	case "echo":
		runEcho(ctx)
	case "dial":
		runDial(ctx)
	default:
		log.Fatalf("未知角色 %q，可选 echo | dial", *role)
	}
}

func hostConfig() netnode.Config {
	var staticRelays []peer.AddrInfo
	if *relayAddr != "" {
		ai, err := peer.AddrInfoFromString(*relayAddr)
		if err != nil {
			log.Fatalf("解析中继地址失败: %v", err)
		}
		staticRelays = append(staticRelays, *ai)
	}

	id := *idPath
	if id == "" {
		dir, err := os.MkdirTemp("", "nexmem-spike-*")
		if err != nil {
			log.Fatalf("创建临时身份目录失败: %v", err)
		}
		id = filepath.Join(dir, "id.key")
	}
	priv, err := netnode.LoadOrCreateKey(id)
	if err != nil {
		log.Fatalf("加载私钥失败: %v", err)
	}

	return netnode.Config{
		PrivateKey:       priv,
		Listen:           splitCSV(*listen),
		UserAgent:        "nexmem-spike/0.1.0",
		EnableNATService: true,
		EnableHolePunch:  true,
		Relay: netnode.RelayPolicy{
			Enabled: true,
			Relays:  staticRelays,
		},
		ConnLow:  32,
		ConnHigh: 256,
	}
}

func bootstrapInfo() peer.AddrInfo {
	if *bootstrap == "" {
		log.Fatal("必须通过 -bootstrap 指定 bootstrap 节点地址")
	}
	ai, err := peer.AddrInfoFromString(*bootstrap)
	if err != nil {
		log.Fatalf("解析 bootstrap 地址失败: %v", err)
	}
	return *ai
}

func runEcho(ctx context.Context) {
	h, err := netnode.NewHost(ctx, hostConfig())
	if err != nil {
		log.Fatalf("启动 host 失败: %v", err)
	}
	defer h.Close()

	boot := bootstrapInfo()
	if err := h.Connect(ctx, boot); err != nil {
		log.Fatalf("连接 bootstrap 失败: %v", err)
	}
	d, err := netnode.NewDHT(ctx, h, dht.ModeAuto, []peer.AddrInfo{boot})
	if err != nil {
		log.Fatalf("启动 DHT 失败: %v", err)
	}
	defer d.Close()

	h.SetStreamHandler(spike.PID, func(s network.Stream) {
		defer s.Close()
		payload, err := spike.Read(s, spike.MaxFrameSize)
		if err != nil {
			log.Printf("读取回显请求失败: %v", err)
			return
		}
		if err := spike.Write(s, payload); err != nil {
			log.Printf("写回显响应失败: %v", err)
		}
	})

	fmt.Printf("ECHO_READY peer_id=%s\n", h.ID())
	printAddrs(h, "ECHO_ADDR")

	// 显式向中继预约 slot：AutoRelay 在本机环回场景下可能判定无需中继，
	// P0 需要确定性地验证 circuit 链路，因此这里主动 Reserve。
	if *relayAddr != "" {
		relayInfo, err := peer.AddrInfoFromString(*relayAddr)
		if err != nil {
			log.Fatalf("解析中继地址失败: %v", err)
		}
		reserveCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
		defer cancel()
		if err := h.Connect(reserveCtx, *relayInfo); err != nil {
			log.Printf("连接中继失败: %v", err)
		}
		rv, err := client.Reserve(reserveCtx, h, *relayInfo)
		if err != nil {
			log.Printf("中继预约失败: %v", err)
		} else {
			fmt.Println("ECHO_RELAY_READY")
			for _, a := range rv.Addrs {
				fmt.Printf("ECHO_CIRCUIT %s/p2p/%s\n", a, h.ID())
			}
		}
	}

	<-ctx.Done()
	log.Printf("echo 节点退出")
}

func runDial(ctx context.Context) {
	if *targetPeer == "" {
		log.Fatal("dial 角色必须通过 -peer 指定目标 PeerID")
	}
	target, err := peer.Decode(*targetPeer)
	if err != nil {
		log.Fatalf("解析目标 PeerID 失败: %v", err)
	}

	h, err := netnode.NewHost(ctx, hostConfig())
	if err != nil {
		log.Fatalf("启动 host 失败: %v", err)
	}
	defer h.Close()

	boot := bootstrapInfo()
	if err := h.Connect(ctx, boot); err != nil {
		log.Fatalf("连接 bootstrap 失败: %v", err)
	}
	d, err := netnode.NewDHT(ctx, h, dht.ModeAuto, []peer.AddrInfo{boot})
	if err != nil {
		log.Fatalf("启动 DHT 失败: %v", err)
	}
	defer d.Close()

	var out *metrics.Writer
	if *csvPath != "" {
		out, err = metrics.Open(*csvPath)
		if err != nil {
			log.Fatalf("打开 CSV 失败: %v", err)
		}
		defer out.Close()
	}

	rec := diag.NewRecorder(diag.New(diag.WithBufferSize(2048)))
	for i := 1; i <= *iterations; i++ {
		s := dialOnce(ctx, h, d, target, rec)
		s.Time = time.Now().Format(time.RFC3339)
		s.Scenario = *scenario
		s.Role = "dial"
		s.Iter = i
		s.Target = target.String()
		s.Via = *via

		fmt.Printf("iter=%d success=%v direct=%v relayed=%v transport=%s connect_ms=%d upgrade_ms=%d rtt_ms=%d err=%q\n",
			s.Iter, s.Success, s.Direct, s.Relayed, s.Transport, s.ConnectMS, s.UpgradeMS, s.RTTMS, s.Error)

		if out != nil {
			if err := out.Write(s); err != nil {
				log.Printf("写 CSV 失败: %v", err)
			}
		}
		_ = h.Network().ClosePeer(target)
		time.Sleep(500 * time.Millisecond)
	}

	if *diagPath != "" {
		size, err := rec.Logger().ExportFile(*diagPath)
		if err != nil {
			log.Printf("导出诊断日志失败: %v", err)
		} else {
			fmt.Printf("DIAG_EXPORT %s bytes=%d\n", *diagPath, size)
		}
	}
}

func dialOnce(ctx context.Context, h host.Host, d *dht.IpfsDHT, target peer.ID, rec *diag.Recorder) metrics.Sample {
	var s metrics.Sample
	s.UpgradeMS = -1
	s.RTTMS = -1

	resolveStart := time.Now()
	addr, err := resolveAddr(ctx, d, target)
	rec.ObserveDHTLookup(time.Since(resolveStart), err)
	if err != nil {
		s.Error = "resolve: " + err.Error()
		return s
	}

	connectCtx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()

	start := time.Now()
	if err := h.Connect(connectCtx, addr); err != nil {
		s.ConnectMS = time.Since(start).Milliseconds()
		s.Error = "connect: " + err.Error()
		rec.ObserveHolePunch("unknown", diag.HolePunchFailed)
		return s
	}
	s.ConnectMS = time.Since(start).Milliseconds()
	s.Success = true

	info := netnode.InspectPeer(h, target)
	s.Direct = info.Direct
	s.Relayed = info.Relayed
	s.Transport = info.Transport
	s.Addrs = strings.Join(info.Addrs, "|")

	// 中继连接建立后，DCUtR 可能在后台升级为直连，这里轮询等待。
	if !info.Direct && *upgradeWait > 0 {
		deadline := time.Now().Add(*upgradeWait)
		for time.Now().Before(deadline) {
			select {
			case <-time.After(500 * time.Millisecond):
			case <-ctx.Done():
				return s
			}
			if cur := netnode.InspectPeer(h, target); cur.Direct {
				s.Direct = true
				s.Relayed = false
				s.Transport = cur.Transport
				s.Addrs = strings.Join(cur.Addrs, "|")
				s.UpgradeMS = time.Since(start).Milliseconds()
				break
			}
		}
	}

	switch {
	case s.Direct:
		rec.ObserveHolePunch(s.Transport, diag.HolePunchDirect)
	case s.Relayed:
		rec.ObserveHolePunch(s.Transport, diag.HolePunchRelayed)
	default:
		rec.ObserveHolePunch(s.Transport, diag.HolePunchFailed)
	}

	streamCtx, streamCancel := context.WithTimeout(ctx, *timeout)
	defer streamCancel()
	// 中继连接是 Limited 连接，默认不允许开流，必须显式放行。
	streamCtx = network.WithAllowLimitedConn(streamCtx, "nexmem-p0-spike")
	stream, err := h.NewStream(streamCtx, target, spike.PID)
	if err != nil {
		s.Error = "newstream: " + err.Error()
		return s
	}
	defer stream.Close()

	payload := []byte(fmt.Sprintf("ping-%d", time.Now().UnixNano()))
	reqStart := time.Now()
	if err := spike.Write(stream, payload); err != nil {
		s.Error = "write: " + err.Error()
		return s
	}
	echo, err := spike.Read(stream, spike.MaxFrameSize)
	if err != nil {
		s.Error = "read: " + err.Error()
		return s
	}
	s.RTTMS = time.Since(reqStart).Milliseconds()
	if string(echo) != string(payload) {
		s.Error = "回显内容不匹配"
	}
	return s
}

func resolveAddr(ctx context.Context, d *dht.IpfsDHT, target peer.ID) (peer.AddrInfo, error) {
	switch *via {
	case "circuit":
		if *relayAddr == "" {
			return peer.AddrInfo{}, fmt.Errorf("via=circuit 需要 -relay")
		}
		relayInfo, err := peer.AddrInfoFromString(*relayAddr)
		if err != nil {
			return peer.AddrInfo{}, err
		}
		return netnode.CircuitAddr(*relayInfo, target)
	case "dht":
		var lastErr error
		// DHT 路由表刚建立时首次查询常失败，重试 3 次以区分「网络不通」与「尚未收敛」。
		for attempt := 0; attempt < 3; attempt++ {
			findCtx, cancel := context.WithTimeout(ctx, *timeout)
			ai, err := d.FindPeer(findCtx, target)
			cancel()
			if err == nil && len(ai.Addrs) > 0 {
				return ai, nil
			}
			if err != nil {
				lastErr = err
			}
			select {
			case <-time.After(2 * time.Second):
			case <-ctx.Done():
				return peer.AddrInfo{}, ctx.Err()
			}
		}
		if lastErr == nil {
			lastErr = fmt.Errorf("FindPeer 未返回可用地址")
		}
		return peer.AddrInfo{}, lastErr
	default:
		return peer.AddrInfo{}, fmt.Errorf("未知 via=%q，可选 dht | circuit", *via)
	}
}

func printAddrs(h host.Host, prefix string) {
	for _, a := range h.Addrs() {
		fmt.Printf("%s %s/p2p/%s\n", prefix, a, h.ID())
	}
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
