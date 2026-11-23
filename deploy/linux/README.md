# Linux 打包（P6-09）

在 **Ubuntu 22.04 x86-64** 上把 `libnexmem.so`（Go c-shared 内核）与 Flutter Linux 产物
封装为 `.deb`，检测到 `appimagetool` 时另出 AppImage。

## 1. 构建环境

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libgtk-3-0 libblkid1 liblzma5 libstdc++6
```

- Go 1.27（可用仓库内 `.toolchain/go`，确保 `PATH` 可找到 `go`）
- Flutter 3.50+（`flutter doctor` 的 Linux toolchain 必须为绿）

## 2. 构建

```bash
bash deploy/linux/build-linux.sh
```

脚本依次执行：

1. `CGO_ENABLED=1 go -C core build -buildmode=c-shared -o ../bin/libnexmem.so ./ffi/capi`
2. 在 `app/` 目录执行 `flutter build linux --release`
3. 暂存包根 `dist/debroot`：
   - `/opt/nexmem/`：完整 Flutter bundle + `libnexmem.so`（与 `nexmem_app` 同目录，供 `dart:ffi` 按 `resolvedExecutable` 加载）
   - `/usr/bin/nexmem` → `/opt/nexmem/nexmem_app`
   - `/usr/share/applications/io.nexmem.nexmem_app.desktop`
   - `/usr/share/icons/hicolor/scalable/apps/io.nexmem.nexmem_app.svg`
4. `go -C core run ./cmd/nexmem-debpack` 生成 `dist/nexmem_<version>_amd64.deb`
   （纯标准库实现 ar + control.tar.gz + data.tar.gz，输出可重复，不依赖 `dpkg-deb`）

产物：

```
dist/nexmem_1.0.0_amd64.deb
dist/nexmem-1.0.0-x86_64.AppImage   # 仅当存在 appimagetool
```

## 3. 安装与验收

```bash
sudo apt install ./dist/nexmem_1.0.0_amd64.deb
nexmem          # 或从应用菜单启动
```

验收清单（对应 P6-09 验收标准）：

1. 应用启动后 `~/.local/share/nexmem/` 生成 `nexmem.db`、`account.sealed`、
   `device.key`、`keystore.master`、`event_seq`；
2. 两台设备（或 Ubuntu + Windows 桌面）互加好友后单聊文本双向可达；
3. 发送文件、切换会话、重启后历史仍在；
4. `dpkg -L nexmem` 列出完整文件清单，`dpkg -s nexmem` 的 `Depends` 覆盖运行时库。

依赖说明：Flutter Linux 桌面运行需要 GTK3 运行库（`libgtk-3-0`）与 `libblkid1` /
`liblzma5` / `libstdc++6`，`nexmem-debpack` 的默认 `Depends` 已包含。

## 4. 已知限制

- 本机（Windows）只能交叉编译 `.so`，`flutter build linux` 与安装验收需 Ubuntu 宿主，
  见开发进度文档 §12 R-19；在宿主就绪前 P6-09 保持「进行中」。
- AppImage 需要 `appimagetool`（`sudo apt install appimagetool` 或从 AppImageKit 发布页下载）；
  缺失时脚本输出 `APPIMAGE_SKIPPED=no-appimagetool` 并只产出 `.deb`。
- 桌面图标缓存由 `dpkg` 触发；若菜单未刷新，执行 `update-desktop-database ~/.local/share/applications`。
