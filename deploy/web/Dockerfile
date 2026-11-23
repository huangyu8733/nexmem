# Nexmem 自托管 Web 网关镜像（P6-10）
#
# 构建上下文必须是仓库根目录：
#   docker build -f deploy/web/Dockerfile -t nexmem-webd .
#
# 镜像内含 nexmem-webd 与 Flutter Web 静态产物（需先执行 make webdist）。

FROM golang:1.26-alpine AS build

WORKDIR /src
COPY core/go.mod core/go.sum ./core/
RUN cd core && go mod download

COPY core/ ./core/
RUN cd core && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
        -o /out/nexmem-webd ./cmd/nexmem-webd

FROM alpine:3.20

RUN adduser -D -u 10001 nexmem \
    && mkdir -p /srv/nexmem/static /srv/nexmem/data \
    && chown -R nexmem:nexmem /srv/nexmem

COPY --from=build /out/nexmem-webd /usr/local/bin/nexmem-webd
COPY app/build/web/ /srv/nexmem/static/

USER nexmem
WORKDIR /srv/nexmem

# 访问令牌由 docker secret 或只读挂载提供，不打进镜像层。
ENV NEXMEM_WEB_ADDR=:8082 \
    NEXMEM_WEB_STATIC=/srv/nexmem/static \
    NEXMEM_WEB_TOKEN_FILE=/run/secrets/web_token

EXPOSE 8082

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8082/healthz >/dev/null 2>&1 || exit 1

ENTRYPOINT ["nexmem-webd"]
