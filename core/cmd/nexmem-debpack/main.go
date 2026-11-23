// nexmem-debpack 把已暂存的 Linux 发行根目录打包成 .deb 安装包（P6-09）。
//
// .deb 是 ar 归档，依次包含 debian-binary、control.tar.gz、data.tar.gz。
// 该工具只用标准库实现，因此在 Windows/macOS/Linux 任一宿主上都能生成同样的
// 包结构，便于在缺少 dpkg-deb 的环境（本机 Windows、CI 的 macOS 运行器）做
// 打包回归；真实安装验证仍需 Ubuntu 宿主（见 R-19）。
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/md5"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

func main() {
	root := flag.String("root", "", "已暂存的包根目录（其下的 usr/、opt/ 等会原样进入 data.tar.gz）")
	out := flag.String("out", "", ".deb 输出路径，默认 dist/<package>_<version>_<arch>.deb")
	pkg := flag.String("package", "nexmem", "包名")
	version := flag.String("version", "1.0.0", "版本号")
	arch := flag.String("arch", "amd64", "架构（amd64/arm64）")
	maintainer := flag.String("maintainer", "Nexmem <dev@nexmem.local>", "维护者")
	depends := flag.String("depends", "libc6, libgtk-3-0, libblkid1, liblzma5, libstdc++6", "运行时依赖")
	description := flag.String("description", "Nexmem 去中心化 P2P 即时通讯客户端", "一句话描述")
	extended := flag.String("extended-description", "Nexmem 是一个去中心化 P2P 即时通讯客户端，消息经端到端加密直连投递，离线消息由用户自托管存储补齐。", "详细描述")
	epoch := flag.Int64("epoch", 0, "归档内 mtime（Unix 秒），默认 0 以保证可重复构建")
	flag.Parse()

	if *root == "" {
		fail("-root 必填")
	}
	if err := validateName(*pkg); err != nil {
		fail(err.Error())
	}
	if err := validateVersion(*version); err != nil {
		fail(err.Error())
	}
	if *out == "" {
		*out = filepath.Join("dist", fmt.Sprintf("%s_%s_%s.deb", *pkg, *version, *arch))
	}

	entries, err := collect(*root)
	if err != nil {
		fail(fmt.Sprintf("读取包根目录: %v", err))
	}
	if len(entries) == 0 {
		fail("包根目录为空")
	}

	dataTar, installedKB, err := buildDataTar(*root, entries, *epoch)
	if err != nil {
		fail(err.Error())
	}
	control := buildControl(controlMeta{
		Package:     *pkg,
		Version:     *version,
		Arch:        *arch,
		Maintainer:  *maintainer,
		Depends:     *depends,
		InstalledKB: installedKB,
		Description: *description,
		Extended:    *extended,
	})
	controlTar, err := buildControlTar(control, buildMD5Sums(*root, entries), *epoch)
	if err != nil {
		fail(err.Error())
	}

	deb := buildAr([]arMember{
		{name: "debian-binary", data: []byte("2.0\n"), mode: 0o100644},
		{name: "control.tar.gz", data: controlTar, mode: 0o100644},
		{name: "data.tar.gz", data: dataTar, mode: 0o100644},
	}, *epoch)

	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		fail(fmt.Sprintf("创建输出目录: %v", err))
	}
	if err := os.WriteFile(*out, deb, 0o644); err != nil {
		fail(fmt.Sprintf("写入 %s: %v", *out, err))
	}

	fmt.Printf("DEB_PATH=%s\n", *out)
	fmt.Printf("DEB_SIZE_BYTES=%d\n", len(deb))
	fmt.Printf("DEB_FILES=%d\n", countRegular(entries))
	fmt.Printf("DEB_INSTALLED_KB=%d\n", installedKB)
	fmt.Println("RESULT=PASS")
}

func fail(msg string) {
	fmt.Printf("RESULT=FAIL\nerror=%s\n", msg)
	os.Exit(1)
}

