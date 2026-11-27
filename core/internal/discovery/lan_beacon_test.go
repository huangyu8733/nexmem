package discovery

import (
	"encoding/base64"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/qrshare"
)

func TestLanIPFromMultiaddrs(t *testing.T) {
	addrs := []string{
		"/ip4/0.0.0.0/tcp/4001/p2p/12D3KooX",
		"/ip4/192.168.10.91/tcp/41105/p2p/12D3KooX",
	}
	if got := lanIPFromMultiaddrs(addrs); got != "192.168.10.91" {
		t.Fatalf("局域网 IP = %q，期望 192.168.10.91", got)
	}
	if got := lanIPFromMultiaddrs([]string{"bad", "/ip6/::1/tcp/1"}); got != "" {
		t.Fatalf("无效地址应返回空串，实际 %q", got)
	}
}

func TestLANBeaconBindsBroadcastToLANIP(t *testing.T) {
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: LANBeaconPort})
	if err != nil {
		t.Skipf("UDP %d 已被占用，跳过 LAN Beacon 绑定测试: %v", LANBeaconPort, err)
	}
	_ = probe.Close()

	acc, _ := identity.GenerateAccount()
	b, err := StartLANBeacon(acc, "12D3KooWSelf", "演示", []string{
		"/ip4/127.0.0.1/tcp/4001/p2p/12D3KooWSelf",
	})
	if err != nil {
		t.Fatalf("启动 LAN Beacon: %v", err)
	}
	defer func() { _ = b.Close() }()
	if got := b.BroadcastLocalAddr(); got != "127.0.0.1" {
		t.Fatalf("广播源地址 = %q，期望绑定到 127.0.0.1", got)
	}
}

func TestLANBeaconHandlePacket(t *testing.T) {
	self, _ := identity.GenerateAccount()
	peer, _ := identity.GenerateAccount()

	selfPeerID := "12D3KooWSelfDevice"
	peerPeerID := "12D3KooWPeerDevice"
	b := &LANBeacon{
		account: self,
		peerID:  selfPeerID,
		peers:   map[string]LANPeer{},
	}

	// 对端签名名片：应被验签接受。
	card, err := qrshare.Encode(peer, peerPeerID, "邻居")
	if err != nil {
		t.Fatalf("生成名片: %v", err)
	}
	addr := "/ip4/192.168.1.20/tcp/4001/p2p/" + peerPeerID
	packet := lanBeaconMagic + card + "|" + base64.RawURLEncoding.EncodeToString([]byte(addr))
	b.handlePacket([]byte(packet))

	peers := b.Snapshot()
	if len(peers) != 1 {
		t.Fatalf("期望发现 1 个对端，实际 %d", len(peers))
	}
	p := peers[0]
	if p.AccountID != peer.ID() {
		t.Fatalf("账号 ID = %s，期望 %s", p.AccountID, peer.ID())
	}
	if p.PeerID != peerPeerID || p.DisplayName != "邻居" {
		t.Fatalf("对端信息不符: %+v", p)
	}
	if !strings.Contains(p.Addr, peerPeerID) {
		t.Fatalf("地址应含对端 PeerID: %s", p.Addr)
	}
}

func TestLANBeaconRejectsForgedAndSelf(t *testing.T) {
	self, _ := identity.GenerateAccount()
	peer, _ := identity.GenerateAccount()
	selfPeerID := "12D3KooWSelfDevice"
	b := &LANBeacon{
		account: self,
		peerID:  selfPeerID,
		peers:   map[string]LANPeer{},
	}

	// 篡改签名：应被拒绝。
	card, _ := qrshare.Encode(peer, "12D3KooWPeer", "伪造")
	forged := strings.Replace(card, "a", "b", 1)
	b.handlePacket([]byte(lanBeaconMagic + forged + "|" + base64.RawURLEncoding.EncodeToString([]byte("/ip4/1.2.3.4/tcp/1/p2p/12D3KooWPeer"))))

	// 自己的名片：应被忽略。
	selfCard, _ := qrshare.Encode(self, selfPeerID, "本机")
	addr := "/ip4/1.2.3.4/tcp/1/p2p/" + selfPeerID
	b.handlePacket([]byte(lanBeaconMagic + selfCard + "|" + base64.RawURLEncoding.EncodeToString([]byte(addr))))

	if len(b.Snapshot()) != 0 {
		t.Fatalf("伪造与自己的名片都应被忽略，实际发现 %d", len(b.Snapshot()))
	}
}

func TestLANBeaconRejectsMismatchedAddr(t *testing.T) {
	self, _ := identity.GenerateAccount()
	peer, _ := identity.GenerateAccount()
	b := &LANBeacon{account: self, peerID: "self", peers: map[string]LANPeer{}}

	card, _ := qrshare.Encode(peer, "12D3KooWRight", "邻居")
	// 地址里的 PeerID 与名片不符：应被拒绝。
	badAddr := "/ip4/192.168.1.20/tcp/4001/p2p/12D3KooWWrong"
	b.handlePacket([]byte(lanBeaconMagic + card + "|" + base64.RawURLEncoding.EncodeToString([]byte(badAddr))))
	if len(b.Snapshot()) != 0 {
		t.Fatal("地址 PeerID 与名片不符时应拒绝")
	}
}

func TestLANBeaconTTL(t *testing.T) {
	self, _ := identity.GenerateAccount()
	b := &LANBeacon{account: self, peerID: "self", peers: map[string]LANPeer{}}
	b.peers["expired"] = LANPeer{AccountID: "expired", LastSeen: time.Now().Add(-lanBeaconTTL - time.Second)}
	b.peers["fresh"] = LANPeer{AccountID: "fresh", LastSeen: time.Now()}
	peers := b.Snapshot()
	if len(peers) != 1 || peers[0].AccountID != "fresh" {
		t.Fatalf("TTL 应过滤过期记录，实际 %+v", peers)
	}
}
