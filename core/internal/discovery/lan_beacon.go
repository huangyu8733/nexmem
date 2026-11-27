package discovery

// LANBeacon 是"同一 WiFi 发现账号"的原生无关实现：用 UDP 受限广播定期
// 宣告本机签名名片（账号 ID + 设备 PeerID + 昵称）与局域网直连地址，
// 收到对端宣告后验签，得到可直接加好友的账号。
//
// 它不依赖 net.Interfaces()/mDNS 组播：广播发往 255.255.255.255，由内核按
// 默认路由出接口，Android 上即使 SELinux 拦截 netlink 也能工作。签名名片
// 复用二维码名片格式，防止伪造身份。

import (
	"context"
	"encoding/base64"
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

	mu           sync.RWMutex
	peers        map[string]LANPeer // key = accountID
	conn         *net.UDPConn
	cancel       context.CancelFunc
	wg           sync.WaitGroup
	broadcastErr string // 最近一次广播失败原因（iOS 权限/路由问题可观测）
}

// StartLANBeacon 启动局域网广播发现。account 为空或无局域网地址时返回错误。
func StartLANBeacon(account *identity.Account, peerID, displayName string, lanMultiaddrs []string) (*LANBeacon, error) {
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

	b := &LANBeacon{
		account: account,
		peerID:  peerID,
		name:    displayName,
		addrs:   lanMultiaddrs,
		peers:   map[string]LANPeer{},
		conn:    conn,
	}
	ctx, cancel := context.WithCancel(context.Background())
	b.cancel = cancel
	b.wg.Add(2)
	go b.broadcastLoop(ctx)
	go b.receiveLoop(ctx)
	return b, nil
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
		return
	}
	// 选第一个局域网地址广播（无需把所有地址塞进一个包）。
	addr := ""
	if len(b.addrs) > 0 {
		addr = b.addrs[0]
	}
	payload := lanBeaconMagic + card + "|" + base64.RawURLEncoding.EncodeToString([]byte(addr))
	dst := &net.UDPAddr{IP: net.IPv4bcast, Port: LANBeaconPort}
	if _, err := b.conn.WriteToUDP([]byte(payload), dst); err != nil {
		b.mu.Lock()
		b.broadcastErr = err.Error()
		b.mu.Unlock()
	} else {
		b.mu.Lock()
		b.broadcastErr = ""
		b.mu.Unlock()
	}
}

// BroadcastError 返回最近一次广播失败原因，空串表示广播正常。
func (b *LANBeacon) BroadcastError() string {
	if b == nil {
		return ""
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.broadcastErr
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
	if b.conn != nil {
		return b.conn.Close()
	}
	return nil
}

type beaconError struct{ msg string }

func (e *beaconError) Error() string { return "局域网发现: " + e.msg }
