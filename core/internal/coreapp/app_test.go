package coreapp

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/dm"
	"github.com/nexmem/core/internal/group"
	"github.com/nexmem/core/internal/identity"
)

type eventLog struct {
	mu     sync.Mutex
	events []event
}

type event struct {
	name string
	data any
}

func (l *eventLog) Emit(name string, data any) {
	l.mu.Lock()
	l.events = append(l.events, event{name: name, data: data})
	l.mu.Unlock()
}

func (l *eventLog) has(name string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, e := range l.events {
		if e.name == name {
			return true
		}
	}
	return false
}

func (l *eventLog) count(name string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for _, e := range l.events {
		if e.name == name {
			n++
		}
	}
	return n
}

// hasState 判断某事件是否带指定 state 字段（用于 message.updated）。
func (l *eventLog) hasState(name, state string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, e := range l.events {
		if e.name != name {
			continue
		}
		if m, ok := e.data.(map[string]any); ok && m["state"] == state {
			return true
		}
	}
	return false
}

func startApp(t *testing.T, dir string, resolver dm.PeerResolver) (*gateway.Gateway, *App, *eventLog) {
	t.Helper()
	gw := gateway.New()
	log := &eventLog{}
	app, err := New(gw, log)
	if err != nil {
		t.Fatalf("创建装配体: %v", err)
	}
	if resolver != nil {
		app.SetPeerResolver(resolver)
	}
	state, err := app.Start(context.Background(), Config{
		DataDir: dir,
		Listen:  []string{"/ip4/127.0.0.1/tcp/0"},
	})
	if err != nil {
		t.Fatalf("启动内核: %v", err)
	}
	if state == "" {
		t.Fatal("启动后状态为空")
	}
	t.Cleanup(func() { _ = app.Stop() })
	return gw, app, log
}

func call(t *testing.T, gw *gateway.Gateway, method string, params any) any {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("序列化 %s 参数: %v", method, err)
	}
	data, gerr := gw.Handle(context.Background(), method, raw)
	if gerr != nil {
		t.Fatalf("%s 失败: %s", method, gerr.Error())
	}
	return data
}

func callErr(t *testing.T, gw *gateway.Gateway, method string, params any) *gateway.Error {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("序列化 %s 参数: %v", method, err)
	}
	_, gerr := gw.Handle(context.Background(), method, raw)
	if gerr == nil {
		t.Fatalf("%s 期望失败但成功了", method)
	}
	return gerr
}

// TestStartStopIdempotent 覆盖 P1-20 的启动/停止幂等、账号持久化与基础方法装配。
func TestStartStopIdempotent(t *testing.T) {
	dir := t.TempDir()
	gw, app, log := startApp(t, dir, nil)

	acc := app.Account()
	if acc == nil {
		t.Fatal("启动后账号为空")
	}
	firstPeer := app.PeerID()

	// core.start 重复调用不切换账号与设备。
	data, ok := call(t, gw, "core.start", map[string]any{
		"config": map[string]any{"data_dir": dir, "listen": []string{"/ip4/127.0.0.1/tcp/0"}},
	}).(map[string]any)
	if !ok {
		t.Fatal("core.start 返回值不是对象")
	}
	if data["state"] == "" {
		t.Fatal("core.start 未返回状态")
	}
	if app.Account().ID() != acc.ID() || app.PeerID() != firstPeer {
		t.Fatal("重复启动改变了账号或设备身份")
	}

	me, ok := call(t, gw, "account.me", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("account.me 返回值不是对象")
	}
	if me["account_id"] != acc.ID() || me["device_id"] != firstPeer {
		t.Fatalf("account.me 身份不一致: %v", me)
	}

	// 联系人装配。
	stranger, err := identity.GenerateAccount()
	if err != nil {
		t.Fatalf("生成联系人账号: %v", err)
	}
	call(t, gw, "contact.add", map[string]any{
		"peer":  hex.EncodeToString(stranger.Pub()),
		"alias": "测试联系人",
	})
	contacts, ok := call(t, gw, "contact.list", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("contact.list 返回值不是对象")
	}
	if n := len(listItems(t, contacts)); n != 1 {
		t.Fatalf("联系人数量 = %d, 期望 1", n)
	}

	// 消息检索与诊断快照。
	if _, ok := call(t, gw, "msg.search", map[string]any{"q": "hello", "limit": 20}).(map[string]any); !ok {
		t.Fatal("msg.search 返回值不是对象")
	}
	if _, ok := call(t, gw, "diag.snapshot", map[string]any{}).(map[string]any); !ok {
		t.Fatal("diag.snapshot 返回值不是对象")
	}

	// 备份导出。
	exportPath := filepath.Join(t.TempDir(), "backup.nxbak")
	call(t, gw, "backup.export", map[string]any{
		"path":           exportPath,
		"passphrase_b64": base64.StdEncoding.EncodeToString([]byte("test-passphrase")),
	})
	if _, err := os.Stat(exportPath); err != nil {
		t.Fatalf("备份文件未生成: %v", err)
	}

	// 停止后方法回到 NOT_STARTED，重复停止幂等。
	call(t, gw, "core.stop", map[string]any{})
	call(t, gw, "core.stop", map[string]any{})
	if gerr := callErr(t, gw, "account.me", map[string]any{}); gerr.Code != gateway.CodeNotStarted {
		t.Fatalf("停止后 account.me 错误码 = %s, 期望 NOT_STARTED", gerr.Code)
	}
	if !log.has("state.changed") {
		t.Fatal("未收到 state.changed 事件")
	}

	// 重新启动应复用同一账号、设备与本地库。
	if _, err := app.Start(context.Background(), Config{DataDir: dir, Listen: []string{"/ip4/127.0.0.1/tcp/0"}}); err != nil {
		t.Fatalf("重新启动: %v", err)
	}
	if app.Account().ID() != acc.ID() {
		t.Fatal("重新启动后账号变化")
	}
	if app.PeerID() != firstPeer {
		t.Fatal("重新启动后设备 PeerID 变化")
	}
	contacts, ok = call(t, gw, "contact.list", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("重启后 contact.list 失败")
	}
	if n := len(listItems(t, contacts)); n != 1 {
		t.Fatalf("重启后联系人数量 = %d, 期望 1", n)
	}
}

