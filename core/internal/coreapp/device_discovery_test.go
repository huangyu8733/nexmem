package coreapp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/libp2p/go-libp2p/p2p/net/mock"

	"github.com/nexmem/core/internal/discovery"
)

func TestDiscoverDevicesMergesPeerbookAndConnections(t *testing.T) {
	mn := mocknet.New()
	defer mn.Close()

	h, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成宿主节点失败: %v", err)
	}
	remote, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成远端节点失败: %v", err)
	}
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("连接 mock 网络失败: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立 mock 连接失败: %v", err)
	}

	book := discovery.NewPeerbook(nil)
	account := strings.Repeat("ab", 32)
	addr := "/ip4/203.0.113.10/tcp/4001/p2p/" + remote.ID().String()
	if err := book.Put(context.Background(), account, remote.ID().String(), []string{addr}, "书房设备"); err != nil {
		t.Fatalf("写入地址簿失败: %v", err)
	}
	a := &App{host: h, book: book}

	data, gerr := a.discoverDevicesHandler()(context.Background(), nil)
	if gerr != nil {
		t.Fatalf("枚举设备失败: %v", gerr)
	}
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("序列化结果失败: %v", err)
	}
	var resp struct {
		Items []struct {
			PeerID    string   `json:"peer_id"`
			AccountID string   `json:"account_id"`
			Label     string   `json:"label"`
			Addrs     []string `json:"addrs"`
			IP        string   `json:"ip"`
			Connected bool     `json:"connected"`
			Source    string   `json:"source"`
		} `json:"items"`
		Total int `json:"total"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("解析结果失败: %v", err)
	}
	if resp.Total != 1 || len(resp.Items) != 1 {
		t.Fatalf("期望 1 台设备，实际 total=%d items=%d", resp.Total, len(resp.Items))
	}
	item := resp.Items[0]
	if item.PeerID != remote.ID().String() {
		t.Fatalf("peer_id 不匹配: %s", item.PeerID)
	}
	if item.AccountID != account {
		t.Fatalf("account_id 不匹配: %s", item.AccountID)
	}
	if item.Label != "书房设备" {
		t.Fatalf("备注不匹配: %s", item.Label)
	}
	if item.IP != "203.0.113.10" {
		t.Fatalf("IP 提取失败: %s", item.IP)
	}
	if !item.Connected {
		t.Fatal("已连接设备未标记 connected")
	}
	if !strings.Contains(item.Source, "peerbook") || !strings.Contains(item.Source, "connected") {
		t.Fatalf("来源未合并: %s", item.Source)
	}
}

func TestDiscoverDevicesPagination(t *testing.T) {
	mn := mocknet.New()
	defer mn.Close()

	h, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成宿主节点失败: %v", err)
	}
	book := discovery.NewPeerbook(nil)
	for i := 1; i <= 3; i++ {
		remote, err := mn.GenPeer()
		if err != nil {
			t.Fatalf("生成远端节点失败: %v", err)
		}
		account := fmt.Sprintf("%064x", i)
		addr := "/ip4/198.51.100." + fmt.Sprintf("%d", i) + "/tcp/4001/p2p/" + remote.ID().String()
		if err := book.Put(context.Background(), account, remote.ID().String(), []string{addr}, ""); err != nil {
			t.Fatalf("写入地址簿失败: %v", err)
		}
	}
	a := &App{host: h, book: book}
	params := json.RawMessage(`{"limit":2,"offset":1}`)
	data, gerr := a.discoverDevicesHandler()(context.Background(), params)
	if gerr != nil {
		t.Fatalf("分页枚举失败: %v", gerr)
	}
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("序列化结果失败: %v", err)
	}
	var resp struct {
		Items  []map[string]any `json:"items"`
		Total  int              `json:"total"`
		Offset int              `json:"offset"`
		Limit  int              `json:"limit"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("解析结果失败: %v", err)
	}
	if resp.Total != 3 || len(resp.Items) != 2 {
		t.Fatalf("分页结果异常: total=%d items=%d", resp.Total, len(resp.Items))
	}
	if resp.Offset != 1 || resp.Limit != 2 {
		t.Fatalf("分页回显异常: offset=%d limit=%d", resp.Offset, resp.Limit)
	}
}

