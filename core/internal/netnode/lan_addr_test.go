package netnode

import (
	"strings"
	"testing"

	"github.com/multiformats/go-multiaddr"
)

func TestExpandUnspecifiedWithLan(t *testing.T) {
	parse := func(s string) multiaddr.Multiaddr {
		a, err := multiaddr.NewMultiaddr(s)
		if err != nil {
			t.Fatalf("解析地址 %s 失败: %v", s, err)
		}
		return a
	}
	addrs := []multiaddr.Multiaddr{
		parse("/ip4/0.0.0.0/tcp/4001"),
		parse("/ip4/0.0.0.0/udp/4002/quic-v1"),
		parse("/ip4/203.0.113.5/tcp/4003"),
		parse("/ip4/127.0.0.1/tcp/4004"),
		parse("/ip6/::/tcp/4005"),
	}
	out := expandUnspecifiedWithLan(addrs, []string{"192.168.10.91"})
	got := make([]string, 0, len(out))
	for _, a := range out {
		got = append(got, a.String())
	}

	// 注入 IP 应补全 TCP 与 QUIC 两种通配地址。
	for _, want := range []string{
		"/ip4/192.168.10.91/tcp/4001",
		"/ip4/192.168.10.91/udp/4002/quic-v1",
	} {
		if !contains(got, want) {
			t.Fatalf("期望注入地址 %s，实际列表 %v", want, got)
		}
	}
	// 非通配地址应原样保留。
	for _, want := range []string{
		"/ip4/203.0.113.5/tcp/4003",
		"/ip4/127.0.0.1/tcp/4004",
		"/ip6/::/tcp/4005",
	} {
		if !contains(got, want) {
			t.Fatalf("期望保留地址 %s，实际列表 %v", want, got)
		}
	}
	// 原始 0.0.0.0 也应保留，避免丢失端口信息。
	if !contains(got, "/ip4/0.0.0.0/tcp/4001") {
		t.Fatalf("期望保留原始通配地址，实际列表 %v", got)
	}
}

func TestExpandUnspecifiedWithLanDeduplicates(t *testing.T) {
	a, err := multiaddr.NewMultiaddr("/ip4/0.0.0.0/tcp/4001")
	if err != nil {
		t.Fatal(err)
	}
	out := expandUnspecifiedWithLan(
		[]multiaddr.Multiaddr{a},
		[]string{"192.168.10.91", "192.168.10.91"},
	)
	count := 0
	for _, addr := range out {
		if strings.Contains(addr.String(), "/ip4/192.168.10.91/tcp/4001") {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("重复注入 IP 应去重，实际出现 %d 次", count)
	}
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}
