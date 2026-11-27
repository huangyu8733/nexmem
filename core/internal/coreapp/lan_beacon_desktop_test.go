package coreapp

import (
	"context"
	"encoding/json"
	"net"
	"reflect"
	"testing"

	"github.com/nexmem/core/gateway"
)

// TestLocalLANIPv4SkipsLoopbackAndLinkLocal 验证桌面端 LAN Beacon 的地址回退
// 不会把回环/链路本地地址当成局域网地址广播出去。
func TestLocalLANIPv4SkipsLoopbackAndLinkLocal(t *testing.T) {
	ips := localLANIPv4()
	seen := map[string]bool{}
	for _, s := range ips {
		if seen[s] {
			t.Fatalf("本机局域网 IP 重复: %s", s)
		}
		seen[s] = true
		ip := net.ParseIP(s)
		if ip == nil || ip.To4() == nil {
			t.Fatalf("返回非 IPv4 地址: %s", s)
		}
		if ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() {
			t.Fatalf("返回了回环/未指定/链路本地地址: %s", s)
		}
	}
	t.Logf("localLANIPv4() = %v", ips)
}

// TestEffectiveLANIPv4InjectionPriority 验证原生注入优先于 Go 枚举，
// 且注入为空时才回退枚举。这是移动端绕开 SELinux 与桌面端回退的分界。
func TestEffectiveLANIPv4InjectionPriority(t *testing.T) {
	injected := []string{"10.0.0.7"}
	got := effectiveLANIPv4(injected)
	if !reflect.DeepEqual(got, injected) {
		t.Fatalf("注入 IP 应原样优先返回，got=%v want=%v", got, injected)
	}
	fallback := effectiveLANIPv4(nil)
	if fallback == nil {
		t.Fatal("回退结果不应为 nil（应为空切片或枚举值）")
	}
	t.Logf("fallback = %v", fallback)
}

// TestLanBeaconAddrs 验证宣告地址包含 IP / TCP 端口 / PeerID 三要素。
func TestLanBeaconAddrs(t *testing.T) {
	got := lanBeaconAddrs([]string{"192.168.1.10", "10.0.0.7"}, 42843, "12D3KooWTest")
	want := []string{
		"/ip4/192.168.1.10/tcp/42843/p2p/12D3KooWTest",
		"/ip4/10.0.0.7/tcp/42843/p2p/12D3KooWTest",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("宣告地址错误:\n got=%v\nwant=%v", got, want)
	}
}

// TestIsVirtualInterface 验证容器/隧道虚拟网卡被识别，物理网卡不被误判，
// 避免 Linux 开发机广播出 Docker 网桥这类无法回连的地址。
func TestIsVirtualInterface(t *testing.T) {
	for _, name := range []string{"docker0", "br-abc123", "veth4f2a", "virbr0", "tun0", "wg0", "tailscale0", "cni0", "flannel.1", "cali123", "dummy0"} {
		if !isVirtualInterface(name) {
			t.Errorf("应识别为虚拟网卡: %s", name)
		}
	}
	for _, name := range []string{"en0", "wlan0", "eth0", "Wi-Fi", "enp3s0"} {
		if isVirtualInterface(name) {
			t.Errorf("物理网卡被误判为虚拟: %s", name)
		}
	}
}

// TestDesktopStartsLANBeaconWithoutInjectedIP 验证桌面/Web 内核在未注入
// lan_addrs 时也能用 Go 枚举的本机 IP 启动 LAN Beacon。若 5357 端口被其他
// 进程占用（例如桌面 App/webd 正在运行），LAN Beacon 无法绑定，此时跳过。
func TestDesktopStartsLANBeaconWithoutInjectedIP(t *testing.T) {
	ips := localLANIPv4()
	if len(ips) == 0 {
		t.Skip("测试机没有可用局域网网卡，跳过桌面 LAN Beacon 启动验证")
	}
	// 5357 是 LAN Beacon 固定端口；被占用时无法在本测试内启动。
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 5357})
	if err != nil {
		t.Skipf("UDP 5357 已被占用，跳过 LAN Beacon 绑定测试: %v", err)
	}
	_ = probe.Close()

	dir := t.TempDir()
	gw := gateway.New()
	app, err := New(gw, &eventLog{})
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	// 不设置 LanAddrs，模拟桌面 macOS/Linux/Windows 与 webd 的启动方式。
	if _, err := app.Start(context.Background(), Config{
		DataDir: dir,
		Listen:  []string{"/ip4/0.0.0.0/tcp/0", "/ip4/0.0.0.0/udp/0/quic-v1"},
	}); err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	t.Cleanup(func() { _ = app.Stop() })

	app.mu.RLock()
	beacon := app.lanBeacon
	app.mu.RUnlock()
	if beacon == nil {
		t.Fatal("桌面端未注入 lan_addrs 时 LAN Beacon 应通过 Go 枚举 IP 启动，实际为 nil")
	}

	// 通过契约诊断确认 lan_beacon_active 为 true。
	raw, gwErr := gw.Handle(context.Background(), "net.discoverDevices", json.RawMessage(`{"limit":1}`))
	if gwErr != nil {
		t.Fatalf("net.discoverDevices 调用失败: %v", gwErr)
	}
	body, _ := json.Marshal(raw)
	var result struct {
		Diagnostics struct {
			LANBeaconActive bool   `json:"lan_beacon_active"`
			BroadcastErr    string `json:"lan_broadcast_error"`
		} `json:"diagnostics"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatalf("解析发现诊断: %v", err)
	}
	if !result.Diagnostics.LANBeaconActive {
		t.Fatalf("诊断应报告 lan_beacon_active=true，实际结果: %s", body)
	}
	t.Logf("桌面 LAN Beacon 已启动, broadcast_err=%q", result.Diagnostics.BroadcastErr)
}
