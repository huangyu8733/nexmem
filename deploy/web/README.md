# Nexmem Web 自托管部署（P6-10）

浏览器端不承载内核：`nexmem-webd` 在用户自有服务器运行完整内核（DHT、打洞、对象存储），
同时托管 Flutter Web 构建产物，浏览器只通过 WebSocket 收发 `Request/Response/Event`。
架构约束见 [Nexmem-engineering-plan.md](../../docs/Nexmem-engineering-plan.md) §6.1。

## 前置：生成 Web 产物

```bash
make webdist            # 等价于 cd app && flutter build web --release
```

产物位于 `app/build/web/`，镜像构建与本地启动脚本都会复用它。

## 方式一：Docker Compose + Caddy（推荐，一条命令）

```bash
cp deploy/web/.env.example deploy/web/.env      # 修改 NEXMEM_DOMAIN
mkdir -p deploy/web/data
docker compose -f deploy/web/docker-compose.yml up -d --build
```

- `webd` 容器只监听内网 `8082`，不直接暴露到公网。
- `caddy` 容器负责 80/443、自动申请并续期 TLS 证书，并透传 WebSocket。
- 访问令牌由 `deploy/web/data/token` 只读挂载到容器内，不打进镜像层。

首次启动前若缺少令牌文件，先生成一个：

```bash
powershell -ExecutionPolicy Bypass -File deploy/web/rotate-token.ps1   # Windows
# Linux/macOS: openssl rand -hex 24 > deploy/web/data/token && chmod 600 deploy/web/data/token
```

## 方式二：Nginx 反代

1. 在本机运行网关，只绑回环地址：

   ```bash
   ./bin/nexmem-webd -addr 127.0.0.1:8082 \
       -token-file /etc/nexmem/token \
       -static /srv/nexmem/static \
       -origins https://chat.example.com
   ```

2. 将 [nginx.conf](nginx.conf) 放入 `/etc/nginx/conf.d/nexmem.conf`，替换域名与证书路径。
   关键点：`Upgrade`/`Connection` 头透传、`proxy_read_timeout` 放大、`client_max_body_size 1m`、
   `/healthz` 不鉴权。

## 方式三：本地一键启动（无 Docker）

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File deploy/web/start.ps1
```

```bash
# Linux/macOS
./deploy/web/start.sh
```

脚本自动生成令牌文件、编译 `bin/nexmem-webd`、按需执行 `flutter build web`，然后前台启动。

## 内置 TLS

网关自身可终结 TLS，适合没有反代的单机部署：

```bash
./bin/nexmem-webd -addr :8443 -token-file ./deploy/web/data/token \
    -static ./app/build/web -tls-cert ./deploy/web/data/cert.pem -tls-key ./deploy/web/data/key.pem
```

生产环境仍建议使用 Caddy/Nginx 终结 TLS，便于统一做证书续期与访问日志。

## 令牌轮换

令牌文件变化后网关在 2s 内自动重新加载：

- 新连接必须使用新令牌；
- 已建立的连接会被立即断开，浏览器需要重新握手（旧令牌视同撤销）。

```bash
powershell -ExecutionPolicy Bypass -File deploy/web/rotate-token.ps1
```

`-token-file` 优先于 `-token`；两者都未提供时网关启动会拒绝（随机令牌仅用于临时调试）。

## 上线自检清单

| 检查项 | 期望结果 |
|---|---|
| `curl -fsS https://<域名>/healthz` | `{"status":"ok"}` |
| `curl -s -o /dev/null -w '%{http_code}' https://<域名>/ws` | `401`（无令牌被拒） |
| 浏览器用 `?token=<令牌>` 连接 | 页面加载、`core.ping` 返回 `{"pong":true}` |
| 修改令牌文件后 2s | 旧连接断开，旧令牌握手 401，新令牌可用 |
| 关闭浏览器标签再打开 | 按 `since` 重放事件；缺口时收到 `resync_required` |

## 注意事项

- 单实例单账号：一个 `nexmem-webd` 只服务一个账号，不要多账号共用。
- 必须启用 TLS（内置或反代）；纯 HTTP 会把访问令牌暴露在链路上。
- 浏览器关闭后没有实时通道，消息依赖 P3 离线闭环在下次打开时补齐。
- 网关只暴露 `/ws`、`/healthz` 与静态资源，内核端口不要对外映射。
