//go:build !windows

package discovery

import (
	"net"

	"golang.org/x/sys/unix"
)

// setBroadcast 打开 UDP socket 的 SO_BROADCAST，允许发往 255.255.255.255。
func setBroadcast(conn *net.UDPConn) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		sockErr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_BROADCAST, 1)
	}); err != nil {
		return err
	}
	return sockErr
}
