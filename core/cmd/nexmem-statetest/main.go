// nexmem-statetest 是 P1-12 的内核 CLI 验收程序：
// 在同一进程内启动两台独立设备（各自的设备密钥与 libp2p host），
// 建立直连后启动状态机，断开连接验证 10s 内进入 degraded，
// 重连后验证 15s 内回到 online。
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

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"

	"github.com/nexmem/core/internal/netnode"
)

var (
	listen  = flag.String("listen", "/ip4/127.0.0.1/tcp/0,/ip4/127.0.0.1/tcp/0", "两台设备的监听地址，逗号分隔")
	timeout = flag.Duration("timeout", 2*time.Minute, "整体超时")
)

const (
	degradeLimit = 10 * time.Second
	recoverLimit = 15 * time.Second
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	runCtx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()

	if err := run(runCtx); err != nil {
		fmt.Printf("RESULT FAIL: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	listens := splitListen(*listen)
	if len(listens) == 0 {
		return fmt.Errorf("监听地址为空")
	}

	root, err := os.MkdirTemp("", "nexmem-statetest-*")
	if err != nil {
		return fmt.Errorf("创建临时目录: %w", err)
	}
	defer os.RemoveAll(root)

	a, err := newHost("A", filepath.Join(root, "a"), listenAt(listens, 0))
	if err != nil {
		return err
	}
	defer a.Close()

	b, err := newHost("B", filepath.Join(root, "b"), listenAt(listens, 1))
	if err != nil {
		return err
	}
	defer b.Close()

	fmt.Printf("DEVICE A peer=%s\n", a.ID())
	fmt.Printf("DEVICE B peer=%s\n", b.ID())

	target := peer.AddrInfo{ID: b.ID(), Addrs: b.Addrs()}
	if err := a.Connect(ctx, target); err != nil {
		return fmt.Errorf("建立直连: %w", err)
	}

	sm := netnode.NewStateMachine(netnode.StateOptions{
		Probe: netnode.HostProbe(a),
		OnChange: func(s netnode.State) {
			fmt.Printf("STATE_CHANGE %s at %s\n", s, time.Now().Format("15:04:05.000"))
		},
	})
	startAt := time.Now()
	if err := sm.Start(ctx); err != nil {
		return fmt.Errorf("启动状态机: %w", err)
	}
	defer sm.Stop()

	if err := waitState(ctx, sm, netnode.StateOnline, 5*time.Second); err != nil {
		return fmt.Errorf("启动后未进入 online: %w", err)
	}
	fmt.Printf("STATE_ONLINE %s (启动 %s)\n", sm.State(), time.Since(startAt).Round(time.Millisecond))

	disconnectAt := time.Now()
	if err := a.Network().ClosePeer(b.ID()); err != nil {
		return fmt.Errorf("断开对端: %w", err)
	}
	if err := waitState(ctx, sm, netnode.StateDegraded, degradeLimit); err != nil {
		return fmt.Errorf("断网后未在 %s 内进入 degraded: %w", degradeLimit, err)
	}
	degradeTook := time.Since(disconnectAt)
	if degradeTook > degradeLimit {
		return fmt.Errorf("断网后 %s 才进入 degraded，超过 %s", degradeTook, degradeLimit)
	}
	fmt.Printf("STATE_DEGRADED %s (断网 %s，上限 %s)\n", sm.State(), degradeTook.Round(time.Millisecond), degradeLimit)

	reconnectAt := time.Now()
	if err := a.Connect(ctx, target); err != nil {
		return fmt.Errorf("重连对端: %w", err)
	}
	if err := waitState(ctx, sm, netnode.StateOnline, recoverLimit); err != nil {
		return fmt.Errorf("重连后未在 %s 内回到 online: %w", recoverLimit, err)
	}
	recoverTook := time.Since(reconnectAt)
	if recoverTook > recoverLimit {
		return fmt.Errorf("重连后 %s 才回到 online，超过 %s", recoverTook, recoverLimit)
	}
	fmt.Printf("STATE_RECOVERED %s (重连 %s，上限 %s)\n", sm.State(), recoverTook.Round(time.Millisecond), recoverLimit)

	sm.Stop()
	if sm.State() != netnode.StateStopped {
		return fmt.Errorf("停止后状态 = %s，期望 stopped", sm.State())
	}

	fmt.Println("RESULT PASS")
	return nil
}

func newHost(name, dir, listen string) (host.Host, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("%s 创建数据目录: %w", name, err)
	}
	priv, err := netnode.LoadOrCreateKey(filepath.Join(dir, "device.key"))
	if err != nil {
		return nil, fmt.Errorf("%s 加载设备密钥: %w", name, err)
	}
	h, err := netnode.NewHost(context.Background(), netnode.Config{
		PrivateKey:       priv,
		Listen:           []string{listen},
		UserAgent:        "nexmem-statetest/0.1.0",
		EnableNATService: true,
		EnableHolePunch:  true,
	})
	if err != nil {
		return nil, fmt.Errorf("%s 启动 host: %w", name, err)
	}
	return h, nil
}

func waitState(ctx context.Context, sm *netnode.StateMachine, want netnode.State, timeout time.Duration) error {
	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return sm.WaitState(waitCtx, want)
}

func splitListen(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

func listenAt(listens []string, idx int) string {
	if idx < len(listens) {
		return listens[idx]
	}
	return listens[0]
}
