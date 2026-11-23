# P0 阶段构建镜像：只产出 bootstrap/relay 节点二进制
FROM golang:1.24-alpine AS build

WORKDIR /src
COPY core/ ./core/
RUN cd core && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/nexmem-bootstrap ./cmd/nexmem-bootstrap

FROM alpine:3.20
RUN adduser -D -u 10001 nexmem && mkdir -p /data && chown nexmem:nexmem /data
COPY --from=build /out/nexmem-bootstrap /usr/local/bin/nexmem-bootstrap
USER nexmem
WORKDIR /data
ENTRYPOINT ["nexmem-bootstrap"]
