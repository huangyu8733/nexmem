#!/bin/sh
# Nexmem 服务端原生一键启动（Linux / macOS）
#
#   ./deploy/server/start.sh build                 # 只编译三个二进制到 bin/
#   ./deploy/server/start.sh all                   # 编译后启动全部（directory/relay 后台，bootstrap 前台）
#   ./deploy/server/start.sh directory|bootstrap|relay   # 单独前台启动某组件
#
# 环境变量：
#   NEXMEM_PUBLIC_IP          服务器真实公网 IP（bootstrap/relay 必填）
#   NEXMEM_DATA_DIR           数据目录，默认 <repo>/data/server
#   NEXMEM_BOOTSTRAP_PORT     默认 14001（tcp+udp）
#   NEXMEM_RELAY_PORT         默认 14002（tcp+udp）
#   NEXMEM_DIRECTORY_PORT     默认 8081（tcp）
#   NEXMEM_RELAY_BANDWIDTH    默认 1073741824（1 GiB/窗口，<=0 不限）
#   NEXMEM_RELAY_WINDOW       默认 1h

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
BIN_DIR=${NEXMEM_BIN_DIR:-$REPO_ROOT/bin}
DATA_DIR=${NEXMEM_DATA_DIR:-$REPO_ROOT/data/server}
PUBLIC_IP=${NEXMEM_PUBLIC_IP:-}
BOOT_PORT=${NEXMEM_BOOTSTRAP_PORT:-14001}
RELAY_PORT=${NEXMEM_RELAY_PORT:-14002}
DIR_PORT=${NEXMEM_DIRECTORY_PORT:-8081}
BANDWIDTH=${NEXMEM_RELAY_BANDWIDTH:-1073741824}
WINDOW=${NEXMEM_RELAY_WINDOW:-1h}

GO=${GO:-$REPO_ROOT/.toolchain/go/bin/go}
[ -x "$GO" ] || GO=go

BIN_DIRECTORY="$BIN_DIR/nexmem-directory"
BIN_BOOTSTRAP="$BIN_DIR/nexmem-bootstrap"
BIN_RELAY="$BIN_DIR/nexmem-relay"

build_all() {
    mkdir -p "$BIN_DIR"
    echo "编译服务端二进制到 $BIN_DIR ..."
    (cd "$REPO_ROOT/core" && "$GO" build -o "$BIN_DIRECTORY" ./cmd/nexmem-directory)
    (cd "$REPO_ROOT/core" && "$GO" build -o "$BIN_BOOTSTRAP" ./cmd/nexmem-bootstrap)
    (cd "$REPO_ROOT/core" && "$GO" build -o "$BIN_RELAY" ./cmd/nexmem-relay)
}

ensure_built() {
    if [ ! -x "$BIN_DIRECTORY" ] || [ ! -x "$BIN_BOOTSTRAP" ] || [ ! -x "$BIN_RELAY" ]; then
        build_all
    fi
}

require_public_ip() {
    if [ -z "$PUBLIC_IP" ]; then
        echo "错误：请先设置 NEXMEM_PUBLIC_IP 为服务器真实公网 IP" >&2
        exit 1
    fi
}

run_directory() {
    mkdir -p "$DATA_DIR"
    exec "$BIN_DIRECTORY" -addr ":$DIR_PORT" -db "$DATA_DIR/directory.db"
}

run_bootstrap() {
    require_public_ip
    mkdir -p "$DATA_DIR"
    exec "$BIN_BOOTSTRAP" \
        -listen "/ip4/0.0.0.0/tcp/$BOOT_PORT,/ip4/0.0.0.0/udp/$BOOT_PORT/quic-v1" \
        -announce "/ip4/$PUBLIC_IP/tcp/$BOOT_PORT,/ip4/$PUBLIC_IP/udp/$BOOT_PORT/quic-v1" \
        -id "$DATA_DIR/bootstrap.key"
}

run_relay() {
    require_public_ip
    mkdir -p "$DATA_DIR"
    exec "$BIN_RELAY" \
        -listen "/ip4/0.0.0.0/tcp/$RELAY_PORT,/ip4/0.0.0.0/udp/$RELAY_PORT/quic-v1" \
        -announce "/ip4/$PUBLIC_IP/tcp/$RELAY_PORT,/ip4/$PUBLIC_IP/udp/$RELAY_PORT/quic-v1" \
        -id "$DATA_DIR/relay.key" \
        -bandwidth "$BANDWIDTH" -window "$WINDOW"
}

start_all() {
    ensure_built
    require_public_ip
    mkdir -p "$DATA_DIR"
    "$0" directory > "$DATA_DIR/directory.log" 2>&1 &
    dir_pid=$!
    "$0" relay > "$DATA_DIR/relay.log" 2>&1 &
    relay_pid=$!
    trap 'kill "$dir_pid" "$relay_pid" 2>/dev/null || true' EXIT INT TERM
    echo "directory pid=$dir_pid, relay pid=$relay_pid"
    echo "日志：$DATA_DIR/directory.log、$DATA_DIR/relay.log"
    echo "bootstrap 在前台运行，Ctrl+C 会一并停止全部组件"
    "$0" bootstrap
}

component=${1:-all}
case "$component" in
    build) build_all ;;
    all) start_all ;;
    directory|bootstrap|relay)
        ensure_built
        case "$component" in
            directory) run_directory ;;
            bootstrap) run_bootstrap ;;
            relay) run_relay ;;
        esac
        ;;
    *)
        echo "用法：$0 {build|all|directory|bootstrap|relay}" >&2
        exit 2
        ;;
esac