func TestDiscoverDevicesFiltersInfrastructureAndUnknownPeers(t *testing.T) {
	mn := mocknet.New()
	defer mn.Close()

	h, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成宿主节点失败: %v", err)
	}
	relay, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成中继节点失败: %v", err)
	}
	stranger, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成陌生节点失败: %v", err)
	}
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("连接 mock 网络失败: %v", err)
	}
	if err := mn.ConnectAllButSelf(); err != nil {
		t.Fatalf("建立 mock 连接失败: %v", err)
	}

	relayAddr := "/ip4/203.0.113.20/tcp/4001/p2p/" + relay.ID().String()
	a := &App{
		host: h,
		cfg:  Config{RelayAddrs: []string{relayAddr}},
		book: discovery.NewPeerbook(nil),
	}
	data, gerr := a.discoverDevicesHandler()(context.Background(), nil)
	if gerr != nil {
		t.Fatalf("枚举设备失败: %v", gerr)
	}
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("序列化结果失败: %v", err)
	}
	var resp struct {
		Items []map[string]any `json:"items"`
		Total int              `json:"total"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("解析结果失败: %v", err)
	}
	if resp.Total != 0 || len(resp.Items) != 0 {
		t.Fatalf("中继与陌生节点不应出现在账号发现中，实际 total=%d items=%d",
			resp.Total, len(resp.Items))
	}
	for _, item := range resp.Items {
		if item["peer_id"] == stranger.ID().String() {
			t.Fatal("陌生节点不应出现在账号发现中")
		}
	}
}

func TestDiscoverDevicesDiagnostics(t *testing.T) {
	mn := mocknet.New()
	defer mn.Close()

	h, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成宿主节点失败: %v", err)
	}
	relay, err := mn.GenPeer()
	if err != nil {
		t.Fatalf("生成中继节点失败: %v", err)
	}
	if err := mn.LinkAll(); err != nil {
		t.Fatalf("连接 mock 网络失败: %v", err)
	}

	relayAddr := "/ip4/203.0.113.20/tcp/4001/p2p/" + relay.ID().String()
	a := &App{
		host: h,
		cfg:  Config{RelayAddrs: []string{relayAddr}},
		book: discovery.NewPeerbook(nil),
	}
	data, gerr := a.discoverDevicesHandler()(context.Background(), nil)
	if gerr != nil {
		t.Fatalf("枚举设备失败: %v", gerr)
	}
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("序列化结果失败: %v", err)
	}
	var resp struct {
		Diagnostics struct {
			MDNSEnabled   bool     `json:"mdns_enabled"`
			SelfID        string   `json:"self_id"`
			SelfAddrs     []string `json:"self_addrs"`
			FilteredInfra int      `json:"filtered_infra"`
		} `json:"diagnostics"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("解析结果失败: %v", err)
	}
	if resp.Diagnostics.MDNSEnabled {
		t.Fatal("未启动 mDNS 时诊断应标记 mdns_enabled=false")
	}
	if resp.Diagnostics.SelfID != h.ID().String() {
		t.Fatalf("诊断 self_id 应为宿主 PeerID，实际 %s", resp.Diagnostics.SelfID)
	}
	if resp.Diagnostics.SelfAddrs == nil {
		t.Fatal("诊断 self_addrs 应始终是可序列化数组")
	}
}

func TestFirstIPFromAddrsPrefersDirectOverRelay(t *testing.T) {
	const pid = "12D3KooWS3cnEVm6z4XQQB9nXs9WBb5sfaHnck5TRCAfxEKZQFKm"
	addrs := []string{
		"/ip4/203.0.113.7/tcp/4001/p2p/" + pid + "/p2p-circuit/p2p/" + pid,
		"/ip4/198.51.100.9/tcp/4001/p2p/" + pid,
	}
	if got := firstIPFromAddrs(addrs); got != "198.51.100.9" {
		t.Fatalf("期望优先直连 IP，实际 %s", got)
	}
	if got := firstIPFromAddrs(addrs[:1]); got != "203.0.113.7" {
		t.Fatalf("只有中继地址时应回退到中继 IP，实际 %s", got)
	}
}
