package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildDebLayout(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "opt", "nexmem")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(appDir, "nexmem_app")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\necho nexmem\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	text := []byte("hello nexmem")
	if err := os.WriteFile(filepath.Join(appDir, "LICENSE"), text, 0o644); err != nil {
		t.Fatal(err)
	}

	hasSymlink := true
	if err := os.MkdirAll(filepath.Join(root, "usr", "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/opt/nexmem/nexmem_app", filepath.Join(root, "usr", "bin", "nexmem")); err != nil {
		hasSymlink = false
	}

	entries, err := collect(root)
	if err != nil {
		t.Fatalf("collect: %v", err)
	}
	dataTar, installedKB, err := buildDataTar(root, entries, 0)
	if err != nil {
		t.Fatalf("buildDataTar: %v", err)
	}
	control := buildControl(controlMeta{
		Package:     "nexmem",
		Version:     "1.0.0",
		Arch:        "amd64",
		Maintainer:  "Nexmem <dev@nexmem.local>",
		Depends:     "libc6",
		InstalledKB: installedKB,
		Description: "Nexmem 去中心化 P2P 即时通讯客户端",
		Extended:    "消息经端到端加密直连投递。",
	})
	controlTar, err := buildControlTar(control, buildMD5Sums(root, entries), 0)
	if err != nil {
		t.Fatalf("buildControlTar: %v", err)
	}
	deb := buildAr([]arMember{
		{name: "debian-binary", data: []byte("2.0\n"), mode: 0o100644},
		{name: "control.tar.gz", data: controlTar, mode: 0o100644},
		{name: "data.tar.gz", data: dataTar, mode: 0o100644},
	}, 0)

	members, err := parseAr(deb)
	if err != nil {
		t.Fatalf("parseAr: %v", err)
	}
	gotNames := make([]string, 0, len(members))
	for _, m := range members {
		gotNames = append(gotNames, m.name)
	}
	wantNames := "debian-binary,control.tar.gz,data.tar.gz"
	if strings.Join(gotNames, ",") != wantNames {
		t.Fatalf("ar 成员顺序 = %v，期望 %s", gotNames, wantNames)
	}
	if string(members[0].data) != "2.0\n" {
		t.Fatalf("debian-binary = %q", members[0].data)
	}

	controlFiles, err := parseTarGz(members[1].data)
	if err != nil {
		t.Fatalf("解析 control.tar.gz: %v", err)
	}
	cfile, ok := controlFiles["./control"]
	if !ok {
		t.Fatalf("control.tar.gz 缺少 ./control，实际 %v", keys(controlFiles))
	}
	for _, want := range []string{
		"Package: nexmem\n",
		"Version: 1.0.0\n",
		"Architecture: amd64\n",
		fmt.Sprintf("Installed-Size: %d\n", installedKB),
		"Depends: libc6\n",
		"Section: net\n",
		"Description: Nexmem 去中心化 P2P 即时通讯客户端\n",
		" 消息经端到端加密直连投递。\n",
	} {
		if !strings.Contains(string(cfile.data), want) {
			t.Fatalf("control 缺少 %q：\n%s", want, cfile.data)
		}
	}

	sums, ok := controlFiles["./md5sums"]
	if !ok {
		t.Fatalf("control.tar.gz 缺少 ./md5sums")
	}
	wantSum := md5.Sum(text)
	if !strings.Contains(string(sums.data), hex.EncodeToString(wantSum[:])+"  opt/nexmem/LICENSE\n") {
		t.Fatalf("md5sums 不含 LICENSE 摘要：\n%s", sums.data)
	}

	dataFiles, err := parseTarGz(members[2].data)
	if err != nil {
		t.Fatalf("解析 data.tar.gz: %v", err)
	}
	bin, ok := dataFiles["./opt/nexmem/nexmem_app"]
	if !ok {
		t.Fatalf("data.tar.gz 缺少可执行文件，实际 %v", keys(dataFiles))
	}
	if bin.mode&0o111 == 0 {
		t.Fatalf("可执行位丢失：mode=%o", bin.mode)
	}
	if !bin.dir && !bytes.Equal(bin.data, []byte("#!/bin/sh\necho nexmem\n")) {
		t.Fatalf("可执行文件内容不一致")
	}
	if _, ok := dataFiles["./opt/nexmem/LICENSE"]; !ok {
		t.Fatalf("data.tar.gz 缺少 LICENSE")
	}
	if hasSymlink {
		link, ok := dataFiles["./usr/bin/nexmem"]
		if !ok || !link.symlink || link.linkname != "/opt/nexmem/nexmem_app" {
			t.Fatalf("符号链接条目不正确：%+v", link)
		}
	}
	if _, ok := dataFiles["./"]; !ok {
		t.Fatalf("data.tar.gz 缺少根目录条目")
	}
}

