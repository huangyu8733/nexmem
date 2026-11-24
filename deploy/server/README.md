# Nexmem 服务端公网部署

本目录提供 directory / bootstrap / relay 三个服务端组件的部署方案。三者的关系见[根 README](../../README.md#公网部署服务端)；这里只讲落地步骤。

## 组件与端口

| 组件 | 二进制 | 端口 | 作用 | 是否必需 |
| --- | --- | --- | --- | --- |
| directory | `nexmem-directory` | `8081/tcp` | 账号 → 设备公钥映射、离线上传票据池 | ✅ 必需 |
| bootstrap | `nexmem-bootstrap` | `14001/tcp` + `14001/udp` | 私有 DHT 第一跳，节点互相发现的入口 | ✅ 必需 |
| relay | `nexmem-relay` | `14002/tcp` + `14002/udp` | 直连/打洞失败时的 Circuit Relay v2 兜底 | 直连失败时需要 |

关键点：

- **三者缺一不可**。只有 bootstrap 没有 directory，客户端能入 DHT 但无法按账号解析对端；只有 relay 没有前两者，双方根本找不到彼此。中继不是"连上就能让任意两人互通"的开关。
- 防火墙/安全组必须**同时放行 TCP 和 UDP**（QUIC 走 UDP）。
- `-announce` 必须是**服务器真实公网 IP + 对外端口**，写 `127.0.0.1` 或容器内网地址会导致其他节点拿到无法拨号的地址。
- relay 只转发加密字节并做带宽计数，**不解密、不落盘任何消息**，因此多个 relay 之间没有任何同步接口，也不需要同步。

## 一、Docker Compose（推荐，三平台通用）

需要 Docker 与 Compose 插件。仓库自带三个 Dockerfile，无需本地 Go 环境。

```bash
cp deploy/.env.example deploy/.env
# 编辑 deploy/.env：把 NEXMEM_PUBLIC_IP 改成服务器真实公网 IP

docker compose -f deploy/docker-compose.yml up -d --build
docker compose -f deploy/docker-compose.yml ps
docker compose -f deploy/docker-compose.yml logs bootstrap
```

`bootstrap` / `relay` 启动日志的 stdout 是一行 JSON，其中的 `peer_id` 就是构造多地址要用的 PeerID。

常用的 compose 命令：

```bash
docker compose -f deploy/docker-compose.yml logs -f relay
docker compose -f deploy/docker-compose.yml restart directory
docker compose -f deploy/docker-compose.yml down          # 数据保留在 named volume
docker compose -f deploy/docker-compose.yml down -v       # 连同数据库与节点私钥一起删除
```

## 二、原生部署

一键脚本会编译三个二进制到 `bin/`，并用环境变量注入公网 IP：

```bash
export NEXMEM_PUBLIC_IP=1.2.3.4
./deploy/server/start.sh build     # 只编译
./deploy/server/start.sh all       # directory/relay 后台，bootstrap 前台
```

也可以单独前台运行某个组件：`./deploy/server/start.sh directory`、`bootstrap`、`relay`。macOS 直接使用同一脚本。

Windows（PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File deploy/server/start.ps1 -PublicIp 1.2.3.4
powershell -ExecutionPolicy Bypass -File deploy/server/start.ps1 -Component directory
```

### Linux 开机自启（systemd）

```bash
sudo useradd -r -s /usr/sbin/nologin nexmem
sudo mkdir -p /opt/nexmem/bin /var/lib/nexmem /etc/nexmem
sudo cp bin/nexmem-* /opt/nexmem/bin/
sudo cp deploy/server/systemd/*.service /etc/systemd/system/
sudo chown -R nexmem:nexmem /var/lib/nexmem

# 写入公网 IP
echo 'NEXMEM_PUBLIC_IP=1.2.3.4' | sudo tee /etc/nexmem/server.env

sudo systemctl daemon-reload
sudo systemctl enable --now nexmem-directory nexmem-bootstrap nexmem-relay
sudo systemctl status nexmem-relay
```

如需改端口或带宽限额，直接编辑对应 unit 文件中的 `-listen` / `-announce` / `-bandwidth` / `-window`，然后 `systemctl daemon-reload && systemctl restart nexmem-*`。

### macOS 开机自启

用 `launchd` 的 `launchctl load` + plist，或直接让 `start.sh all` 在终端后台常驻。项目未提供现成 plist。

## 三、构造引导地址并配置客户端

在 bootstrap 日志中拿到 PeerID（以 `12D3Koo...` 开头），拼成：

```
/ip4/1.2.3.4/tcp/14001/p2p/12D3KooWxxxxxxxxxxxxxxxx
```

relay 同理，用 relay 日志的 PeerID 与 14002 端口。

### 桌面端（Windows / macOS / Linux）

两种任选其一：

1. **设置页**：打开「设置 → 网络 → 中继设置」，开启中继并填写完整的 relay 多地址（含 `/p2p/<PeerID>`），重启应用。地址由 Go 内核在下次 `core.start` 时从 KV 读取。
2. **构建/启动时注入**（适合统一部署）：

```bash
NEXMEM_BOOTSTRAPS='/ip4/1.2.3.4/tcp/14001/p2p/12D3Koo...' \
NEXMEM_DIRECTORY_URL='http://1.2.3.4:8081' \
NEXMEM_RELAY_ADDRS='/ip4/1.2.3.4/tcp/14002/p2p/12D3Koo...' \
  ./your-nexmem-app
```

### Android

移动端没有设置页的中继入口（配置在编译时注入），需要带 dart-define 重新构建 APK：

```powershell
flutter build apk --release `
  --dart-define=NEXMEM_BOOTSTRAPS=/ip4/1.2.3.4/tcp/14001/p2p/12D3Koo... `
  --dart-define=NEXMEM_DIRECTORY_URL=http://1.2.3.4:8081 `
  --dart-define=NEXMEM_RELAY_ADDRS=/ip4/1.2.3.4/tcp/14002/p2p/12D3Koo...
```

> Git Bash 会把 `/ip4/...` 误转换成 Windows 路径，Android 构建请用 PowerShell 或设置 `MSYS_NO_PATHCONV=1`。

### Web

浏览器端内核跑在网关上，不能使用设置页的中继配置（那只写进浏览器本地 KV）。请在 webd 启动时注入：

```bash
NEXMEM_DATA_DIR=/srv/nexmem/data \
NEXMEM_BOOTSTRAPS='/ip4/1.2.3.4/tcp/14001/p2p/12D3Koo...' \
NEXMEM_DIRECTORY_URL='http://1.2.3.4:8081' \
NEXMEM_RELAY_ADDRS='/ip4/1.2.3.4/tcp/14002/p2p/12D3Koo...' \
  ./bin/nexmem-webd -token-file ./deploy/web/data/token
```

Docker 场景把上述变量写进 `deploy/web/.env`，`deploy/web/docker-compose.yml` 会自动透传。详细 Web 网关部署见 [deploy/web/README.md](../web/README.md)。

## 四、多个中继器节点

relay 之间**没有连接、没有状态、没有同步接口**。让分处不同网络的用户互通靠两点：

1. 共享同一套 bootstrap 与 directory（地址/账号能解析到同一张网络）；
2. 所有客户端配置**同一份 relay 地址列表**（建议 2~3 个公网节点），每个客户端会同时向列表里的中继预约，天然形成交集。多个地址用逗号分隔：

```
NEXMEM_RELAY_ADDRS=/ip4/1.1.1.1/tcp/14002/p2p/12D3KooA...,/ip4/2.2.2.2/tcp/14002/p2p/12D3KooB...
```

部署第二个 relay 时，换一台服务器、换一个 `-id` 密钥文件即可，不需要把它"注册"到第一个 relay。

## 五、验证

1. `curl http://<服务器IP>:8081/` 返回非连接拒绝（directory 未注册根路径，404 属正常）。
2. 客户端设置 → 网络诊断：能看到 DHT 入网、目录服务可达。
3. 加好友后发消息：连接状态在直连失败时显示"经中继"，打洞成功后自动升级为直连。
4. `docker compose logs relay` 无 `RELAY_QUOTA_ALERT`；出现该日志说明带宽超限，需调大 `-bandwidth`。

## 六、常见问题

- **客户端显示 `PEER_UNREACHABLE`**：多半是 bootstrap / directory 没注入，或双方指向了不同实例。检查客户端启动配置。
- **relay 配了但没生效**：relay 在 host 创建时装配，改完必须重启应用；Web 则是重启 webd。
- **连上中继但一直不升级直连**：双方 NAT 类型都可能是对称 NAT，DCUtR 打洞失败，此时会保持中继转发，消息仍是端到端加密的。
- **容器日志显示地址不可达**：检查 `-announce` 是否写了公网 IP 与映射端口，以及云安全组的 UDP 规则。
