package discovery

import (
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/peer"
	ma "github.com/multiformats/go-multiaddr"
)

func TestMDNSSnapshotSkipsExpiredPeers(t *testing.T) {
	addr, err := ma.NewMultiaddr("/ip4/192.168.1.20/tcp/4001")
	if err != nil {
		t.Fatalf("构造 multiaddr 失败: %v", err)
	}
	n := &mdnsNotifee{addrs: map[peer.ID]cachedAddr{}}
	fresh := peer.ID("fresh-peer")
	expired := peer.ID("expired-peer")
	n.HandlePeerFound(peer.AddrInfo{ID: fresh, Addrs: []ma.Multiaddr{addr}})
	n.HandlePeerFound(peer.AddrInfo{ID: expired, Addrs: []ma.Multiaddr{addr}})

	n.mu.Lock()
	c := n.addrs[expired]
	c.seen = time.Now().Add(-addrTTL - time.Second)
	n.addrs[expired] = c
	n.mu.Unlock()

	snapshot := (&MDNS{notifee: n}).Snapshot()
	if len(snapshot) != 1 {
		t.Fatalf("期望 1 条未过期记录，实际 %d", len(snapshot))
	}
	if snapshot[0].ID != fresh {
		t.Fatalf("返回了错误节点: %s", snapshot[0].ID)
	}
	if len(snapshot[0].Addrs) != 1 {
		t.Fatalf("地址数量异常: %d", len(snapshot[0].Addrs))
	}
}
