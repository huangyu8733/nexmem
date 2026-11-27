//go:build windows

package discovery

import (
	"net"

	"golang.org/x/sys/windows"
)

// setBroadcast 打开 UDP socket 的 SO_BROADCAST，允许发往 255.255.255.255。
func setBroadcast(conn *net.UDPConn) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		sockErr = windows.SetsockoptInt(
			windows.Handle(fd), windows.SOL_SOCKET, windows.SO_BROADCAST, 1,
		)
	}); err != nil {
		return err
	}
	return sockErr
}