// TestSendTextBetweenApps 覆盖两节点直连发送、入站事件与本地入库。
func TestSendTextBetweenApps(t *testing.T) {
	var (
		mu sync.Mutex
		a  *App
		b  *App
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if len(a.Account().Pub()) == len(accountPub) && string(a.Account().Pub()) == string(accountPub) {
			return targetOf(a), nil
		}
		if string(b.Account().Pub()) == string(accountPub) {
			return targetOf(b), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	gwA, appA, logA := startApp(t, filepath.Join(t.TempDir(), "a"), resolver)
	gwB, appB, logB := startApp(t, filepath.Join(t.TempDir(), "b"), resolver)
	mu.Lock()
	a, b = appA, appB
	mu.Unlock()

	data, ok := call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "hello from a",
	}).(map[string]any)
	if !ok || data["msg_uuid"] == "" {
		t.Fatalf("dm.sendText 未返回 msg_uuid: %v", data)
	}

	waitFor(t, propagationWait, func() bool { return logB.has("message.new") })
	waitFor(t, propagationWait, func() bool { return logA.has("message.updated") })

	search, ok := call(t, gwB, "msg.search", map[string]any{"q": "hello", "limit": 20}).(map[string]any)
	if !ok {
		t.Fatal("接收端 msg.search 返回值不是对象")
	}
	if n := len(listItems(t, search)); n != 1 {
		t.Fatalf("接收端检索到 %d 条消息, 期望 1", n)
	}

	// msg.list 应按会话倒序返回本地历史：接收端为 in，发送端为 out。
	conv := dm.ConversationID(appA.Account().Pub(), appB.Account().Pub())
	histB, ok := call(t, gwB, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 10,
	}).(map[string]any)
	if !ok {
		t.Fatal("接收端 msg.list 返回值不是对象")
	}
	itemsB := listItems(t, histB)
	if len(itemsB) != 1 {
		t.Fatalf("接收端历史 %d 条, 期望 1", len(itemsB))
	}
	firstB, _ := itemsB[0].(map[string]any)
	if firstB["text"] != "hello from a" || firstB["direction"] != "in" {
		t.Fatalf("接收端历史字段错误: %v", firstB)
	}
	if histB["has_more"] != false {
		t.Fatalf("接收端历史不应有更多: %v", histB["has_more"])
	}

	histA, ok := call(t, gwA, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 10,
	}).(map[string]any)
	if !ok {
		t.Fatal("发送端 msg.list 返回值不是对象")
	}
	itemsA := listItems(t, histA)
	if len(itemsA) != 1 {
		t.Fatalf("发送端历史 %d 条, 期望 1", len(itemsA))
	}
	firstA, _ := itemsA[0].(map[string]any)
	if firstA["direction"] != "out" || firstA["text"] != "hello from a" {
		t.Fatalf("发送端历史字段错误: %v", firstA)
	}
	if state, _ := firstA["state"].(string); state == "" || state == "unknown" {
		t.Fatalf("发送端历史状态缺失: %v", firstA)
	}
}

