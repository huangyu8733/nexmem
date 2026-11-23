package coreapp

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	lpcrypto "github.com/libp2p/go-libp2p/core/crypto"

	nxcrypto "github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/identity"
)

// deviceKeyFile 是设备私钥的密文文件名（相对数据目录）。
const deviceKeyFile = "device.key"

// loadDeviceKey 读取设备私钥；不存在时生成并以账号 X25519 公钥封装后落盘。
//
// 设备私钥决定 PeerID，必须跨重启稳定；落盘形态为密文，避免明文私钥留在磁盘上。
func loadDeviceKey(dataDir string, acc *identity.Account) (lpcrypto.PrivKey, error) {
	if acc == nil {
		return nil, errors.New("缺少账号")
	}
	path := filepath.Join(dataDir, deviceKeyFile)
	sealed, err := os.ReadFile(path)
	switch {
	case err == nil:
		return unsealDeviceKey(sealed, acc)
	case !errors.Is(err, os.ErrNotExist):
		return nil, fmt.Errorf("读取设备密钥: %w", err)
	}

	priv, _, err := lpcrypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("生成设备密钥: %w", err)
	}
	raw, err := lpcrypto.MarshalPrivateKey(priv)
	if err != nil {
		return nil, fmt.Errorf("序列化设备密钥: %w", err)
	}
	env, err := nxcrypto.SealMessage(acc.XPub(), raw, []byte(deviceKeyAAD))
	if err != nil {
		return nil, fmt.Errorf("封装设备密钥: %w", err)
	}
	if err := writeSealedKey(path, encodeSealed(env)); err != nil {
		return nil, err
	}
	return priv, nil
}

// unsealDeviceKey 用账号 X25519 私钥解封并解析设备私钥。
func unsealDeviceKey(sealed []byte, acc *identity.Account) (lpcrypto.PrivKey, error) {
	msg, err := decodeSealed(sealed)
	if err != nil {
		return nil, err
	}
	raw, err := nxcrypto.OpenMessage(acc.XPriv(), msg, []byte(deviceKeyAAD))
	if err != nil {
		return nil, fmt.Errorf("解封设备密钥: %w", err)
	}
	priv, err := lpcrypto.UnmarshalPrivateKey(raw)
	if err != nil {
		return nil, fmt.Errorf("解析设备密钥: %w", err)
	}
	return priv, nil
}

// rotateDeviceKeyIfStale 清理无法用当前账号解封的旧设备密钥。
//
// 设备密钥以账号 X25519 私钥封装，导入备份替换账号后旧文件永久解不开；
// 若不清理，下次启动会在解封阶段失败，表现为「导入备份后重启打不开」。
// 清理后由下次启动生成新设备密钥，PeerID 随之更新（账号身份不变）。
func rotateDeviceKeyIfStale(dataDir string, acc *identity.Account) error {
	if acc == nil {
		return errors.New("缺少账号")
	}
	path := filepath.Join(dataDir, deviceKeyFile)
	sealed, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("读取设备密钥: %w", err)
	}
	if _, err := unsealDeviceKey(sealed, acc); err == nil {
		return nil
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("重置设备密钥: %w", err)
	}
	return nil
}

// deviceKeyAAD 是设备私钥密文的附加认证数据，避免与其他信封交叉解密。
const deviceKeyAAD = "nexmem/device-key/v1"

// encodeSealed 把信封序列化为：uint16(encKeyLen) | encKey | nonce | ciphertext。
func encodeSealed(msg *nxcrypto.SealedMessage) []byte {
	out := make([]byte, 2+len(msg.EncryptedKey)+len(msg.Nonce)+len(msg.Ciphertext))
	out[0] = byte(len(msg.EncryptedKey) >> 8)
	out[1] = byte(len(msg.EncryptedKey))
	n := copy(out[2:], msg.EncryptedKey)
	n += copy(out[2+n:], msg.Nonce)
	copy(out[2+n:], msg.Ciphertext)
	return out
}

// decodeSealed 解析 encodeSealed 的产物。
func decodeSealed(raw []byte) (*nxcrypto.SealedMessage, error) {
	if len(raw) < 2 {
		return nil, errors.New("设备密钥密文长度不足")
	}
	keyLen := int(raw[0])<<8 | int(raw[1])
	rest := raw[2:]
	if keyLen <= 0 || len(rest) < keyLen+1 {
		return nil, errors.New("设备密钥密文结构损坏")
	}
	if keyLen > len(rest) {
		return nil, errors.New("设备密钥密文结构损坏")
	}
	encKey := rest[:keyLen]
	rest = rest[keyLen:]
	const nonceLen = 12
	if len(rest) <= nonceLen {
		return nil, errors.New("设备密钥密文缺少正文")
	}
	return &nxcrypto.SealedMessage{
		KeyAlg:       nxcrypto.EnvelopeKeyAlg,
		EncryptedKey: encKey,
		Nonce:        rest[:nonceLen],
		Ciphertext:   rest[nonceLen:],
	}, nil
}

// writeSealedKey 原子写入密文密钥文件，权限 0600。
func writeSealedKey(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建设备密钥目录: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("写入设备密钥: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("替换设备密钥: %w", err)
	}
	return nil
}
