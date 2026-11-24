package discovery

import (
	"context"
	"encoding/hex"
	"strings"
	"testing"

	ma "github.com/multiformats/go-multiaddr"
)

const testPeerID = "12D3KooWGTcvnEFREG2x1KGtzMM6ENgppMwTcamCrYGCWPZXi82i"
const testAddr = "/ip4/192.168.1.10/tcp/4001/p2p/12D3KooWGTcvnEFREG2x1KGtzMM6ENgppMwTcamCrYGCWPZXi82i"

func testAccountID() string {
	return strings.Repeat("ab", 32)
}

func TestPeerbookPutDiscover(t *testing.T) {
	ctx := context.Background()
	book := NewPeerbook(nil) // 内存模式
	aid := testAccountID()

	if err := book.Put(ctx, aid, testPeerID, []string{testAddr}, "手机"); err != nil {
		t.Fatalf("Put 失败: %v", err)
	}

	pub, _ := hex.DecodeString(aid)
	infos, ok := book.Discover(ctx, pub)
	if !ok || len(infos) != 1 {
		t.Fatalf("Discover 未命中: ok=%v infos=%v", ok, infos)
	}
	if infos[0].ID.String() != testPeerID {
		t.Fatalf("PeerID 不符: %s", infos[0].ID.String())
	}
	if len(infos[0].Addrs) != 1 {
		t.Fatalf("地址数量不符: %d", len(infos[0].Addrs))
	}
}

func TestPeerbookRemove(t *testing.T) {
	ctx := context.Background()
	book := NewPeerbook(nil)
	aid := testAccountID()
	_ = book.Put(ctx, aid, testPeerID, []string{testAddr}, "")

	if err := book.Remove(ctx, aid); err != nil {
		t.Fatalf("Remove 失败: %v", err)
	}
	pub, _ := hex.DecodeString(aid)
	if _, ok := book.Discover(ctx, pub); ok {
		t.Fatal("Remove 后仍能发现")
	}
}

func TestPeerbookValidation(t *testing.T) {
	ctx := context.Background()
	book := NewPeerbook(nil)
	if err := book.Put(ctx, "short", testPeerID, []string{testAddr}, ""); err == nil {
		t.Fatal("非法账号 ID 应被拒绝")
	}
	if err := book.Put(ctx, testAccountID(), testPeerID, []string{"not-a-multiaddr"}, ""); err == nil {
		t.Fatal("非法 multiaddr 应被拒绝")
	}
}

func TestAppendUnique(t *testing.T) {
	ma1, err := ma.NewMultiaddr(testAddr)
	if err != nil {
		t.Fatalf("解析地址失败: %v", err)
	}
	got := appendUnique([]ma.Multiaddr{ma1}, []ma.Multiaddr{ma1})
	if len(got) != 1 {
		t.Fatalf("去重失败: %d", len(got))
	}
	got = appendUnique(got, []ma.Multiaddr{ma1})
	if len(got) != 1 {
		t.Fatalf("再次去重失败: %d", len(got))
	}
}

func TestParsePublicBootstraps(t *testing.T) {
	list := ParsePublicBootstraps([]string{"", "  " + testAddr + "  ", "invalid"})
	if len(list) != 1 {
		t.Fatalf("解析公共 bootstrap 数量不符: %d", len(list))
	}
	if list[0].ID.String() != testPeerID {
		t.Fatalf("PeerID 不符: %s", list[0].ID.String())
	}
}
