# P5-03 打洞策略调优记录

> 状态：策略与默认参数已在代码中落地并完成本地可复现验证；**对称 NAT 双端可达率 ≥95% 的量化结论须在真实公网环境采集，本机不具备双公网/对称 NAT 条件（R-17）**。本文件记录可调参数、取值依据、本地验证方式与公网执行步骤，不填充未实测的数字。

## 1. 可调参数与取值依据

参数定义见 `core/internal/netnode/relay.go`（`RelayPolicy` / `RelayServicePolicy`），经 `core/internal/coreapp/app.go` 的 `relayPolicy()` 从 `core.start` 配置的 `relay_addrs` 等字段装配。

| 参数 | 默认值 | 取值依据 |
|---|---|---|
| `RelayPolicy.Enabled` | `false` | 项目默认关闭中继，仅显式开启时启用；避免默认占用公网中继资源 |
| `NumRelays` | = 候选数 | 多候选时保留全部静态中继，提高对称 NAT 下至少一条预约成功的概率 |
| `BootDelay` | `10s` | 候选不足时的等待上限，远小于验收时限 `RelayReservationDeadline=30s`，留出建链余量 |
| `Backoff` | `1m` | 单个预约失败后的退避，避免对不稳定中继高频重试 |
| `ForcePrivate` | `false` | 生产保持 false，由 AutoNAT 判定可达性；仅本地联调置 true 以强制启动预约 |
| `MaxCircuits` | libp2p 默认 16 | 单 peer 并发中继连接上限，防止单节点耗尽中继资源 |
| `MaxCircuitData` | 128KB/向 | 单条中继连接流量上限，抑制滥用 |
| `BandwidthLimit` / `BandwidthWindow` | 可配 / 1h | 单节点每窗口转发字节上限；`server/relay` 的 `Guard` 超限告警并拒绝新预约（P5-02） |
| `BandwidthWarnRatio` | `0.8` | 达到限额 80% 先告警，便于提前扩容 |

调优方向（对称 NAT 打洞失败 → 中继回退）：
1. 候选池至少配置 2 个公网可达中继（`server/relay` + 官方兜底），避免单点；
2. `NumRelays` 取候选数，确保 AutoRelay 同时向多个预约；
3. `BootDelay` 保持默认 10s，保证 30s 时限内完成首预约；
4. 带宽限额按预期并发估算，配合告警阈值提前观测。

## 2. 本地可复现验证（已执行）

`go test ./internal/netnode -run 'TestAutoRelayReservationWithinDeadline|TestRelayPolicyDefaultsDisabled|TestRelayServicePolicyDefaultsDisabled|TestRelayReservation' -count=1`：

- 默认零策略不启用任何中继选项；
- 静态候选中继在 `ForcePrivate` 下于 `RelayReservationDeadline`（30s）内完成预约；
- 预约地址含 `p2p-circuit`，`HasRelayReservation`/`WaitRelayReservation` 语义正确；
- 带宽限额用例（P5-02）验证超限告警与新预约拒绝。

`relaytest`（`go test ./server/relay ./internal/netnode -run 'Quota|Reservation|TestRelay'`）本地全绿。

## 3. 公网可达率 ≥95% 的执行步骤（待环境）

按 `docs/p0-report.md` §7 真实场景执行包：

1. 在公网机器启动 bootstrap 与 2+ 中继节点（`-relay -allow-private` 视网络而定），中继须 `ForceReachabilityPublic` 且公网可达；
2. 准备一组处于对称 NAT 后的真机/网络（公司 NAT、4G 热点等），A/B 两端仅交换账号公钥；
3. 每场景各跑 50 次 `spike-nat` 建连，记录直连/中继回退结果与 `net.holepunch` 诊断字段；
4. 汇总 `docs/p0-report.md` §5 的直连率、兜底可达率、直连/中继 P95；
5. 若兜底可达率 <95%，按第 1 节方向增补中继候选并复测。

## 4. 结论口径

- 策略代码、默认值、本地预约与限额验证：**已完成**（§13 门禁记录）。
- 对称 NAT 双端可达率 ≥95%：**待公网实测**（R-17），不得以本地环回数据替代。
