package contacts

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/store"
)

func newTestService(t *testing.T) *Service {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "nexmem.db"))
	if err != nil {
		t.Fatalf("打开数据库: %v", err)
	}
	if err := store.Migrate(context.Background(), db); err != nil {
		db.Close()
		t.Fatalf("迁移: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	svc, err := New(store.NewDAO(db))
	if err != nil {
		t.Fatalf("创建联系人服务: %v", err)
	}
	return svc
}

func testPeer(fill byte) []byte {
	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = fill
	}
	return pub
}

func TestAddAndRemark(t *testing.T) {
	ctx := context.Background()
	svc := newTestService(t)
	peer := testPeer(0x31)

	c, err := svc.Add(ctx, peer)
	if err != nil {
		t.Fatalf("添加好友: %v", err)
	}
	if c.Alias != "" || c.Blocked {
		t.Fatalf("新好友应无备注且未拉黑: %+v", c)
	}

	if err := svc.Remark(ctx, peer, " 老王 "); err != nil {
		t.Fatalf("设置备注: %v", err)
	}
	c, err = svc.Get(ctx, peer)
	if err != nil {
		t.Fatalf("读取好友: %v", err)
	}
	if c.Alias != "老王" {
		t.Fatalf("备注应去除首尾空白，实际 %q", c.Alias)
	}

	// 再次 Add 不得清除已有备注。
	if _, err := svc.Add(ctx, peer); err != nil {
		t.Fatalf("重复添加: %v", err)
	}
	c, _ = svc.Get(ctx, peer)
	if c.Alias != "老王" {
		t.Fatalf("重复添加不应清除备注，实际 %q", c.Alias)
	}

	if err := svc.Remark(ctx, peer, ""); err != nil {
		t.Fatalf("清除备注: %v", err)
	}
	c, _ = svc.Get(ctx, peer)
	if c.Alias != "" {
		t.Fatalf("备注应被清除，实际 %q", c.Alias)
	}
}

func TestBlockAndUnblock(t *testing.T) {
	ctx := context.Background()
	svc := newTestService(t)
	peer := testPeer(0x32)

	if err := svc.SetBlocked(ctx, peer, true); err != nil {
		t.Fatalf("拉黑: %v", err)
	}
	blocked, err := svc.IsBlocked(ctx, peer)
	if err != nil {
		t.Fatalf("查询黑名单: %v", err)
	}
	if !blocked {
		t.Fatalf("拉黑后 IsBlocked 应为 true")
	}

	if err := svc.SetBlocked(ctx, peer, false); err != nil {
		t.Fatalf("取消拉黑: %v", err)
	}
	if blocked, _ := svc.IsBlocked(ctx, peer); blocked {
		t.Fatalf("取消拉黑后 IsBlocked 应为 false")
	}

	if _, err := svc.IsBlocked(ctx, []byte("bad")); !errors.Is(err, ErrInvalidPeer) {
		t.Fatalf("非法公钥应返回 ErrInvalidPeer，实际 %v", err)
	}
	if _, err := svc.Add(ctx, nil); !errors.Is(err, ErrEmptyPeer) {
		t.Fatalf("空公钥应返回 ErrEmptyPeer，实际 %v", err)
	}
}

func TestGatewayContactMethods(t *testing.T) {
	ctx := context.Background()
	svc := newTestService(t)
	g := gateway.New()
	if err := Bind(g, svc); err != nil {
		t.Fatalf("接入网关: %v", err)
	}

	peer := testPeer(0x33)
	peerHex := hex.EncodeToString(peer)

	call := func(method, params string) (any, *gateway.Error) {
		return g.Handle(ctx, method, json.RawMessage(params))
	}

	if _, e := call("contact.add", `{"peer":"`+peerHex+`"}`); e != nil {
		t.Fatalf("contact.add: %v", e)
	}
	if _, e := call("contact.remark", `{"peer":"`+peerHex+`","remark":"同事"}`); e != nil {
		t.Fatalf("contact.remark: %v", e)
	}
	if _, e := call("contact.block", `{"peer":"`+peerHex+`","blocked":true}`); e != nil {
		t.Fatalf("contact.block: %v", e)
	}

	data, e := call("contact.list", `{"limit":10}`)
	if e != nil {
		t.Fatalf("contact.list: %v", e)
	}
	body, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("序列化结果: %v", err)
	}
	var list struct {
		Items []struct {
			AccountPub string `json:"account_pub"`
			Alias      string `json:"alias"`
			Blocked    bool   `json:"blocked"`
		} `json:"items"`
	}
	if err := json.Unmarshal(body, &list); err != nil {
		t.Fatalf("解析结果: %v", err)
	}
	if len(list.Items) != 1 || list.Items[0].AccountPub != peerHex ||
		list.Items[0].Alias != "同事" || !list.Items[0].Blocked {
		t.Fatalf("contact.list 结果错误: %s", body)
	}

	if _, e := call("contact.add", `{"peer":"not-a-key"}`); e == nil || e.Code != gateway.CodeInvalidArg {
		t.Fatalf("非法 peer 应返回 INVALID_ARG，实际 %v", e)
	}
	if _, e := call("contact.block", `{"peer":"`+peerHex+`"}`); e == nil || e.Code != gateway.CodeInvalidArg {
		t.Fatalf("缺少 blocked 应返回 INVALID_ARG，实际 %v", e)
	}

	// base64url 编码同样被接受。
	alt := base64.RawURLEncoding.EncodeToString(testPeer(0x34))
	if _, e := call("contact.add", `{"peer":"`+alt+`"}`); e != nil {
		t.Fatalf("base64url peer 应被接受: %v", e)
	}
}
