// nexmem-keystoretest 是 P1-02 的内核 CLI 验收程序：
// 在临时目录创建 KeyStore 主密钥与密文账号，验证落盘内容不含明文私钥、
// 重新加载可还原同一账号，以及删除 Keystore 条目后无法再解密。
package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nexmem/core/internal/identity"
)

func main() {
	dir := flag.String("dir", "", "工作目录，默认使用临时目录")
	flag.Parse()

	if err := run(*dir); err != nil {
		fmt.Printf("RESULT=FAIL\nerror=%v\n", err)
		os.Exit(1)
	}
}

func run(dir string) error {
	if dir == "" {
		var err error
		dir, err = os.MkdirTemp("", "nexmem-keystore-*")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
	} else if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}

	ks := identity.NewKeyStore(filepath.Join(dir, "master.key"))
	accPath := filepath.Join(dir, "account.enc")

	acc, err := identity.LoadOrCreateSealedAccount(accPath, ks)
	if err != nil {
		return fmt.Errorf("创建密文账号: %w", err)
	}
	raw, err := os.ReadFile(accPath)
	if err != nil {
		return err
	}
	fmt.Printf("KEYSTORE_ACCOUNT_ID=%s\n", acc.ID())
	fmt.Printf("KEYSTORE_SEALED_FILE_BYTES=%d\n", len(raw))

	xprivB64 := base64.StdEncoding.EncodeToString(acc.XPriv())
	if bytes.Contains(raw, []byte(xprivB64)) || bytes.Contains(raw, []byte("account_ed25519_seed")) ||
		bytes.Contains(raw, []byte("account_x25519_priv")) {
		return errors.New("密文文件中检测到明文私钥")
	}
	fmt.Println("KEYSTORE_PLAINTEXT_LEAK=false")

	reloaded, err := identity.LoadSealedAccount(accPath, ks)
	if err != nil {
		return fmt.Errorf("重新加载密文账号: %w", err)
	}
	if reloaded.ID() != acc.ID() {
		return errors.New("重新加载后账号 ID 不一致")
	}
	fmt.Println("KEYSTORE_RELOAD=ok")

	deleter, ok := ks.(interface{ Delete() error })
	if !ok {
		return errors.New("当前平台 KeyStore 不支持删除条目")
	}
	if err := deleter.Delete(); err != nil {
		return fmt.Errorf("删除 Keystore 条目: %w", err)
	}
	_, err = identity.LoadSealedAccount(accPath, ks)
	if !errors.Is(err, identity.ErrKeyStoreMissing) {
		return fmt.Errorf("删除条目后应无法解密，实际 %v", err)
	}
	fmt.Println("KEYSTORE_AFTER_DELETE=denied")
	fmt.Println("RESULT=PASS")
	return nil
}
