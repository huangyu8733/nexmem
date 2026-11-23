package coreapp

// P2 阶段门禁的本地可复现项：链路中断 30 秒后双方消息集合完全一致（0 丢失 / 0 重复）。
//
// 中断通过在两节点之间插入可控 TCP 代理实现：代理放行时等价于正常链路，
// 切断时关闭监听与全部已建立连接，新建拨号立即失败，等价于「拔网线」。
// 恢复时换用新的代理端口，避免 libp2p 对故障地址的拨号退避拖慢重连，
// 与真实设备换网后拿到新地址的情形一致。

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/p2p/protocol/identify"
	"github.com/multiformats/go-multiaddr"

	"github.com/nexmem/core/gateway"
	"github.com/nexmem/core/internal/dm"
)

// gateLink 是解析器启动后注入的链路地址快照。
type gateLink struct {
	accA, accB   []byte
	hostA, hostB host.Host
	proxy        *cutProxy
}

// cutProxy 是两节点之间的可控 TCP 代理。
type cutProxy struct {
	target string

	mu   sync.Mutex
	ln   net.Listener
	addr multiaddr.Multiaddr
	conn map[net.Conn]struct{}

	// gate 非空表示链路被挂起：连接保持建立但不再转发数据，
	// 等价于接收端被系统挂起（锁屏）后无法处理网络报文。
	gate atomic.Pointer[chan struct{}]
}

func newCutProxy(t *testing.T, target string) *cutProxy {
	t.Helper()
	p := &cutProxy{target: target, conn: make(map[net.Conn]struct{})}
	if err := p.listen(); err != nil {
		t.Fatalf("启动链路代理: %v", err)
	}
	t.Cleanup(p.close)
	return p
}

func (p *cutProxy) listen() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	maddr, err := multiaddr.NewMultiaddr(fmt.Sprintf("/ip4/127.0.0.1/tcp/%d", port))
	if err != nil {
		_ = ln.Close()
		return err
	}
	p.mu.Lock()
	p.ln = ln
	p.addr = maddr
	p.mu.Unlock()
	go p.serve(ln)
	return nil
}

func (p *cutProxy) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		p.track(c)
		go p.pipe(c)
	}
}

func (p *cutProxy) pipe(client net.Conn) {
	upstream, err := net.Dial("tcp", p.target)
	if err != nil {
		p.drop(client)
		return
	}
	p.track(upstream)
	go func() {
		p.copyGated(upstream, client)
		p.drop(upstream)
	}()
	p.copyGated(client, upstream)
	p.drop(client)
}

