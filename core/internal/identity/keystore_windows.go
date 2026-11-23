//go:build windows && !android

package identity

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// DPAPIKeyStore 用 Windows DPAPI 保护主密钥文件。
// 密文与当前 Windows 用户绑定，复制到其他用户或机器上无法解封。
type DPAPIKeyStore struct {
	// Path 是 DPAPI 密文文件路径。
	Path string
}

// NewKeyStore 返回当前桌面平台的主密钥存储实现。
func NewKeyStore(path string) KeyStore {
	return &DPAPIKeyStore{Path: path}
}

const cryptProtectUIForbidden = 0x1

var (
	crypt32                = syscall.NewLazyDLL("crypt32.dll")
	kernel32               = syscall.NewLazyDLL("kernel32.dll")
	procCryptProtectData   = crypt32.NewProc("CryptProtectData")
	procCryptUnprotectData = crypt32.NewProc("CryptUnprotectData")
	procLocalFree          = kernel32.NewProc("LocalFree")
)

type dataBlob struct {
	cbData uint32
	pbData *byte
}

// MasterKey 只读取现有 DPAPI 条目，条目缺失返回 ErrKeyStoreMissing。
func (s *DPAPIKeyStore) MasterKey() ([]byte, error) {
	key, err := s.read()
	if errors.Is(err, ErrKeyStoreMissing) {
		return nil, err
	}
	return key, err
}

// EnsureMasterKey 读取条目；不存在时生成 32 字节随机主密钥并以 DPAPI 加密落盘。
func (s *DPAPIKeyStore) EnsureMasterKey() ([]byte, error) {
	key, err := s.read()
	if err == nil {
		return key, nil
	}
	if !errors.Is(err, ErrKeyStoreMissing) {
		return nil, err
	}
	key = make([]byte, masterKeySize)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("生成主密钥: %w", err)
	}
	blob, err := dpapiCall(true, key)
	if err != nil {
		return nil, fmt.Errorf("%w: DPAPI 加密失败: %v", ErrKeyStoreLocked, err)
	}
	if err := writeKeyFile(s.Path, blob); err != nil {
		return nil, err
	}
	return key, nil
}

// Delete 删除 DPAPI 条目；条目已不存在视为成功。
func (s *DPAPIKeyStore) Delete() error {
	if s == nil || s.Path == "" {
		return nil
	}
	if err := os.Remove(s.Path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (s *DPAPIKeyStore) read() ([]byte, error) {
	if s == nil || s.Path == "" {
		return nil, fmt.Errorf("%w: 未配置 DPAPI 条目路径", ErrKeyStoreLocked)
	}
	blob, err := os.ReadFile(s.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrKeyStoreMissing, s.Path)
		}
		return nil, fmt.Errorf("%w: %v", ErrKeyStoreLocked, err)
	}
	key, err := dpapiCall(false, blob)
	if err != nil {
		return nil, fmt.Errorf("%w: DPAPI 解密失败: %v", ErrKeyStoreLocked, err)
	}
	if len(key) != masterKeySize {
		return nil, fmt.Errorf("%w: 主密钥长度 %d", ErrKeyStoreLocked, len(key))
	}
	return key, nil
}

// dpapiCall 执行 DPAPI 加/解密；protect=false 且不匹配当前用户时返回错误。
func dpapiCall(protect bool, in []byte) ([]byte, error) {
	if len(in) == 0 {
		return nil, errors.New("DPAPI 输入为空")
	}
	entropy := []byte(keystoreDomain)
	inBlob := dataBlob{cbData: uint32(len(in)), pbData: &in[0]}
	entBlob := dataBlob{cbData: uint32(len(entropy)), pbData: &entropy[0]}
	var out dataBlob

	var r uintptr
	var err error
	if protect {
		r, _, err = procCryptProtectData.Call(
			uintptr(unsafe.Pointer(&inBlob)),
			0,
			uintptr(unsafe.Pointer(&entBlob)),
			0,
			0,
			cryptProtectUIForbidden,
			uintptr(unsafe.Pointer(&out)),
		)
	} else {
		r, _, err = procCryptUnprotectData.Call(
			uintptr(unsafe.Pointer(&inBlob)),
			0,
			uintptr(unsafe.Pointer(&entBlob)),
			0,
			0,
			cryptProtectUIForbidden,
			uintptr(unsafe.Pointer(&out)),
		)
	}
	if r == 0 {
		if err == nil || errors.Is(err, syscall.Errno(0)) {
			err = syscall.EINVAL
		}
		return nil, err
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.pbData)))
	return append([]byte(nil), unsafe.Slice(out.pbData, out.cbData)...), nil
}
