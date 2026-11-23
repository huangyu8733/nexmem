#!/usr/bin/env bash
# P6-09：构建 Linux x86-64 发行包（.deb，检测到 appimagetool 时另出 AppImage）。
#
# 需在 Linux 宿主执行（Flutter 的 Linux 桌面产物只能在 Linux 上编译）：
#   bash deploy/linux/build-linux.sh
#
# 可用环境变量覆盖：GO、FLUTTER、VERSION、ARCH、OUT。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

GO="${GO:-go}"
FLUTTER="${FLUTTER:-flutter}"
VERSION="${VERSION:-$(sed -n 's/^version:[[:space:]]*\([0-9][^+]*\).*/\1/p' app/pubspec.yaml | head -n1)}"
ARCH="${ARCH:-amd64}"
OUT="${OUT:-$ROOT/dist}"
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
PKG_ROOT="$OUT/debroot"
APP_DIR="$PKG_ROOT/opt/nexmem"
DEB="$OUT/nexmem_${VERSION}_${ARCH}.deb"

if [ -z "$VERSION" ]; then
  echo "无法从 app/pubspec.yaml 解析版本号，请用 VERSION= 指定" >&2
  exit 1
fi

echo "LINUX_DIST_VERSION=$VERSION"
echo "LINUX_DIST_ARCH=$ARCH"

# 1. 内核 c-shared（Linux 本机编译，需 gcc；产物放在可执行文件同目录供 dart:ffi 加载）
echo "==> 构建 libnexmem.so"
CGO_ENABLED=1 "$GO" -C core build -buildmode=c-shared -o ../bin/libnexmem.so ./ffi/capi

# 2. Flutter Linux 产物
echo "==> 构建 Flutter Linux 产物"
(cd app && "$FLUTTER" build linux --release)

if [ ! -x "$BUNDLE/nexmem_app" ]; then
  echo "缺少 $BUNDLE/nexmem_app，Flutter 构建可能失败" >&2
  exit 1
fi

# 3. 暂存包根：/opt/nexmem 放完整 bundle 与内核 .so，/usr/bin/nexmem 软链入口
echo "==> 暂存 $PKG_ROOT"
rm -rf "$PKG_ROOT"
mkdir -p "$APP_DIR" \
  "$PKG_ROOT/usr/bin" \
  "$PKG_ROOT/usr/share/applications" \
  "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps"
cp -a "$BUNDLE/." "$APP_DIR/"
cp "$ROOT/bin/libnexmem.so" "$APP_DIR/libnexmem.so"
ln -sf /opt/nexmem/nexmem_app "$PKG_ROOT/usr/bin/nexmem"
install -m 0644 deploy/linux/io.nexmem.nexmem_app.desktop \
  "$PKG_ROOT/usr/share/applications/"
install -m 0644 deploy/linux/io.nexmem.nexmem_app.svg \
  "$PKG_ROOT/usr/share/icons/hicolor/scalable/apps/"

# 4. .deb：用 nexmem-debpack 生成确定性的 ar/control/data 结构，不依赖 dpkg-deb
echo "==> 打包 .deb"
"$GO" -C core run ./cmd/nexmem-debpack \
  -root "$PKG_ROOT" \
  -out "$DEB" \
  -package nexmem \
  -version "$VERSION" \
  -arch "$ARCH"

# 5. AppImage（可选）
if command -v appimagetool >/dev/null 2>&1; then
  echo "==> 打包 AppImage"
  APPDIR="$OUT/nexmem.AppDir"
  rm -rf "$APPDIR"
  mkdir -p "$APPDIR"
  cp -a "$BUNDLE/." "$APPDIR/"
  cp "$ROOT/bin/libnexmem.so" "$APPDIR/libnexmem.so"
  install -m 0644 deploy/linux/io.nexmem.nexmem_app.desktop "$APPDIR/nexmem.desktop"
  install -m 0644 deploy/linux/io.nexmem.nexmem_app.svg "$APPDIR/nexmem.svg"
  cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE:${LD_LIBRARY_PATH:-}"
exec "$HERE/nexmem_app" "$@"
EOF
  chmod 0755 "$APPDIR/AppRun"
  ARCH=x86_64 appimagetool "$APPDIR" "$OUT/nexmem-${VERSION}-x86_64.AppImage"
  echo "APPIMAGE=$OUT/nexmem-${VERSION}-x86_64.AppImage"
else
  echo "APPIMAGE_SKIPPED=no-appimagetool"
fi

echo "DEB=$DEB"
echo "DEB_SIZE_BYTES=$(stat -c%s "$DEB")"
echo "RESULT=PASS"
