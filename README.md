# Nexmem（奈讯联）

去中心化 P2P 即时通讯应用。端到端加密、无中心服务器、跨平台（Windows / macOS / Linux / Android / Web）。

## 下载安装（推荐）

前往 [GitHub Releases 最新版](https://github.com/huangyu8733/nexmem/releases/latest) 下载对应平台的安装包：

| 平台 | 资产文件 | 说明 |
| --- | --- | --- |
| Windows x64 | `Nexmem-*-windows-x64.zip` | 解压即用，附带 `install.ps1` / `uninstall.ps1` |
| macOS arm64 (Apple Silicon) | `Nexmem-*-macos-arm64.zip` | 解压后拖入「应用程序」 |
| Linux x64 | `Nexmem-*-linux-x64.deb` 或 `.tar.gz` | Debian/Ubuntu 用 `.deb`，其他发行版用 tarball |
| Android | `Nexmem-*-android.apk` | 允许“安装未知来源应用”后安装 |
| Web | `Nexmem-*-web.zip` | 静态站点，解压后用任意 Web 服务器托管 |

📖 各平台详细步骤、首次配置、FAQ 见 **[安装与使用教程](docs/安装与使用教程.md)**。

> 桌面安装包已内置 Go 内核动态库（`nexmem.dll` / `libnexmem.so` / `libnexmem.dylib`）。请保持压缩包内的目录结构，不要只复制主程序。

## 功能概览

- 端到端加密的单聊与群聊，离线消息与跨设备同步
- 好友 / 群组 / 设备管理，二维码分享账号
- 个人资料：昵称、介绍、推广图、头像（支持裁剪），账号与设备 ID 完整显示和复制
- 文件传输、群云盘、加密备份与恢复
- 33 种界面语言，含 RTL（阿拉伯语、希伯来语）布局适配
- Web 端通过网关接入，桌面端直连 P2P

## 从源码构建

需要 Go 1.26+、Flutter 3.50+（Android 还需 JDK 17 与 Android SDK/NDK）。

```bash
# 桌面 Windows（PowerShell）
powershell -ExecutionPolicy Bypass -File deploy/desktop/build-windows.ps1

# 桌面 Linux（Ubuntu 需先安装 GTK3 等依赖）
bash deploy/linux/build-linux.sh

# Android（先生成 Go 内核 AAR）
make android-aar
cd app && flutter build apk --release

# Web
cd app && flutter build web --release
```

测试：`cd app && flutter test`，Go 侧：`make test`。

## 自动发布

推送 `v*` 标签即触发 [Release 工作流](.github/workflows/release.yml)：云端并行构建 Windows / Linux / macOS / Android / Web，自动创建 GitHub Release 并上传安装包。

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 文档

- [安装与使用教程](docs/安装与使用教程.md)
- [开发进度文档](docs/开发进度文档.md)
- [剩余开发进度](docs/剩余开发进度.md)
- [UI 规范](docs/ui-spec.md)
- [工程方案](docs/Nexmem-engineering-plan.md)

内部包名 `nexmem_app` 仅用于构建与部署脚本；产品显示名为 **Nexmem / 奈讯联**。
