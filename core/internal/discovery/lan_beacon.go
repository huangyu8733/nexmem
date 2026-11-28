package discovery

// LANBeacon 是"同一 WiFi 发现账号"的原生无关实现：用 UDP 受限广播定期
// 宣告本机签名名片（账号 ID + 设备 PeerID + 昵称）与局域网直连地址，
// 收到对端宣告后验签，得到可直接加好友的账号。
//
// 它不依赖 net.Interfaces()/mDNS 组播：广播发往 255.255.255.255，但发送 socket
// 会显式绑定宿主注入的局域网 IP，避免 iOS 在同时有蜂窝网络时把受限广播从默认
// 路由（蜂窝）发出，导致同一 WiFi 的对端收不到。Android 上即使 SELinux 拦截
// netlink 也能工作。签名名片复用二维码名片格式，防止伪造身份。

import (
	"context"
	"encoding/base64"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/nexmem/core/internal/identity"
	"github.com/nexmem/core/internal/qrshare"
)

const (
	// LANBeaconPort 是局域网发现广播端口。
	LANBeaconPort      = 5357
	lanBeaconMagic     = "NEXMEM-LAN/1|"
	lanBeaconInterval  = 3 * time.Second
	lanBeaconTTL       = 90 * time.Second
	lanBeaconMaxPacket = 8 * 1024
)

// LANPeer 是一条被验签的局域网发现记录。
type LANPeer struct {
	AccountID   string
	PeerID      string
	DisplayName string
	Addr        string // 对端局域网直连 multiaddr，含 /p2p/<PeerID>
	LastSeen    time.Time
}

// LANBeacon 管理广播与接收。
type LANBeacon struct {
	account *identity.Account
	peerID  string
	name    string
	addrs   []string // 本机局域网宣告地址（含 /p2p/<peerID>）

	mu              sync.RWMutex
	peers           map[string]LANPeer // key = accountID
	conn            *net.UDPConn       // 0.0.0.0:5357，负责接收
	broadcastConn   *net.UDPConn       // 绑定局域网 IP 的临时端口，负责发送
	broadcastAddr   string             // 实际绑定的源 IP；空串表示回退到 conn
	broadcastTarget string             // 定向广播地址（如 192.168.10.255）；空串用 255.255.255.255
	broadcastSent   uint64             // 成功广播次数（用于确认 iOS 真的发出过包）
	cancel          context.CancelFunc
	wg              sync.WaitGroup
	broadcastErr    string // 最近一次广播失败原因（iOS 权限/路由问题可观测）
}

// StartLANBeacon 启动局域网广播发现。account 为空或无局域网地址时返回错误。
// broadcastAddr 是可选的定向广播地址（如 192.168.10.255）；iOS 不允许向
// 255.255.255.255 受限广播发送（sendto: no route to host），必须传定向广播。
// 留空时回退到 255.255.255.255，兼容 Android/桌面/Web。
func StartLANBeacon(account *identity.Account, peerID, displayName string, lanMultiaddrs []string, broadcastAddr string) (*LANBeacon, error) {
	if account == nil || len(lanMultiaddrs) == 0 {
		return nil, &beaconError{"账号或局域网地址为空"}
	}
	// 绑定任意接口的 UDP 端口；受限广播不需要枚举网卡。
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: LANBeaconPort})
	if err != nil {
		return nil, &beaconError{err.Error()}
	}
	if err := conn.SetWriteDeadline(time.Time{}); err != nil {
		_ = conn.Close()
		return nil, &beaconError{err.Error()}
	}
	// 打开 SO_BROADCAST，否则写 255.255.255.255 会被系统拒绝。
	if err := setBroadcast(conn); err != nil {
		_ = conn.Close()
		return nil, &beaconError{err.Error()}
	}

	// 发送 socket 单独绑定宿主注入的局域网 IP：只靠 0.0.0.0 的默认路由在
	// iOS（蜂窝 + WiFi 并存）上可能从蜂窝口发出，WiFi 对端永远收不到。
	// 绑定失败时保留旧行为（用接收 socket 发送），并把原因暴露在诊断里。
	lanIP := lanIPFromMultiaddrs(lanMultiaddrs)
	b := &LANBeacon{
		account:         account,
		peerID:          peerID,
		name:            displayName,
		addrs:           lanMultiaddrs,
		peers:           map[string]LANPeer{},
		conn:            conn,
		broadcastTarget: broadcastAddr,
	}
	if lanIP != "" {
		sendConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP(lanIP), Port: 0})
		if err != nil {
			b.broadcastErr = "绑定局域网发送地址失败: " + err.Error()
		} else if err := setBroadcast(sendConn); err != nil {
			_ = sendConn.Close()
			b.broadcastErr = "设置广播发送地址失败: " + err.Error()
		} else {
			b.broadcastConn = sendConn
			b.broadcastAddr = lanIP
		}
	} else {
		b.broadcastErr = "无法从宣告地址解析出局域网 IP，广播走默认路由"
	}
	ctx, cancel := context.WithCancel(context.Background())
	b.cancel = cancel
	b.wg.Add(2)
	go b.broadcastLoop(ctx)
	go b.receiveLoop(ctx)
	return b, nil
}