// TestReadReceiptMarksRead 覆盖 P6-07 已读回执闭环：接收方打开会话推进已读后，
// 发送方的出站消息被置为 read，并收到 message.updated(state=read)。
func TestReadReceiptMarksRead(t *testing.T) {
	var (
		mu sync.Mutex
		a  *App
		b  *App
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if a != nil && string(a.Account().Pub()) == string(accountPub) {
			return targetOf(a), nil
		}
		if b != nil && string(b.Account().Pub()) == string(accountPub) {
			return targetOf(b), nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	gwA, appA, logA := startApp(t, filepath.Join(t.TempDir(), "a"), resolver)
	gwB, appB, _ := startApp(t, filepath.Join(t.TempDir(), "b"), resolver)
	mu.Lock()
	a, b = appA, appB
	mu.Unlock()

	conv := dm.ConversationID(appA.Account().Pub(), appB.Account().Pub())
	data, ok := call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "read receipt",
	}).(map[string]any)
	if !ok || data["msg_uuid"] == "" {
		t.Fatalf("dm.sendText 未返回 msg_uuid: %v", data)
	}
	msgID := data["msg_uuid"].(string)
	waitFor(t, propagationWait, func() bool { return logA.hasState("message.updated", "sent") })

	// B 打开会话：内核清零未读并把最后一条入站消息的时间戳作为已读水位回传。
	call(t, gwB, "msg.markRead", map[string]any{
		"conversation_id": conv,
		"up_to_id":        msgID,
	})

	waitFor(t, 10*time.Second, func() bool { return logA.hasState("message.updated", "read") })

	histA, ok := call(t, gwA, "msg.list", map[string]any{
		"conversation_id": conv, "limit": 10,
	}).(map[string]any)
	if !ok {
		t.Fatal("发送端 msg.list 返回值不是对象")
	}
	itemsA := listItems(t, histA)
	if len(itemsA) != 1 {
		t.Fatalf("发送端历史 %d 条, 期望 1", len(itemsA))
	}
	firstA, _ := itemsA[0].(map[string]any)
	if state, _ := firstA["state"].(string); state != "read" {
		t.Fatalf("发送端消息状态 = %v, 期望 read", firstA["state"])
	}

	// 接收方未读应清零。
	convs, ok := call(t, gwB, "conversation.list", map[string]any{}).(map[string]any)
	if !ok {
		t.Fatal("conversation.list 返回值不是对象")
	}
	for _, raw := range listItems(t, convs) {
		item, _ := raw.(map[string]any)
		if item["conversation_id"] != conv {
			continue
		}
		if unread, _ := item["unread"].(float64); unread != 0 {
			t.Fatalf("接收方未读 = %v, 期望 0", item["unread"])
		}
		return
	}
	t.Fatal("conversation.list 未返回目标会话")
}

