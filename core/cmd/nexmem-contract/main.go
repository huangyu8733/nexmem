// Command nexmem-contract 从 gateway 注册表导出跨端契约文件 contract/api.json。
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nexmem/core/gateway"
)

func main() {
	out := flag.String("out", "contract/api.json", "契约输出路径")
	flag.Parse()

	data, err := gateway.New().ContractJSON()
	if err != nil {
		fmt.Fprintln(os.Stderr, "生成契约失败:", err)
		os.Exit(1)
	}
	data = append(data, '\n')

	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "创建目录失败:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "写入契约失败:", err)
		os.Exit(1)
	}
	fmt.Println("契约已写入", *out)
}