var (
	namePattern    = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]+$`)
	versionPattern = regexp.MustCompile(`^[0-9][0-9A-Za-z.+~:-]*$`)
)

func validateName(name string) error {
	if !namePattern.MatchString(name) {
		return fmt.Errorf("非法包名 %q：仅允许小写字母、数字与 +.-", name)
	}
	return nil
}

func validateVersion(version string) error {
	if !versionPattern.MatchString(version) {
		return fmt.Errorf("非法版本号 %q：须以数字开头且只含字母数字与 .+~:-", version)
	}
	return nil
}

type entry struct {
	rel    string // 相对包根的 slash 路径
	mode   int64
	size   int64
	link   string
	isDir  bool
	isFile bool
}

func collect(root string) ([]entry, error) {
	var out []entry
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == root {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		e := entry{rel: filepath.ToSlash(rel), mode: int64(info.Mode().Perm())}
		switch {
		case d.IsDir():
			e.isDir = true
			e.mode = 0o755
		case info.Mode()&os.ModeSymlink != 0:
			target, err := os.Readlink(p)
			if err != nil {
				return err
			}
			e.link = filepath.ToSlash(target)
		case info.Mode().IsRegular():
			e.isFile = true
			e.size = info.Size()
			e.mode = executablePerm(p, e.mode)
		default:
			return fmt.Errorf("不支持的条目类型（仅接受普通文件、目录与符号链接）: %s", rel)
		}
		out = append(out, e)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].rel < out[j].rel })
	return out, nil
}

func countRegular(entries []entry) int {
	n := 0
	for _, e := range entries {
		if e.isFile {
			n++
		}
	}
	return n
}

// executablePerm 把普通文件的权限统一为 0644 / 0755：
// 源文件带执行位或内容为 ELF / 脚本时给 0755，其余 0644。
// 这样 Windows（不保留执行位、权限恒为 0666）与 Linux 产出一致。
func executablePerm(p string, perm int64) int64 {
	if perm&0o111 != 0 {
		return 0o755
	}
	f, err := os.Open(p)
	if err != nil {
		return 0o644
	}
	defer f.Close()
	head := make([]byte, 4)
	n, _ := io.ReadFull(f, head)
	head = head[:n]
	if bytes.Equal(head, []byte("\x7fELF")) || bytes.HasPrefix(head, []byte("#!")) {
		return 0o755
	}
	return 0o644
}

func buildDataTar(root string, entries []entry, epoch int64) ([]byte, int64, error) {
	mtime := time.Unix(epoch, 0).UTC()
	var buf bytes.Buffer
	gz, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, 0, err
	}
	tw := tar.NewWriter(gz)

	if err := tw.WriteHeader(&tar.Header{
		Typeflag: tar.TypeDir,
		Name:     "./",
		Mode:     0o755,
		ModTime:  mtime,
		Format:   tar.FormatGNU,
	}); err != nil {
		return nil, 0, err
	}

	var installed int64
	for _, e := range entries {
		hdr := &tar.Header{
			Name:    "./" + e.rel,
			Mode:    e.mode,
			ModTime: mtime,
			Uname:   "root",
			Gname:   "root",
			Format:  tar.FormatGNU,
		}
		switch {
		case e.isDir:
			hdr.Typeflag = tar.TypeDir
			if !strings.HasSuffix(hdr.Name, "/") {
				hdr.Name += "/"
			}
		case e.link != "":
			hdr.Typeflag = tar.TypeSymlink
			hdr.Linkname = e.link
		default:
			hdr.Typeflag = tar.TypeReg
			hdr.Size = e.size
			installed += e.size
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return nil, 0, fmt.Errorf("写入 tar 头 %s: %w", e.rel, err)
		}
		if e.isFile {
			f, err := os.Open(filepath.Join(root, filepath.FromSlash(e.rel)))
			if err != nil {
				return nil, 0, fmt.Errorf("打开 %s: %w", e.rel, err)
			}
			if _, err := io.Copy(tw, f); err != nil {
				f.Close()
				return nil, 0, fmt.Errorf("写入 %s: %w", e.rel, err)
			}
			if err := f.Close(); err != nil {
				return nil, 0, err
			}
		}
	}
	if err := tw.Close(); err != nil {
		return nil, 0, err
	}
	if err := gz.Close(); err != nil {
		return nil, 0, err
	}
	return buf.Bytes(), (installed + 1023) / 1024, nil
}

func buildMD5Sums(root string, entries []entry) string {
	var b strings.Builder
	for _, e := range entries {
		if !e.isFile {
			continue
		}
		f, err := os.Open(filepath.Join(root, filepath.FromSlash(e.rel)))
		if err != nil {
			continue
		}
		sum := md5.New()
		_, err = io.Copy(sum, f)
		f.Close()
		if err != nil {
			continue
		}
		b.WriteString(hex.EncodeToString(sum.Sum(nil)))
		b.WriteString("  ")
		b.WriteString(e.rel)
		b.WriteString("\n")
	}
	return b.String()
}

type controlMeta struct {
	Package     string
	Version     string
	Arch        string
	Maintainer  string
	Depends     string
	InstalledKB int64
	Description string
	Extended    string
}

func buildControl(m controlMeta) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Package: %s\n", m.Package)
	fmt.Fprintf(&b, "Version: %s\n", m.Version)
	fmt.Fprintf(&b, "Architecture: %s\n", m.Arch)
	fmt.Fprintf(&b, "Maintainer: %s\n", m.Maintainer)
	fmt.Fprintf(&b, "Installed-Size: %d\n", m.InstalledKB)
	if strings.TrimSpace(m.Depends) != "" {
		fmt.Fprintf(&b, "Depends: %s\n", m.Depends)
	}
	b.WriteString("Section: net\nPriority: optional\n")
	fmt.Fprintf(&b, "Description: %s\n", m.Description)
	if strings.TrimSpace(m.Extended) != "" {
		for _, line := range strings.Split(strings.TrimSpace(m.Extended), "\n") {
			fmt.Fprintf(&b, " %s\n", strings.TrimSpace(line))
		}
	}
	return b.String()
}

func buildControlTar(control, md5sums string, epoch int64) ([]byte, error) {
	mtime := time.Unix(epoch, 0).UTC()
	var buf bytes.Buffer
	gz, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	tw := tar.NewWriter(gz)
	write := func(name, content string) error {
		hdr := &tar.Header{
			Typeflag: tar.TypeReg,
			Name:     "./" + name,
			Mode:     0o644,
			Size:     int64(len(content)),
			ModTime:  mtime,
			Uname:    "root",
			Gname:    "root",
			Format:   tar.FormatGNU,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		_, err := tw.Write([]byte(content))
		return err
	}
	if err := write("control", control); err != nil {
		return nil, err
	}
	if err := write("md5sums", md5sums); err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

type arMember struct {
	name string
	data []byte
	mode int64
}

// buildAr 生成 Debian 使用的 ar 归档：成员名不带末尾斜杠，与 dpkg-deb 一致。
func buildAr(members []arMember, epoch int64) []byte {
	var buf bytes.Buffer
	buf.WriteString("!<arch>\n")
	for _, m := range members {
		if len(m.name) > 16 {
			panic("ar 成员名超过 16 字节: " + m.name)
		}
		fmt.Fprintf(&buf, "%-16s%-12d%-6d%-6d%-8s%-10d`\n",
			m.name, epoch, 0, 0, fmt.Sprintf("%o", m.mode), len(m.data))
		buf.Write(m.data)
		if len(m.data)%2 == 1 {
			buf.WriteByte('\n')
		}
	}
	return buf.Bytes()
}
