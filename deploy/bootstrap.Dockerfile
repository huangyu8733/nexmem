# 服务端基础镜像：产出 bootstrap 与 relay 两个节点二进制
#
# bootstrap：私有 DHT 入口（-dht=true 默认）
# relay：独立 Circuit Relay v2 节点（支持 -bandwidth / -window 限额）
FROM golang:1.26-alpine AS build

WORKDIR /src
COPY core/ ./core/
RUN cd core \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/nexmem-bootstrap ./cmd/nexmem-bootstrap \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/nexmem-relay ./cmd/nexmem-relay

FROM alpine:3.20
RUN adduser -D -u 10001 nexmem && mkdir -p /data && chown nexmem:nexmem /data
COPY --from=build /out/nexmem-bootstrap /usr/local/bin/nexmem-bootstrap
COPY --from=build /out/nexmem-relay /usr/local/bin/nexmem-relay
USER nexmem
WORKDIR /data
ENTRYPOINT ["nexmem-bootstrap"]
