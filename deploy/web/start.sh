#!/bin/sh
# Nexmem Web 网关本地一键启动（P6-10，Linux/macOS）
#
#   ./deploy/web/start.sh
#   NEXMEM_TLS_CERT=... NEXMEM_TLS_KEY=... ./deploy/web/start.sh
#
# 脚本会：确保令牌文件存在 -> 编译 nexmem-webd -> 按需构建 Flutter Web -> 前台启动。

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

ADDR=${ADDR:-:8082}
TOKEN_FILE=${TOKEN_FILE:-$SCRIPT_DIR/data/token}
STATIC_DIR=${STATIC_DIR:-$REPO_ROOT/app/build/web}
ORIGINS=${ORIGINS:-}
TLS_CERT=${NEXMEM_TLS_CERT:-}
TLS_KEY=${NEXMEM_TLS_KEY:-}

GO=${GO:-$REPO_ROOT/.toolchain/go/bin/go}
[ -x "$GO" ] || GO=go

FLUTTER=${FLUTTER:-$REPO_ROOT/.toolchain/flutter/bin/flutter}
[ -x "$FLUTTER" ] || FLUTTER=flutter

# 1. 令牌文件
mkdir -p "$(dirname "$TOKEN_FILE")"
if [ ! -s "$TOKEN_FILE" ]; then
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24 > "$TOKEN_FILE"
    else
        head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE"
    fi
    chmod 600 "$TOKEN_FILE"
    echo "已生成访问令牌: $TOKEN_FILE"
fi
echo "访问令牌: $(cat "$TOKEN_FILE")"

# 2. 编译网关
mkdir -p "$REPO_ROOT/bin"
BIN=$REPO_ROOT/bin/nexmem-webd
(cd "$REPO_ROOT/core" && "$GO" build -o "$BIN" ./cmd/nexmem-webd)

# 3. Flutter Web 产物
if [ ! -f "$STATIC_DIR/index.html" ]; then
    echo "构建 Flutter Web 产物 ..."
    (
      cd "$REPO_ROOT/app"
      FLUTTER_STORAGE_BASE_URL=${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn} \
        "$FLUTTER" build web --release
    )
fi

# 4. 前台启动
set -- -addr "$ADDR" -token-file "$TOKEN_FILE" -static "$STATIC_DIR"
[ -n "$ORIGINS" ] && set -- "$@" -origins "$ORIGINS"
[ -n "$TLS_CERT" ] && set -- "$@" -tls-cert "$TLS_CERT"
[ -n "$TLS_KEY" ] && set -- "$@" -tls-key "$TLS_KEY"

echo "启动: $BIN $*"
exec "$BIN" "$@"
