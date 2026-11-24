# Nexmem 索引服务（directory）镜像
#
# 构建上下文必须是仓库根目录：
#   docker build -f deploy/directory.Dockerfile -t nexmem-directory .
#
# 默认监听 :8081，SQLite 数据库落在 /data/directory.db（volume 持久化）。

FROM golang:1.26-alpine AS build

WORKDIR /src
COPY core/ ./core/
RUN cd core && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
        -o /out/nexmem-directory ./cmd/nexmem-directory

FROM alpine:3.20
RUN adduser -D -u 10001 nexmem \
    && mkdir -p /data \
    && chown nexmem:nexmem /data
COPY --from=build /out/nexmem-directory /usr/local/bin/nexmem-directory
USER nexmem
WORKDIR /data

EXPOSE 8081

# 目录服务未提供 /healthz，用 TCP 探测端口即可（不依赖 nc -z，兼容 BusyBox）。
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD nc -w 2 127.0.0.1 8081 </dev/null >/dev/null 2>&1 || exit 1

ENTRYPOINT ["nexmem-directory"]