// broadcastTargetIP 返回广播目标地址。iOS 不允许向受限广播 255.255.255.255
// 发送（sendto: no route to host），必须改用子网定向广播（如 192.168.10.255）。
// 注入值不是合法 IPv4 时回退到受限广播，兼容 Android/桌面/Web。
func broadcastTargetIP(target string) net.IP {
	if ip := net.ParseIP(target); ip != nil && ip.To4() != nil {
		return ip.To4()
	}
	return net.IPv4bcast
}

// lanIPFromMultiaddrs 从宣告地址中取第一个可用 IPv4。
// 移动端注入的 lan_addrs 形如 /ip4/192.168.10.91/tcp/41105/p2p/<PeerID>。
func lanIPFromMultiaddrs(addrs []string) string {
	for _, raw := range addrs {
		rest := raw
		for {
			start := strings.Index(rest, "/ip4/")
			if start < 0 {
				break
			}
			rest = rest[start+len("/ip4/"):]
			end := strings.IndexByte(rest, '/')
			ip := rest
			if end >= 0 {
				ip = rest[:end]
				rest = rest[end:]
			} else {
				rest = ""
			}
			parsed := net.ParseIP(ip)
			if parsed != nil && parsed.To4() != nil && ip != "0.0.0.0" {
				return ip
			}
		}
	}
	return ""
}

// broadcastLoop 定期广播本机签名名片与直连地址。
func (b *LANBeacon) broadcastLoop(ctx context.Context) {
	defer b.wg.Done()
	ticker := time.NewTicker(lanBeaconInterval)
	defer ticker.Stop()
	b.broadcastOnce()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			b.broadcastOnce()
		}
	}
}

func (b *LANBeacon) broadcastOnce() {
	card, err := qrshare.Encode(b.account, b.peerID, b.name)
	if err != nil {
		b.mu.Lock()
		b.broadcastErr = "签名名片失败: " + err.Error()
		b.mu.Unlock()
		return
	}
	// 选第一个局域网地址广播（无需把所有地址塞进一个包）。
	addr := ""
	if len(b.addrs) > 0 {
		addr = b.addrs[0]
	}
	payload := lanBeaconMagic + card + "|" + base64.RawURLEncoding.EncodeToString([]byte(addr))
	dst := &net.UDPAddr{IP: broadcastTargetIP(b.broadcastTarget), Port: LANBeaconPort}
	conn := b.conn
	if b.broadcastConn != nil {
		conn = b.broadcastConn
	}
	if _, err := conn.WriteToUDP([]byte(payload), dst); err != nil {
		b.mu.Lock()
		b.broadcastErr = err.Error()
		b.mu.Unlock()
		return
	}
	b.mu.Lock()
	b.broadcastErr = ""
	b.broadcastSent++
	b.mu.Unlock()
}

