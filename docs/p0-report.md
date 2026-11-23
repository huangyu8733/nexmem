# P0 连通性验证报告（阶段版）

> 状态：进行中。本地链路已跑通，真实网络四场景尚未测量，**不构成 Go/No-Go 结论**。
> 更新：2026-11-18

## 1. 环境

| 项 | 值 |
|---|---|
| OS | Windows（本机） |
| Go | 1.27.4（便携版解压在 `.toolchain/`，未写入系统 PATH） |
| go-libp2p | v0.52.0 |
| kad-dht | v0.43.0 |
| 传输 | TCP + QUIC v1 |
| 加密 | Noise（libp2p 默认） |
| DHT 协议前缀 | `/nexmem`（私有网络） |

## 2. 代码位置

| 组件 | 路径 |
|---|---|
| host 构造（NAT/打洞/Relay 开关） | `core/internal/netnode/host.go` |
| 私有 DHT | `core/internal/netnode/dht.go` |
| 连接性质判定（直连/中继） | `core/internal/netnode/conninfo.go` |
| 回显协议与帧 | `core/internal/spike/frame.go` |
| CSV 指标 | `core/internal/metrics/csv.go` |
| bootstrap / relay 节点 | `core/cmd/nexmem-bootstrap` |
| 双节点测量工具 | `core/cmd/spike-nat` |
| 本地场景脚本 | `tools/p0/run-local.ps1` |
| 容器编排 | `deploy/docker-compose.yml` |

P0 阶段三个二进制暂放在 `core/cmd/`，P1 起再按方案拆到 `server/*` 独立模块，避免早期多 module 的 `replace` 开销。

## 3. 验证方法

```powershell
# 直连（DHT 寻址）
pwsh -File tools/p0/run-local.ps1 -Iter 5

# 中继兜底（同一节点同时提供 DHT + Relay）
pwsh -File tools/p0/run-local.ps1 -Iter 5 -Relay
```

判定口径：

- `direct`：存在一条非 Limited、地址中不含 `p2p-circuit` 的连接。
- `relayed`：连接被标记为 Limited 或地址包含 `p2p-circuit`。
- `rtt_ms`：在已建立的点对点流上做一次「发帧-收帧」往返。
- `connect_ms`：从 `Connect` 调用到返回的耗时（不含 DHT 寻址）。

## 4. 本地结果（非门禁）

| 场景 | 样本 | 成功 | 直连 | 中继 | 说明 |
|---|---|---|---|---|---|
| local（DHT） | 9 | 8 | 8 | 0 | 首次冷查询失败 1 次，已加重试修复 |
| local-relay（circuit） | 5 | 5 | 1 | 4 | 中继连通 4/4；1 次因 peerstore 已有直连地址而走 QUIC |

补充：

- 本地 `connect_ms` 为 0–4ms，`rtt_ms` 为 0ms，全部为环回地址，**不能用于评估真实网络性能**。
- 中继连接首版无法开流，原因是 Limited 连接默认禁止开流；修复方式为 `network.WithAllowLimitedConn`。
- 中继服务在 libp2p v0.52 中仅在节点宣告 `ReachabilityPublic` 时启动，需 `libp2p.ForceReachabilityPublic()`；本地另需放开预约地址过滤。

## 5. 待完成（门禁必需）

| 编号 | 项 | 状态 |
|---|---|---|
| P0-05 | 同 LAN / 家宽 / 公司 NAT / 4G 四场景各 ≥50 样本 | 待测 |
| P0-06 | 对称 NAT 下打洞失败 → 中继回退时延 | 待测 |
| P0-07 | 直连率、兜底可达率、P95 建连时延汇总 | 待数据 |
| P0-08 | 门禁评审 | 未开始 |

## 6. 已识别风险

1. 真实环境的打洞成败取决于运营商 NAT 类型，本地结果无参考价值。
2. 中继节点需公网可达 + `ForceReachabilityPublic`，生产部署必须固定公网地址并做带宽限额。
3. Windows 本机 4001 端口可能被其他应用（如 QQ）占用，脚本已改用 14001/14002。
4. 本机未安装 Docker，`deploy/docker-compose.yml` 尚未实机验证。

## 7. 真实场景执行包

### 7.1 准备

- 一台有公网 IP 的机器（云主机，放行 TCP/UDP 14001、14002）。
- 两台被测设备：家宽 / 公司网络 / 4G 热点。
- 把 `bin/` 下两个二进制拷到各机器（或各自 `make build`）。

### 7.2 启动 bootstrap（公网机器）

```powershell
bin\nexmem-bootstrap.exe `
  -listen "/ip4/0.0.0.0/tcp/14001,/ip4/0.0.0.0/udp/14001/quic-v1" `
  -announce "/ip4/<公网IP>/tcp/14001,/ip4/<公网IP>/udp/14001/quic-v1" `
  -id data/bootstrap.key
```

输出中 `addrs` 即为其他节点的 `-bootstrap` 值。

需要同时验证中继时追加 `-relay -allow-private`，并另起一个端口为 14002 的节点。

### 7.3 跑场景

```powershell
# A 机（echo）
pwsh -File tools/p0/run-scenario.ps1 -Role echo `
  -Bootstrap /ip4/<公网IP>/tcp/14001/p2p/<bootstrapID>

# B 机（dial），记录 A 机输出的 PeerID
pwsh -File tools/p0/run-scenario.ps1 -Role dial `
  -Bootstrap /ip4/<公网IP>/tcp/14001/p2p/<bootstrapID> `
  -Peer <echoPeerID> -Scenario home -Iter 50
```

四个场景各跑 50 次，`-Scenario` 分别取 `lan`、`home`、`office`、`lte`。

### 7.4 汇总

```powershell
pwsh -File tools/p0/summarize.ps1 `
  -Paths data\p0\lan.csv,data\p0\home.csv,data\p0\office.csv,data\p0\lte.csv `
  -Out data\p0\summary.md
```

输出直连率、兜底可达率、中继占比、直连/中继 P95，并对照门禁阈值。