// TestGroupCreateOverGateway 覆盖 P1-20 群聊装配：建群分发密钥、成员查询、
// 群消息广播到成员并产生 message.new。
func TestGroupCreateOverGateway(t *testing.T) {
	var (
		mu sync.Mutex
		a  *App
		b  *App
	)
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		mu.Lock()
		defer mu.Unlock()
		if a != nil {
			if acc := a.Account(); acc != nil && string(acc.Pub()) == string(accountPub) {
				return targetOf(a), nil
			}
		}
		if b != nil {
			if acc := b.Account(); acc != nil && string(acc.Pub()) == string(accountPub) {
				return targetOf(b), nil
			}
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})
	gwA, appA, _ := startApp(t, filepath.Join(t.TempDir(), "a"), resolver)
	gwB, appB, _ := startApp(t, filepath.Join(t.TempDir(), "b"), resolver)
	mu.Lock()
	a, b = appA, appB
	mu.Unlock()

	// 测试环境没有索引服务，群成员目标解析器按账号直接给出设备地址。
	targetResolver := group.TargetResolverFunc(func(_ context.Context, accountPub []byte) (group.KeyTarget, error) {
		mu.Lock()
		defer mu.Unlock()
		for _, app := range []*App{a, b} {
			if app == nil {
				continue
			}
			acc := app.Account()
			if acc == nil || string(acc.Pub()) != string(accountPub) {
				continue
			}
			return group.KeyTarget{
				PeerID: app.hostOrNilID(), Addrs: app.hostOrNilAddrs(),
				AccountPub: accountPub, XPub: acc.XPub(),
			}, nil
		}
		return group.KeyTarget{}, dm.ErrInvalidTarget
	})
	appA.SetGroupTargetResolver(targetResolver)
	appB.SetGroupTargetResolver(targetResolver)

	// 先建立一条单聊连接，群广播即可沿现有连接到达。
	call(t, gwA, "dm.sendText", map[string]any{
		"peer": hex.EncodeToString(appB.Account().Pub()),
		"text": "connect first",
	})

	created, ok := call(t, gwA, "group.create", map[string]any{
		"title":   "研发群",
		"members": []string{hex.EncodeToString(appB.Account().Pub())},
	}).(map[string]any)
	if !ok {
		t.Fatal("group.create 返回值不是对象")
	}
	groupID, _ := created["group_id"].(string)
	if groupID == "" {
		t.Fatal("group.create 未返回 group_id")
	}
	if failed := created["failed"].(int); failed != 0 {
		t.Fatalf("密钥投递失败数 %d，期望 0", failed)
	}

	view, ok := call(t, gwA, "group.members", map[string]any{"group_id": groupID}).(map[string]any)
	if !ok {
		t.Fatal("group.members 返回值不是对象")
	}
	if view["title"] != "研发群" {
		t.Fatalf("群名称 %v，期望 研发群", view["title"])
	}
	if n := len(view["members"].([]map[string]any)); n != 2 {
		t.Fatalf("成员数 %d，期望 2", n)
	}
	if view["storage_configured"].(bool) {
		t.Fatal("新建群不应预置群盘配置")
	}

	// 建群后必须等接收端受理密钥信封并订阅群主题，再发首条群消息。
	// 密钥投递与主题广播走不同链路，背靠背调用会让消息在订阅生效前发出而被丢弃；
	// 真实 UI 中用户建群后再输入消息天然有这段间隔，测试要显式同步这一步。
	keyParams, _ := json.Marshal(map[string]any{"group_id": groupID})
	waitFor(t, 10*time.Second, func() bool {
		_, gerr := gwB.Handle(context.Background(), "group.members", keyParams)
		return gerr == nil
	})

	// GossipSub mesh 刚订阅时尚未连通，首次广播可能丢失。沿用仓库 R-15
	// 测试惯例（见 internal/group/pending_test.go）：重复发送直到接收端
	// 落库，再按「存在目标消息」断言，而不是依赖恰好只有一条。
	convID := "group:" + groupID
	var inItems []map[string]any
	arrived := false
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) && !arrived {
		sent, ok := call(t, gwA, "dm.sendGroupText", map[string]any{
			"group_id": groupID,
			"text":     "群里好",
		}).(map[string]any)
		if !ok || sent["msg_uuid"] == "" {
			t.Fatalf("dm.sendGroupText 未返回 msg_uuid: %v", sent)
		}
		if sent["stored"].(bool) {
			t.Fatal("未配置群盘时 stored 应为 false")
		}
		pollUntil := time.Now().Add(time.Second)
		for time.Now().Before(pollUntil) {
			resp, ok := call(t, gwB, "msg.list", map[string]any{
				"conversation_id": convID,
				"limit":           10,
			}).(map[string]any)
			if ok {
				inItems, _ = resp["items"].([]map[string]any)
				arrived = findGroupMessage(inItems, "群里好", "in") != nil
			}
			if arrived {
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
		if !arrived {
			time.Sleep(200 * time.Millisecond)
		}
	}
	if !arrived {
		t.Fatalf("接收端未落库群消息: %v", inItems)
	}

	// 接收端按密钥信封落库后应能读出同一群资料。
	viewB, ok := call(t, gwB, "group.members", map[string]any{"group_id": groupID}).(map[string]any)
	if !ok || viewB["title"] != "研发群" {
		t.Fatalf("接收端群资料不一致: %v", viewB)
	}

	// 群消息应双端落入本地库，供 msg.list / conversation.list 读取。
	outgoing, ok := call(t, gwA, "msg.list", map[string]any{
		"conversation_id": convID,
		"limit":           10,
	}).(map[string]any)
	if !ok {
		t.Fatal("发送端 msg.list 返回值不是对象")
	}
	outItems, _ := outgoing["items"].([]map[string]any)
	if findGroupMessage(outItems, "群里好", "out") == nil {
		t.Fatalf("发送端群消息未落库: %v", outItems)
	}

	if findGroupMessage(inItems, "群里好", "in") == nil {
		t.Fatalf("接收端群消息未落库: %v", inItems)
	}

	convs, ok := call(t, gwB, "conversation.list", map[string]any{"limit": 10}).(map[string]any)
	if !ok {
		t.Fatal("接收端 conversation.list 返回值不是对象")
	}
	var groupConv map[string]any
	for _, c := range convs["items"].([]map[string]any) {
		if c["conversation_id"] == convID {
			groupConv = c
			break
		}
	}
	if groupConv == nil {
		t.Fatalf("群会话未出现在会话列表: %v", convs["items"])
	}
	if groupConv["kind"] != "group" || groupConv["group_id"] != groupID || groupConv["title"] != "研发群" {
		t.Fatalf("群会话条目字段不正确: %v", groupConv)
	}
	unread := asInt(groupConv["unread"])
	if unread < 1 || groupConv["last_text"] != "群里好" {
		t.Fatalf("群会话未读或摘要不正确: %v", groupConv)
	}
}

// hostOrNilID / hostOrNilAddrs 在锁外读取本机设备地址，供测试解析器使用。
func (a *App) hostOrNilID() peer.ID {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.host == nil {
		return ""
	}
	return a.host.ID()
}

func (a *App) hostOrNilAddrs() []multiaddr.Multiaddr {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.host == nil {
		return nil
	}
	return a.host.Addrs()
}

// listItems 把 {items:[...]} 形式的响应还原成切片，避免依赖具体元素类型。
func listItems(t *testing.T, data map[string]any) []any {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("序列化响应: %v", err)
	}
	var wrap struct {
		Items []any `json:"items"`
	}
	if err := json.Unmarshal(raw, &wrap); err != nil {
		t.Fatalf("解析响应: %v", err)
	}
	return wrap.Items
}

