# Nexmem（奈讯联）客户端

Flutter 客户端，支持 Windows / macOS / Linux / Android / Web。端到端加密、去中心化 P2P 即时通讯。

预编译安装包请到 [GitHub Releases](https://github.com/huangyu8733/nexmem/releases/latest) 下载，安装教程见 [docs/安装与使用教程.md](../docs/安装与使用教程.md)。

## 本地开发

需要 Flutter 3.50+（本仓库自带 `.toolchain/flutter`）。桌面端还需先构建 Go 内核动态库：

```bash
# Windows
powershell -ExecutionPolicy Bypass -File deploy/desktop/build-windows.ps1

# Linux
bash deploy/linux/build-linux.sh

# Web
flutter build web --release
```

Android 先执行 `make android-aar` 生成 `app/android/app/libs/nexmem.aar`，再执行 `flutter build apk --release`。

测试：`flutter analyze && flutter test`。