func TestBuildDebDeterministic(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "usr", "share"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "usr", "share", "a.txt"), []byte("a"), 0o644); err != nil {
		t.Fatal(err)
	}

	build := func() []byte {
		entries, err := collect(root)
		if err != nil {
			t.Fatal(err)
		}
		dataTar, kb, err := buildDataTar(root, entries, 0)
		if err != nil {
			t.Fatal(err)
		}
		control := buildControl(controlMeta{Package: "nexmem", Version: "1.0.0", Arch: "amd64", InstalledKB: kb})
		controlTar, err := buildControlTar(control, buildMD5Sums(root, entries), 0)
		if err != nil {
			t.Fatal(err)
		}
		return buildAr([]arMember{
			{name: "debian-binary", data: []byte("2.0\n"), mode: 0o100644},
			{name: "control.tar.gz", data: controlTar, mode: 0o100644},
			{name: "data.tar.gz", data: dataTar, mode: 0o100644},
		}, 0)
	}
	if !bytes.Equal(build(), build()) {
		t.Fatal("同一输入两次打包结果不一致")
	}
}

func TestCollectRejectsMissingRoot(t *testing.T) {
	if _, err := collect(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("不存在目录应报错")
	}
}

func TestValidateMetadata(t *testing.T) {
	if err := validateName("Nexmem"); err == nil {
		t.Fatal("大写包名应被拒绝")
	}
	if err := validateVersion("v1.0.0"); err == nil {
		t.Fatal("非数字开头版本号应被拒绝")
	}
	if err := validateName("nexmem"); err != nil {
		t.Fatalf("合法包名被拒绝: %v", err)
	}
	if err := validateVersion("1.0.0-rc.1"); err != nil {
		t.Fatalf("合法版本号被拒绝: %v", err)
	}
}

type arFile struct {
	name string
	data []byte
}

func parseAr(b []byte) ([]arFile, error) {
	if !bytes.HasPrefix(b, []byte("!<arch>\n")) {
		return nil, fmt.Errorf("不是 ar 归档")
	}
	rest := b[len("!<arch>\n"):]
	var out []arFile
	for len(rest) > 0 {
		if len(rest) < 60 {
			return nil, fmt.Errorf("ar 头部不完整")
		}
		hdr := rest[:60]
		rest = rest[60:]
		name := strings.TrimSpace(strings.TrimSuffix(string(hdr[0:16]), "/"))
		sizeField := strings.TrimSpace(string(hdr[48:58]))
		var size int
		if _, err := fmt.Sscanf(sizeField, "%d", &size); err != nil {
			return nil, fmt.Errorf("ar 大小字段非法 %q", sizeField)
		}
		if size < 0 || len(rest) < size {
			return nil, fmt.Errorf("ar 成员 %s 数据不足", name)
		}
		out = append(out, arFile{name: name, data: rest[:size]})
		rest = rest[size:]
		if size%2 == 1 {
			if len(rest) < 1 {
				return nil, fmt.Errorf("ar 成员 %s 缺少补齐字节", name)
			}
			rest = rest[1:]
		}
	}
	return out, nil
}

type tarEntry struct {
	data     []byte
	mode     int64
	dir      bool
	symlink  bool
	linkname string
}

func parseTarGz(b []byte) (map[string]tarEntry, error) {
	gz, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	out := make(map[string]tarEntry)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		e := tarEntry{mode: hdr.Mode, dir: hdr.Typeflag == tar.TypeDir, symlink: hdr.Typeflag == tar.TypeSymlink, linkname: hdr.Linkname}
		if hdr.Typeflag == tar.TypeReg {
			data, err := io.ReadAll(tr)
			if err != nil {
				return nil, err
			}
			e.data = data
		}
		out[hdr.Name] = e
	}
	return out, nil
}

func keys(m map[string]tarEntry) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