// copyGated 等价于 io.Copy，但在挂起期间把已读到的数据滞留在代理内，
// 不写入对端，直到恢复后再继续转发。
func (p *cutProxy) copyGated(dst, src net.Conn) {
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			p.waitGate()
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// pause 挂起链路：连接保持建立但停止转发，模拟接收端被系统挂起。
func (p *cutProxy) pause() {
	ch := make(chan struct{})
	p.gate.Store(&ch)
}

// resume 恢复链路并放行挂起期间滞留的数据。
func (p *cutProxy) resume() {
	if ch := p.gate.Swap(nil); ch != nil {
		close(*ch)
	}
}

// waitGate 在挂起期间阻塞，恢复后立即返回。
func (p *cutProxy) waitGate() {
	if ch := p.gate.Load(); ch != nil {
		<-*ch
	}
}

func (p *cutProxy) track(c net.Conn) {
	p.mu.Lock()
	p.conn[c] = struct{}{}
	p.mu.Unlock()
}

func (p *cutProxy) drop(c net.Conn) {
	p.mu.Lock()
	delete(p.conn, c)
	p.mu.Unlock()
	_ = c.Close()
}

// Multiaddr 返回当前代理地址。
func (p *cutProxy) Multiaddr() multiaddr.Multiaddr {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.addr
}

// cut 关闭监听与全部连接，后续拨号立即失败。
func (p *cutProxy) cut() {
	p.mu.Lock()
	ln := p.ln
	p.ln = nil
	conns := make([]net.Conn, 0, len(p.conn))
	for c := range p.conn {
		conns = append(conns, c)
	}
	p.conn = make(map[net.Conn]struct{})
	p.mu.Unlock()

	if ln != nil {
		_ = ln.Close()
	}
	for _, c := range conns {
		_ = c.Close()
	}
	// 关闭连接后放行挂起中的转发协程，使它们因写入失败而退出。
	p.resume()
}

// restore 在新端口上重新监听，使对端拿到未被退避的新地址。
func (p *cutProxy) restore() error {
	p.cut()
	return p.listen()
}

func (p *cutProxy) close() { p.cut() }

// hostOf 读取装配体内部的 libp2p 主机。
func hostOf(t *testing.T, app *App) host.Host {
	t.Helper()
	app.mu.RLock()
	defer app.mu.RUnlock()
	if app.host == nil {
		t.Fatal("内核主机未就绪")
	}
	return app.host
}

// tcpListenAddr 取主机的 TCP 监听地址（测试只用 tcp 监听）。
func tcpListenAddr(t *testing.T, h host.Host) string {
	t.Helper()
	for _, a := range h.Addrs() {
		if port, err := a.ValueForProtocol(multiaddr.P_TCP); err == nil {
			return net.JoinHostPort("127.0.0.1", port)
		}
	}
	t.Fatal("未找到 TCP 监听地址")
	return ""
}

// gateHistory 读取会话历史，失败时返回 false（供轮询使用，不中断用例）。
func gateHistory(gw *gateway.Gateway, conv string) ([]map[string]any, bool) {
	raw, err := json.Marshal(map[string]any{"conversation_id": conv, "limit": 200})
	if err != nil {
		return nil, false
	}
	data, gerr := gw.Handle(context.Background(), "msg.list", raw)
	if gerr != nil {
		return nil, false
	}
	encoded, err := json.Marshal(data)
	if err != nil {
		return nil, false
	}
	var wrap struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(encoded, &wrap); err != nil {
		return nil, false
	}
	return wrap.Items, true
}

// gatePair 是一对经可控代理互联的内核实例，供 P2 门禁场景复用。
type gatePair struct {
	gwA, gwB   *gateway.Gateway
	appA, appB *App
	hostA      host.Host
	hostB      host.Host
	proxy      *cutProxy
	conv       string
}

// newGatePair 启动两节点并让 A 只能经代理访问 B。
func newGatePair(t *testing.T) *gatePair {
	t.Helper()

	// 解析器在 dm 服务构造时被捕获，因此先用原子指针占位，启动后再注入真实地址。
	var link atomic.Pointer[gateLink]
	resolver := dm.PeerResolverFunc(func(_ context.Context, accountPub []byte) (dm.Target, error) {
		st := link.Load()
		if st == nil {
			return dm.Target{}, dm.ErrInvalidTarget
		}
		switch {
		case bytes.Equal(st.accA, accountPub):
			return dm.Target{PeerID: st.hostA.ID(), Addrs: st.hostA.Addrs()}, nil
		case bytes.Equal(st.accB, accountPub):
			// 对端地址经代理暴露，代理切断或挂起即链路不可用。
			return dm.Target{PeerID: st.hostB.ID(), Addrs: []multiaddr.Multiaddr{st.proxy.Multiaddr()}}, nil
		}
		return dm.Target{}, dm.ErrInvalidTarget
	})

	gwA, appA, _ := startApp(t, filepath.Join(t.TempDir(), "a"), resolver)
	gwB, appB, _ := startApp(t, filepath.Join(t.TempDir(), "b"), resolver)

	hostA := hostOf(t, appA)
	hostB := hostOf(t, appB)
	// 关掉 B 的 identify：否则 A 会从握手回执里学到 B 的真实监听地址，
	// 绕过代理直连，链路中断就失效了。
	hostB.RemoveStreamHandler(identify.ID)
	proxy := newCutProxy(t, tcpListenAddr(t, hostB))
	link.Store(&gateLink{
		accA:  appA.Account().Pub(),
		accB:  appB.Account().Pub(),
		hostA: hostA,
		hostB: hostB,
		proxy: proxy,
	})

	return &gatePair{
		gwA:   gwA,
		gwB:   gwB,
		appA:  appA,
		appB:  appB,
		hostA: hostA,
		hostB: hostB,
		proxy: proxy,
		conv:  dm.ConversationID(appA.Account().Pub(), appB.Account().Pub()),
	}
}

// send 经网关发送一条单聊文本，返回内核消息 ID。
func (g *gatePair) send(text string) (string, error) {
	raw, err := json.Marshal(map[string]any{
		"peer": hex.EncodeToString(g.appB.Account().Pub()),
		"text": text,
	})
	if err != nil {
		return "", err
	}
	data, gerr := g.gwA.Handle(context.Background(), "dm.sendText", raw)
	if gerr != nil {
		return "", gerr
	}
	m, _ := data.(map[string]any)
	uuid, _ := m["msg_uuid"].(string)
	return uuid, nil
}

// waitHeads 等待接收端会话达到指定条数。
func (g *gatePair) waitHeads(t *testing.T, want int, timeout time.Duration) {
	t.Helper()
	waitFor(t, timeout, func() bool {
		items, ok := gateHistory(g.gwB, g.conv)
		return ok && len(items) == want
	})
}

// linkCutSpec 描述一次链路中断门禁场景。
type linkCutSpec struct {
	title  string
	outage time.Duration
	total  int
}

// runLinkCutGate 执行「链路中断 → 期间消息本地落库并入队 → 恢复后自动补发」门禁流程。
func runLinkCutGate(t *testing.T, spec linkCutSpec) {
	t.Helper()

	g := newGatePair(t)

	// 预热：先经代理建立一次直连并完成收发。
	if _, err := g.send("warmup"); err != nil {
		t.Fatalf("预热发送失败: %v", err)
	}
	g.waitHeads(t, 1, 20*time.Second)

	// 中断链路并保持指定窗口。
	cutStart := time.Now()
	g.proxy.cut()
	time.Sleep(300 * time.Millisecond)
	if g.hostA.Network().Connectedness(g.hostB.ID()) == network.Connected {
		t.Fatal("链路切断后仍保持连接，门禁前提不成立")
	}

	for i := 0; i < spec.total; i++ {
		uuid, err := g.send(fmt.Sprintf("cut-%03d", i))
		if err != nil {
			t.Fatalf("中断期间发送应本地落库并入队，实际返回错误: %v", err)
		}
		if uuid == "" {
			t.Fatalf("中断期间发送未返回 msg_uuid")
		}
	}

	itemsA, ok := gateHistory(g.gwA, g.conv)
	if !ok {
		t.Fatal("读取发送端历史失败")
	}
	if len(itemsA) != spec.total+1 {
		t.Fatalf("中断期间发送端历史 %d 条，期望 %d", len(itemsA), spec.total+1)
	}
	failed := 0
	for _, item := range itemsA {
		if item["state"] == "failed" {
			failed++
		}
	}
	if failed != spec.total {
		counts := make(map[string]int)
		for _, item := range itemsA {
			counts[fmt.Sprint(item["state"])]++
		}
		t.Fatalf("中断期间应有 %d 条进入待补发状态，实际 %d（分布 %v）", spec.total, failed, counts)
	}

	if remain := time.Until(cutStart.Add(spec.outage)); remain > 0 {
		time.Sleep(remain)
	}
	if err := g.proxy.restore(); err != nil {
		t.Fatalf("恢复链路失败: %v", err)
	}

	// 恢复后立即发一条：新建连接会触发补发扫描，中断期间的队列应自动重发。
	if _, err := g.send("recovered"); err != nil {
		t.Fatalf("恢复后发送失败: %v", err)
	}

	want := spec.total + 2
	g.waitHeads(t, want, 120*time.Second)

	itemsB, ok := gateHistory(g.gwB, g.conv)
	if !ok {
		t.Fatal("读取接收端历史失败")
	}
	seenB := make(map[string]struct{}, len(itemsB))
	for _, item := range itemsB {
		uuid, _ := item["msg_uuid"].(string)
		if uuid == "" {
			t.Fatalf("接收端消息缺少 msg_uuid: %v", item)
		}
		if _, dup := seenB[uuid]; dup {
			t.Fatalf("接收端出现重复消息: %s", uuid)
		}
		seenB[uuid] = struct{}{}
		if item["direction"] != "in" {
			t.Fatalf("接收端方向应为 in: %v", item)
		}
	}
	expect := []string{"recovered"}
	for i := spec.total - 1; i >= 0; i-- {
		expect = append(expect, fmt.Sprintf("cut-%03d", i))
	}
	expect = append(expect, "warmup")
	for i, item := range itemsB {
		if item["text"] != expect[i] {
			t.Fatalf("第 %d 条正文 %v，期望 %q", i, item["text"], expect[i])
		}
	}

	// 发送端：全部转为已发送，且消息集合与接收端一致。
	waitFor(t, 60*time.Second, func() bool {
		items, ok := gateHistory(g.gwA, g.conv)
		if !ok || len(items) != want {
			return false
		}
		for _, item := range items {
			if item["state"] != "sent" {
				return false
			}
		}
		return true
	})
	itemsA, ok = gateHistory(g.gwA, g.conv)
	if !ok {
		t.Fatal("读取发送端历史失败")
	}
	seenA := make(map[string]struct{}, len(itemsA))
	for _, item := range itemsA {
		uuid, _ := item["msg_uuid"].(string)
		if _, dup := seenA[uuid]; dup {
			t.Fatalf("发送端出现重复消息: %s", uuid)
		}
		seenA[uuid] = struct{}{}
	}
	for uuid := range seenB {
		if _, ok := seenA[uuid]; !ok {
			t.Fatalf("发送端缺少接收端已入库的消息: %s", uuid)
		}
	}

	t.Logf("P2 门禁场景 %q 通过：中断/挂起 %s、%d 条消息 0 丢失 0 重复", spec.title, spec.outage, spec.total)
}

// TestP2GateLinkOutageKeepsConversationConsistent 对应 P2 门禁「拔网线 30s」场景：
// 中断期间消息落库并进入离线队列，链路恢复后自动补发，双方消息集合完全一致。
func TestP2GateLinkOutageKeepsConversationConsistent(t *testing.T) {
	if testing.Short() {
		t.Skip("P2 门禁用例需要 30 秒链路中断窗口")
	}
	runLinkCutGate(t, linkCutSpec{title: "拔网线 30s", outage: 30 * time.Second, total: 20})
}

// TestP2GateNetworkSwitchKeepsConversationConsistent 对应 P2 门禁「切 Wi-Fi/蜂窝」场景：
// 链路中断后以新地址重新建连（恢复时换新端口，等价于换网后拿到新地址），
// 中断期间的消息在恢复后自动补发且不重不漏。
func TestP2GateNetworkSwitchKeepsConversationConsistent(t *testing.T) {
	if testing.Short() {
		t.Skip("P2 门禁用例需要链路切换窗口")
	}
	runLinkCutGate(t, linkCutSpec{title: "切 Wi-Fi/蜂窝", outage: 3 * time.Second, total: 10})
}

// TestP2GateReceiverSuspendedKeepsConversationConsistent 对应 P2 门禁「锁屏 5 分钟」场景：
// 接收端被系统挂起期间链路保持建立但无法处理报文，挂起期间发送的消息全部本地落库并重试，
// 恢复后自动补发且双方消息集合一致。
//
// 5 分钟窗口耗时较长，默认跳过；设 NEXMEM_P2_SUSPEND_GATE=1 运行。
func TestP2GateReceiverSuspendedKeepsConversationConsistent(t *testing.T) {
	if testing.Short() {
		t.Skip("P2 门禁挂起场景需要 5 分钟窗口")
	}
	if os.Getenv("NEXMEM_P2_SUSPEND_GATE") != "1" {
		t.Skip("设置 NEXMEM_P2_SUSPEND_GATE=1 运行接收端挂起 5 分钟门禁")
	}

	const (
		suspendFor = 5 * time.Minute
		total      = 10
	)

	g := newGatePair(t)
	if _, err := g.send("warmup"); err != nil {
		t.Fatalf("预热发送失败: %v", err)
	}
	g.waitHeads(t, 1, 20*time.Second)

	// 挂起链路：连接不断，但接收端不再处理任何报文。
	suspendStart := time.Now()
	g.proxy.pause()
	time.Sleep(300 * time.Millisecond)

	// 并发发送，使每条消息在挂起窗口内完成 8s × 3 次重试并进入待补发队列。
	var wg sync.WaitGroup
	errs := make(chan error, total)
	for i := 0; i < total; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			uuid, err := g.send(fmt.Sprintf("suspend-%03d", i))
			if err != nil {
				errs <- err
				return
			}
			if uuid == "" {
				errs <- fmt.Errorf("挂起期间发送未返回 msg_uuid")
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("挂起期间发送应本地落库并入队，实际返回错误: %v", err)
	}

	itemsA, ok := gateHistory(g.gwA, g.conv)
	if !ok {
		t.Fatal("读取发送端历史失败")
	}
	if len(itemsA) != total+1 {
		t.Fatalf("挂起期间发送端历史 %d 条，期望 %d", len(itemsA), total+1)
	}
	failed := 0
	for _, item := range itemsA {
		if item["state"] == "failed" {
			failed++
		}
	}
	if failed != total {
		counts := make(map[string]int)
		for _, item := range itemsA {
			counts[fmt.Sprint(item["state"])]++
		}
		t.Fatalf("挂起期间应有 %d 条进入待补发状态，实际 %d（分布 %v）", total, failed, counts)
	}

	// 保持挂起满 5 分钟后再恢复。
	if remain := time.Until(suspendStart.Add(suspendFor)); remain > 0 {
		time.Sleep(remain)
	}
	g.proxy.resume()
	if _, err := g.send("awake"); err != nil {
		t.Fatalf("恢复后发送失败: %v", err)
	}

	want := total + 2
	g.waitHeads(t, want, 120*time.Second)

	itemsB, ok := gateHistory(g.gwB, g.conv)
	if !ok {
		t.Fatal("读取接收端历史失败")
	}
	textsB := make(map[string]struct{}, len(itemsB))
	seenB := make(map[string]struct{}, len(itemsB))
	for _, item := range itemsB {
		uuid, _ := item["msg_uuid"].(string)
		if uuid == "" {
			t.Fatalf("接收端消息缺少 msg_uuid: %v", item)
		}
		if _, dup := seenB[uuid]; dup {
			t.Fatalf("接收端出现重复消息: %s", uuid)
		}
		seenB[uuid] = struct{}{}
		if item["direction"] != "in" {
			t.Fatalf("接收端方向应为 in: %v", item)
		}
		textsB[fmt.Sprint(item["text"])] = struct{}{}
	}
	expect := map[string]struct{}{"warmup": {}, "awake": {}}
	for i := 0; i < total; i++ {
		expect[fmt.Sprintf("suspend-%03d", i)] = struct{}{}
	}
	if len(textsB) != len(expect) {
		t.Fatalf("接收端正文集合 %d 种，期望 %d 种", len(textsB), len(expect))
	}
	for text := range expect {
		if _, ok := textsB[text]; !ok {
			t.Fatalf("接收端缺少挂起期间的消息: %s", text)
		}
	}

	// 发送端：全部转为已发送，且消息集合与接收端一致。
	waitFor(t, 60*time.Second, func() bool {
		items, ok := gateHistory(g.gwA, g.conv)
		if !ok || len(items) != want {
			return false
		}
		for _, item := range items {
			if item["state"] != "sent" {
				return false
			}
		}
		return true
	})
	itemsA, ok = gateHistory(g.gwA, g.conv)
	if !ok {
		t.Fatal("读取发送端历史失败")
	}
	seenA := make(map[string]struct{}, len(itemsA))
	for _, item := range itemsA {
		uuid, _ := item["msg_uuid"].(string)
		if _, dup := seenA[uuid]; dup {
			t.Fatalf("发送端出现重复消息: %s", uuid)
		}
		seenA[uuid] = struct{}{}
	}
	for uuid := range seenB {
		if _, ok := seenA[uuid]; !ok {
			t.Fatalf("发送端缺少接收端已入库的消息: %s", uuid)
		}
	}

	t.Logf("P2 门禁场景 %q 通过：挂起 %s、%d 条消息 0 丢失 0 重复", "锁屏 5 分钟", suspendFor, total)
}
