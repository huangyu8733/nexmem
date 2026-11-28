package discovery

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/libp2p/go-libp2p/core/peer"

	"github.com/nexmem/core/internal/dm"
)

// recordingFallback 同时充当信令服务器，记录自己被调用的次数与顺序。
type recordingFallback struct {
	ids       []peer.ID
	target    dm.Target
	err       error
	idsCalls  int
	fullCalls int
	order     *[]string
}

func (f *recordingFallback) ResolvePeerIDs(_ context.Context, _ []byte) ([]peer.ID, error) {
	f.idsCalls++
	if f.order != nil {
		*f.order = append(*f.order, "signaling:ids")
	}
	return f.ids, nil
}

func (f *recordingFallback) ResolvePeer(_ context.Context, _ []byte) (dm.Target, error) {
	f.fullCalls++
	if f.order != nil {
		*f.order = append(*f.order, "signaling:full")
	}
	return f.target, f.err
}

func testResolver(fb dm.PeerResolver) *CascadingResolver {
	return &CascadingResolver{
		peerbook: NewPeerbook(nil),
		fallback: fb,
	}
}

func accountBytes() []byte {
	return []byte(strings.Repeat("a", 32))
}

func TestResolvePeerIDsBeforeSignalingFallback(t *testing.T) {
	id, err := peer.Decode(testPeerID)
	if err != nil {
		t.Fatalf("测试 PeerID 解析: %v", err)
	}
	order := make([]string, 0)
	fb := &recordingFallback{
		ids:    []peer.ID{id},
		target: dm.Target{PeerID: id, AccountPub: accountBytes()},
		err:    errors.New("目录无地址"),
		order:  &order,
	}
	r := testResolver(fb)

	got, err := r.ResolvePeer(context.Background(), accountBytes())
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if got.PeerID != id {
		t.Fatalf("对端 PeerID = %s，期望 %s", got.PeerID, id)
	}
	// DHT 未配置时直接落到信令兜底，但身份映射必须先于完整解析发生，
	// 且只取一次 PeerID，不能把中心服务器整体解析抢到 DHT 之前。
	if fb.idsCalls != 1 {
		t.Fatalf("PeerID 映射调用 %d 次，期望 1", fb.idsCalls)
	}
	if fb.fullCalls != 1 {
		t.Fatalf("信令完整解析调用 %d 次，期望 1", fb.fullCalls)
	}
	if len(order) != 2 || order[0] != "signaling:ids" || order[1] != "signaling:full" {
		t.Fatalf("调用顺序 = %v，期望身份映射先于完整解析", order)
	}
}

func TestResolvePeerIDSourceMissingFallsBackOnce(t *testing.T) {
	// 不实现 peerIDSource 的普通 resolver 也要能工作：取 PeerID 与兜底各调一次。
	fb := &plainFallback{target: dm.Target{PeerID: ""}, err: errors.New("不可达")}
	r := testResolver(fb)
	if _, err := r.ResolvePeer(context.Background(), accountBytes()); err == nil {
		t.Fatal("期望 signaling 兜底返回错误")
	}
	if fb.calls != 2 {
		t.Fatalf("ResolvePeer 调用 %d 次，期望 2（取 PeerID + 兜底）", fb.calls)
	}
}

type plainFallback struct {
	target dm.Target
	err    error
	calls  int
}

func (f *plainFallback) ResolvePeer(_ context.Context, _ []byte) (dm.Target, error) {
	f.calls++
	return f.target, f.err
}