// BroadcastError 返回最近一次广播失败原因，空串表示广播正常。
func (b *LANBeacon) BroadcastError() string {
	if b == nil {
		return ""
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	// 广播循环启动后会立即发一次包；若计数仍为 0 且没有错误，说明 goroutine
	// 未进入发送或信标用了错误配置，直接把内部状态暴露出来，避免空态误判为
	// "对端没开机"。
	if b.broadcastErr == "" && b.broadcastSent == 0 {
		return fmt.Sprintf(
			"广播尚未发出: 源=%q 目标=%q 宣告地址=%v 接收socket=%t 发送socket=%t",
			b.broadcastAddr, b.broadcastTarget, b.addrs, b.conn != nil, b.broadcastConn != nil,
		)
	}
	return b.broadcastErr
}

// BroadcastLocalAddr 返回发送 socket 绑定的源 IP。
// 空串表示无法解析局域网 IP，广播仍走默认路由（iOS 上可能从蜂窝口发出）。
func (b *LANBeacon) BroadcastLocalAddr() string {
	if b == nil {
		return ""
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.broadcastAddr
}

// BroadcastSent 返回成功发出的广播包数量，用于确认移动端是否真的在发送。
func (b *LANBeacon) BroadcastSent() uint64 {
	if b == nil {
		return 0
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.broadcastSent
}

// receiveLoop 接收对端广播并验签。
func (b *LANBeacon) receiveLoop(ctx context.Context) {
	defer b.wg.Done()
	buf := make([]byte, lanBeaconMaxPacket)
	go func() {
		<-ctx.Done()
		_ = b.conn.Close()
	}()
	for {
		n, _, err := b.conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		b.handlePacket(buf[:n])
	}
}

func (b *LANBeacon) handlePacket(packet []byte) {
	text := string(packet)
	if !strings.HasPrefix(text, lanBeaconMagic) {
		return
	}
	rest := strings.TrimPrefix(text, lanBeaconMagic)
	parts := strings.SplitN(rest, "|", 2)
	if len(parts) != 2 {
		return
	}
	cardText, addrB64 := parts[0], parts[1]
	card, err := qrshare.Decode(cardText)
	if err != nil {
		return // 签名无效，忽略
	}
	if card.AccountID == "" || card.DeviceID == b.peerID {
		return // 忽略自己
	}
	addrRaw, err := base64.RawURLEncoding.DecodeString(addrB64)
	if err != nil {
		return
	}
	addr := string(addrRaw)
	// 地址必须含对端 PeerID，防止被引导连接到错误身份。
	if !strings.Contains(addr, card.DeviceID) {
		return
	}
	b.mu.Lock()
	b.peers[card.AccountID] = LANPeer{
		AccountID:   card.AccountID,
		PeerID:      card.DeviceID,
		DisplayName: card.DisplayName,
		Addr:        addr,
		LastSeen:    time.Now(),
	}
	b.mu.Unlock()
}

// Snapshot 返回 TTL 内未过期的局域网发现记录。
func (b *LANBeacon) Snapshot() []LANPeer {
	if b == nil {
		return nil
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	out := make([]LANPeer, 0, len(b.peers))
	now := time.Now()
	for _, p := range b.peers {
		if now.Sub(p.LastSeen) > lanBeaconTTL {
			continue
		}
		out = append(out, p)
	}
	return out
}

// Close 停止广播与接收。
func (b *LANBeacon) Close() error {
	if b.cancel != nil {
		b.cancel()
	}
	b.wg.Wait()
	if b.broadcastConn != nil && b.broadcastConn != b.conn {
		_ = b.broadcastConn.Close()
	}
	if b.conn != nil {
		return b.conn.Close()
	}
	return nil
}

type beaconError struct{ msg string }

func (e *beaconError) Error() string { return "局域网发现: " + e.msg }