// findGroupMessage 在 msg.list 结果中查找指定文本与方向的群消息。
// 测试会为重发做幂等处理，接收端可能落库多条，断言按存在性而非条数判断。
func findGroupMessage(items []map[string]any, text, direction string) map[string]any {
	for _, item := range items {
		if item["text"] == text && item["direction"] == direction {
			return item
		}
	}
	return nil
}

func targetOf(app *App) dm.Target {
	app.mu.RLock()
	defer app.mu.RUnlock()
	h := app.host
	if h == nil {
		return dm.Target{}
	}
	return dm.Target{PeerID: h.ID(), Addrs: h.Addrs()}
}

// CI runner 上 P2P 建链与控制帧传播偶发慢于本机，测试等待窗口统一放宽，
// 避免 5 秒硬上限把正常的慢传播误判成失败。
const (
	propagationWait = 15 * time.Second
	eventWait       = 5 * time.Second
)

func waitFor(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("等待条件超时")
}

// waitGroupTopicReady 等待成员已订阅群主题、且管理员侧主题出现邻居。
// 群记录与密钥落库先于 GossipSub 订阅完成，而 PubSub 不回放历史消息；
// 在邻居形成前发布群设置控制帧会被静默丢弃，成员侧永远看不到变更。
func waitGroupTopicReady(t *testing.T, admin, member *App, groupID string) {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(groupID)
	if err != nil {
		t.Fatalf("群 ID 解码失败: %v", err)
	}
	waitFor(t, propagationWait, func() bool {
		return member.groupService() != nil &&
			member.groupService().Subscribed(raw) &&
			admin.groupService() != nil &&
			admin.groupService().Peers(raw) > 0
	})
}

// TestDiscoveryDefaultsEnabled 校验发现源默认开启，且用户显式 false 仍可关闭。
func TestDiscoveryDefaultsEnabled(t *testing.T) {
	tests := []struct {
		raw      string
		fallback bool
		want     bool
	}{
		{raw: "", fallback: true, want: true},
		{raw: "true", fallback: true, want: true},
		{raw: "false", fallback: true, want: false},
		{raw: "invalid", fallback: true, want: true},
	}
	for _, tt := range tests {
		if got := boolSetting(tt.raw, tt.fallback); got != tt.want {
			t.Fatalf("boolSetting(%q, %v) = %v, want %v", tt.raw, tt.fallback, got, tt.want)
		}
	}
}
