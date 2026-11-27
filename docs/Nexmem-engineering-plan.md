# Nexmem 工程实施方案（Go 核心 + Flutter 全端）

> 本方案是原始设计文档的可执行版本，已修正原方案中 6 处架构级矛盾。
> 技术基线：Go 1.x 核心（go-libp2p）+ gomobile 绑定 + Flutter 全端 UI。

---

## 0. 决策基线

| 项目 | 决策 | 理由 |
|---|---|---|
| P2P 栈 | `go-libp2p`（最成熟，移动端有 Berty 先例） | 打洞、Relay v2、DHT、GossipSub 全在库内 |
| 核心语言 | Go，编译为 `android/.aar` + `ios/.xcframework` | 一套协议实现，避免多端行为不一致 |
| UI | Flutter 3.x（`flutter_webrtc` 承担媒体面） | 一套代码覆盖四端 |
| 本地库 | `modernc.org/sqlite`（纯 Go，无 cgo）+ 应用层字段加密 | gomobile 下避免 cgo/SQLCipher 构建地狱 |
| 序列化 | protobuf（`google.golang.org/protobuf`） | 与原设计一致，跨端稳定 |
| 离线存储 | S3 兼容（R2 / MinIO / OSS / COS / B2） | 保留原设计 |
| 凭证模型 | **上传票据池（presigned URL）**，凭证不出接收方设备 | 修正原方案"发送方持有接收方 AK/SK"的矛盾 |
| 多端 | **账号密钥 + 设备密钥双层** | 修正同 PeerID 多端冲突 |
| 音视频 | `flutter_webrtc` 媒体 + Go 只做信令 | 原文档缺失此选型 |
| 推送 | 可选 `APNs/FCM` 唤醒通道，只带"有离线消息"指针 | 修正 iOS 后台不可常驻的硬约束 |

### 0.1 明确不做的部分（控制爆炸半径）

- 不做消息漫游、不做跨账号云端备份、不做群历史回溯给新成员。
- 不做自研音视频编解码，不做端内 RTP 栈。
- 一期不做 Double Ratchet（静态密钥加密，写进威胁模型，二期再谈）。
- 不做多副本离线消息（群盘单副本 + 生命周期清理）。

---

## 1. 仓库结构

```
nexmem/
├── core/                          # Go module: github.com/nexmem/core
│   ├── go.mod
│   ├── cmd/
│   │   └── nexmemd/               # 桌面端 sidecar / CLI / 调试入口
│   ├── gateway/                   # 统一语义层：Request/Response/Event 分发（一次性实现）
│   ├── mobile/                    # gomobile 导出层（Android/iOS）
│   │   ├── api.go
│   │   └── types.go               # 只用 gomobile 支持的类型
│   ├── ffi/                       # c-shared 导出层（Windows/macOS/Linux 桌面）
│   ├── internal/
│   │   ├── identity/              # 账号密钥、设备密钥、DeviceCert、备份包
│   │   ├── netnode/               # Host、传输、DHT、Relay、AutoRelay、连接管理
│   │   ├── wire/                  # protobuf 帧、编解码、协议 ID 常量
│   │   ├── crypto/                # X25519+HKDF+AES-GCM、密钥封装、签名校验
│   │   ├── store/                 # SQLite、迁移、DAO（消息/会话/游标/群/设置）
│   │   ├── blob/                  # S3 客户端、presign、票据池客户端、生命周期检查
│   │   ├── dm/                    # 单聊服务：直连、ACK、重传、去重、序
│   │   ├── group/                 # 群：GossipSub、密钥分发/轮换、群盘
│   │   ├── directory/             # 索引服务器 HTTP 客户端（签名请求）
│   │   ├── rtc/                   # WebRTC 信令（只交换 SDP/ICE）
│   │   ├── diag/                  # 结构化日志、指标、脱敏导出
│   │   └── lifecycle/             # 前后台切换、网络变化、唤醒处理
│   ├── api/                       # protoc 生成的 pb（gen 目录，勿手改）
│   └── proto/                     # .proto 源文件
├── apps/flutter/                  # nexmem_app
│   ├── lib/
│   │   ├── core/                  # bridge.dart / events.dart / models/（通道封装，不含业务）
│   │   ├── features/{chat,group,contacts,storage,settings,rtc}/
│   │   └── main.dart
│   ├── android/                   # NexmemService（前台服务）+ NexmemPlugin + EventBuffer
│   ├── ios/                       # NexmemPlugin.swift + 推送唤醒
│   ├── desktop/                   # native_ffi.dart（dart:ffi 加载 c-shared）
│   └── pubspec.yaml
├── contract/                      # 通道契约单一真源：api.json + cases/*.json
├── server/
│   ├── directory/                 # 索引服务：公钥、票据池、群盘配置
│   ├── bootstrap/                 # 私有 DHT bootstrap 节点
│   ├── relay/                     # 官方兜底 Relay（限额）
│   └── push/                      # 可选唤醒推送（仅指针，无内容）
├── deploy/
│   ├── docker-compose.yml         # 本地三节点联调（bootstrap+relay+directory）
│   └── minio/init.sh              # 本地 S3 + 生命周期规则
├── tools/
│   ├── spike-nat/                 # P0 连通性压测工具
│   └── loadgen/
├── docs/
└── Makefile
```

---

## 2. 协议定义（`core/proto/`）

### 2.1 identity.proto

```proto
syntax = "proto3";
package nexmem.v1;
option go_package = "github.com/nexmem/core/api/v1;nexmemv1";

// 账号密钥签发的设备证书：解决"同一身份多端并存"的身份归属问题
message DeviceCert {
  bytes  account_pub = 1;   // ed25519，32B，账号身份
  bytes  account_x_pub = 2; // x25519，32B，离线消息封装公钥
  bytes  device_pub = 3;    // 设备 libp2p 公钥（设备级 PeerID）
  string device_name = 4;
  int64  issued_at = 5;
  int64  not_after = 6;
  bytes  signature = 7;     // account_pub 对 1..6 的签名
}

// 上传到索引服务器的公开档案
message PublicProfile {
  bytes  account_pub = 1;
  bytes  account_x_pub = 2;
  repeated DeviceCert devices = 3;
  bool   offline_enabled = 4;   // 用户"对外公开我的离线存储"开关
  int64  updated_at = 5;
  bytes  signature = 6;
}
```

### 2.2 message.proto

```proto
message OfflineMessage {
  string  msg_uuid = 1;         // UUIDv7，自带时间序
  int64   timestamp = 2;
  bytes   sender_account = 3;
  bytes   receiver_account = 4;
  bytes   conversation_id = 5;  // dm:<sorted(account_a,account_b)>
  bytes   encrypted_key = 6;    // 临时 X25519 -> HKDF -> AES-256 key，被 receiver x25519 公钥封装
  bytes   nonce = 7;            // 12B
  bytes   ciphertext = 8;       // InnerMessage
  uint32  key_alg = 9;          // 1 = X25519-HKDF-SHA256-AES256GCM
  ContentType content_type = 10;
  uint32  ttl_hours = 11;
  bytes   sender_sig = 12;      // 发送方账号密钥对 1..11 签名
}

message InnerMessage {
  string  text = 1;
  repeated Attachment attachments = 2;
  string  reply_to = 3;
  RtcInvite rtc = 4;
}

message Attachment {
  string  name = 1;
  uint64  size = 2;
  string  mime = 3;
  bytes   sha256 = 4;
  string  blob_ref = 5;   // 附件密文对象键（分片见 wire.proto）
  bytes   key = 6;        // 附件 AES 密钥（在 InnerMessage 密文内，安全）
}

message GroupOfflineMessage {
  string  msg_uuid = 1;
  int64   timestamp = 2;
  bytes   group_id = 3;
  bytes   sender_account = 4;
  uint32  key_version = 5;
  bytes   nonce = 6;
  bytes   ciphertext = 7;
  uint32  ttl_hours = 8;
  bytes   sender_sig = 9;
}
```

### 2.3 group.proto

```proto
message GroupKeyEnvelope {
  bytes  group_id = 1;
  bytes  member_account = 2;
  uint32 key_version = 3;
  bytes  encrypted_group_key = 4;   // 用成员 account_x_pub 封装
  bytes  group_meta = 5;            // 群名/成员表/群盘配置摘要（同密钥加密）
  bytes  admin_sig = 6;
}

message GroupStorageConfig {
  string endpoint = 1;
  string bucket = 2;
  string prefix = 3;         // 固定 group_offline/{group_id}/
  string region = 4;
  bytes  access_key_enc = 5; // 用当前群密钥加密
  bytes  secret_key_enc = 6;
  uint32 key_version = 7;
}
```

### 2.4 wire.proto（P2P 流帧）

```proto
enum FrameType { HELLO=0; MSG=1; ACK=2; READ=3; TYPING=4; FILE_OFFER=5; RTC_SIGNAL=6; META=7; }

message Frame {
  uint32    version = 1;
  FrameType type = 2;
  bytes     payload = 3;   // 对应各消息的序列化字节
  bytes     sig = 4;       // 发送方设备密钥签名
}

message Ack {
  string msg_uuid = 1;
  int32  code = 2;         // 0=ok,1=dup,2=reject
  int64  at = 3;
}
```

**流协议 ID 常量**（`wire/protocol.go`）：

```go
const (
    PID_DM   protocol.ID = "/nexmem/dm/1.0.0"
    PID_META protocol.ID = "/nexmem/group-meta/1.0.0"
    PID_RTC  protocol.ID = "/nexmem/rtc/1.0.0"
)
```

**帧格式**：4 字节大端长度 + protobuf。单帧上限 1 MiB，超出走附件分片。

---

## 3. 关键机制实现要点

### 3.1 身份与多端（修正项 1）

- 首次启动：生成 **账号密钥对**（ed25519 + x25519）+ **设备密钥对**（ed25519，作为 libp2p Identity）。
- 设备启动时向账号签名生成 `DeviceCert`，本地保存；通过已配对设备扫码/加密信道把账号私钥传给新设备（**账号私钥只在用户设备间流转，不落服务端**）。
- 私聊/群消息的密钥封装一律针对 **account_x_pub**，因此同账号所有设备都可解密；设备密钥只用于传输身份与签名。
- 索引服务器按 `account_pub` 索引，同时保存 `devices` 列表，用于推送唤醒与票据按设备分发。

### 3.2 上传票据池（修正项 2）

原方案"发送方直接用接收方 AK/SK 上传"不可行（等于公开凭证）。替换为：

```
接收方设备（在线时，每 30 min）
  → 用本机 S3 凭证批量生成 512 个 presigned PUT（键：im_offline/{acct}/inbox/{rand16}.msg）
  → POST /v1/inbox/{acct}/tickets  交存（服务端只存 URL 与键，不存凭证）

发送方（离线投递）
  → GET /v1/inbox/{acct}/tickets?take=1  服务端原子出队（Redis LPOP / SQL DELETE..RETURNING）
  → 加密后 PUT 到该 URL；失败则重试一次（换一张票）
```

要点：
- 票据**一次性**，服务端不保留明文凭证；接收方设备离线过久导致票池耗尽时，投递降级为"对方暂不可达"。
- presigned PUT 无法限制对象大小：接收方拉取时丢弃超限对象，并在桶上配置用量告警；后续可切 presigned POST（`content-length-range`）收紧。
- 桶内生命周期规则：`im_offline/` 前缀 7 天自动过期；客户端**不删对象**。

**多端游标（修正项 3）**：共用 `im_offline/{acct}/inbox/`，每台设备在本地维护自己的 `cursor`，靠 `msg_uuid` 去重，不互相删除。

### 3.3 群聊（修正项 6）

1. GossipSub 主题：`/nexmem/group/<base64url(sha256(group_id))>`，消息体为 `GroupOfflineMessage`（已用群密钥加密），签名由 libp2p 密钥完成。
2. **订阅前必须先连通**：入群时通过 `GroupKeyEnvelope.group_meta` 拿到成员 `account_pub` 列表 → DHT `FindPeer` 逐个预热 mesh；新成员由邀请人主动拨号一次。
3. 群密钥轮换：`key_version` 单调递增；退群/踢人立即生成新版本并只向剩余成员分发。
4. 群盘：单副本写入 `group_offline/{group_id}/{msg_uuid}.msg`，成员用群密钥解密；成员各自维护 `group_cursor`。
5. 未配置群盘或上传失败时：仅在线广播，UI 常驻提示（与原文档一致）。

### 3.4 网络层（修正项：阶段前移）

```go
// core/internal/netnode/host.go（节选）
h, err := libp2p.New(
    libp2p.Identity(dev.Priv),
    libp2p.ListenAddrStrings("/ip4/0.0.0.0/udp/0/quic-v1", "/ip4/0.0.0.0/tcp/0"),
    libp2p.NATPortMap(),
    libp2p.EnableNATService(),
    libp2p.EnableHolePunching(),                       // UDP/TCP 打洞
    libp2p.EnableRelay(),                              // Relay 客户端
    libp2p.EnableAutoRelayWithPeerSource(relayPeers),  // 自动预约中继
    libp2p.ConnectionManager(connmgr.NewConnManager(80, 320, connmgr.WithGracePeriod(time.Minute))),
)

kdht, err := dht.New(ctx, h,
    dht.Mode(dht.ModeAuto),
    dht.ProtocolPrefix("/nexmem"),        // 私有 DHT，不污染公网
    dht.BootstrapPeers(bootstrapPeers...),
)
```

- 私有 DHT 必须自建 bootstrap（`server/bootstrap`），这是**第二个中心点**，要纳入运维与备案。
- Relay 服务默认关闭；桌面端可手动开启，官方 Relay 仅兜底并限速限流量。
- 移动端 `EnableHolePunching` 依赖 QUIC；蜂窝网优先 QUIC，Wi-Fi 允许 TCP 回退。

### 3.5 ACK / 重传 / 去重

- 发送：写入本地 `outbox`（状态 `pending`）→ 直连发帧 → 等 `Ack`（8s）→ 3 次失败转离线投递链路。
- 接收：`msg_uuid` 主键去重；校验 `timestamp` 与本机时间偏差 > 7 天拒收；`sender_sig` 验签失败拒收。
- 会话恢复：重连后先发 `HELLO{last_ack_uuid}`，对端补发缺口；本端补发 `pending` 消息。

### 3.6 媒体（修正项 5）

- Go 侧只做信令：`PID_RTC` 流上交换 `{type: offer|answer|candidate, sdp, mid, index}`。
- Flutter 侧 `flutter_webrtc` 负责采集、编码、渲染；ICE 使用 STUN，TURN 可选（自建 coturn，非必需）。
- 通话不落盘，不做录制。

### 3.7 推送唤醒（修正项 4）

- 仅当用户开启"离线提醒"时，接收方在索引服务器登记设备推送令牌。
- 发送方离线投递成功 → 索引服务器向该账号的活跃设备发一条**无内容**推送：`{acct, has_offline: true, bucket_hint}`。
- iOS 靠推送唤醒 → 拉起 core 拉取密文 → 本地解密展示。不接推送则明确产品文案："iOS 后台不保证实时送达，打开应用后收取"。

---

## 4. 本地数据库（SQLite）

```sql
-- migrations/0001_init.sql（节选）
CREATE TABLE account (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  account_pub BLOB NOT NULL, account_priv_enc BLOB NOT NULL,
  account_x_pub BLOB NOT NULL, account_x_priv_enc BLOB NOT NULL,
  device_pub BLOB NOT NULL, device_priv_enc BLOB NOT NULL,
  device_cert BLOB NOT NULL, display_name TEXT
);

CREATE TABLE contacts (
  account_pub BLOB PRIMARY KEY,
  alias TEXT, group_name TEXT,
  blocked INTEGER NOT NULL DEFAULT 0,
  profile BLOB, updated_at INTEGER NOT NULL
);

CREATE TABLE conversations (
  id TEXT PRIMARY KEY,            -- dm:<a|b> 或 group:<gid>
  kind INTEGER NOT NULL,          -- 0=dm 1=group
  title TEXT, last_msg_at INTEGER, unread INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE messages (
  msg_uuid TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  sender_account BLOB NOT NULL,
  sent_at INTEGER NOT NULL,
  direction INTEGER NOT NULL,     -- 0=in 1=out
  content_type INTEGER NOT NULL,
  body_enc BLOB NOT NULL,         -- 应用层加密后的 InnerMessage
  state INTEGER NOT NULL,         -- 0=pending 1=sent 2=acked 3=failed 4=received
  raw BLOB
);
CREATE INDEX idx_messages_conv ON messages(conversation_id, sent_at);

CREATE TABLE inbox_cursors (
  scope TEXT PRIMARY KEY,         -- dm:<acct> 或 group:<gid>
  object_key TEXT NOT NULL,
  etag TEXT, seen_at INTEGER NOT NULL
);

CREATE TABLE groups (
  group_id BLOB PRIMARY KEY, title TEXT, my_role INTEGER NOT NULL,
  key_version INTEGER NOT NULL, group_key_enc BLOB NOT NULL,
  storage_cfg_enc BLOB, offline_enabled INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE group_members (
  group_id BLOB NOT NULL, account_pub BLOB NOT NULL,
  role INTEGER NOT NULL, joined_at INTEGER NOT NULL,
  PRIMARY KEY (group_id, account_pub)
);

CREATE TABLE outbox (
  msg_uuid TEXT PRIMARY KEY, peer_account BLOB, attempts INTEGER NOT NULL DEFAULT 0,
  next_retry_at INTEGER NOT NULL, payload BLOB NOT NULL
);

CREATE TABLE kv (k TEXT PRIMARY KEY, v BLOB NOT NULL);
```

- 库文件位于应用私有目录；`account_priv_enc` 由 **OS Keystore 持有 KEK** 做信封加密（Android Keystore / iOS Keychain / Windows DPAPI / macOS Keychain）。
- `body_enc` 使用本机数据密钥（DataKey）加密，DataKey 同样由 Keystore 保护。

---

## 5. 索引服务（`server/directory`）

### 5.1 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| PUT | `/v1/profile` | 上传 `PublicProfile`（自签名校验） |
| GET | `/v1/profile/{account}` | 查询公钥与设备列表 |
| POST | `/v1/inbox/{account}/tickets` | 接收方交存 presigned 票据 |
| GET | `/v1/inbox/{account}/tickets?take=1` | 发送方原子领取票据 |
| GET/PUT | `/v1/groups/{gid}/storage` | 群盘配置（仅管理员可写） |
| POST | `/v1/presence` | 心跳（设备级，TTL 90s） |
| POST | `/v1/push/token` | 登记推送令牌（可选） |

### 5.2 安全

- 所有请求携带 `X-Nexmem-Pub`、`X-Nexmem-Sig`、`X-Nexmem-Ts`；待签内容为 `nexmem-directory-v1\nMETHOD\npath?query\nUnix秒\nsha256(body)`，服务端用公钥验签并限制时钟偏移 5 分钟，缺失/伪造/篡改/过期一律 401。
- 限流：按 IP + 按 account 双维度；票据领取接口单账号 10 req/s，超限 429 并返回 `Retry-After`。
- 票据交存要求路径账号与签名账号一致（403），读取他人公开档案与代领票据不做该绑定（仍受账号限流约束）。
- 不存消息明文、不存 S3 凭证、不记录正文日志。

### 5.3 存储

- `profiles`、`group_storage`、`push_tokens` 用 PostgreSQL（或 SQLite 单机起步）。
- 票据池用 Redis：`LPUSH`/`RPOP`，键 `tickets:{account}:{device}`，TTL 24h。

---

## 6. Go ↔ Flutter 通信机制设计

### 6.1 通道选型（先纠正一个前提：gomobile 只支持 Android / iOS）

| 平台 | Go 产物 | 中间层 | Dart 访问方式 |
|---|---|---|---|
| Android | `gomobile bind` → `nexmem.aar` | `NexmemService`（前台服务）+ `NexmemPlugin`（Kotlin） | `MethodChannel` + `EventChannel` |
| iOS | `gomobile bind` → `Nexmem.xcframework` | `NexmemPlugin.swift` | `MethodChannel` + `EventChannel` |
| Windows / macOS / Linux | `go build -buildmode=c-shared` → `.dll/.dylib/.so` | 无（同进程） | `dart:ffi` |

**明确否决的方案**：
- ❌ 本地 gRPC / WebSocket 端口（`127.0.0.1:xxxxx`）：会触发防火墙弹窗、端口冲突、其他本机进程可连接，安全面扩大。
- ❌ sidecar 子进程：iOS 根本不允许 `fork/exec`，且桌面端多一套进程守护与崩溃恢复。
- ❌ 移动端用 `dart:ffi` + c-shared：iOS 上无法可靠加载，gomobile 才是官方路径。

三种传输的**语义层完全一致**：由 `core/gateway` 一次性实现 `Request → Response` 与 `Event`，两个导出层（`mobile/`、`ffi/`）只负责字节搬运。这样业务逻辑不会出现两套。

### 6.2 统一消息契约

所有通道上只跑三种 JSON（UTF-8 字节）：

```jsonc
// 1) 请求
{"id": 1024, "method": "dm.sendText", "params": {"peer": "12D3...", "text": "hi"}, "timeout_ms": 15000}

// 2) 响应
{"id": 1024, "ok": true,  "data": {"msg_uuid": "0192f3..."}}
{"id": 1024, "ok": false, "error": {"code": "PEER_UNREACHABLE", "message": "打洞与中继均失败", "retryable": true}}

// 3) 事件（单向，只从 Go 流向 Dart）
{"seq": 87, "type": "message.new", "ts": 1730000000000, "data": {"conversation_id": "dm:...", "msg_uuid": "..."}}
```

- `id` 由 Dart 侧单调递增分配，用于并发请求对号入座。
- `seq` 由 Go 侧全局递增，用于事件去重、缺口检测与重放。
- 错误码为固定枚举（见 6.4），Dart 统一抛 `NexmemException(code, message, retryable)`，**不在各业务页面里解析 Go error 字符串**。

### 6.3 方法清单（Gateway 注册表）

| method | params | data | 说明 |
|---|---|---|---|
| `core.start` | `Config` | `{state}` | 幂等；已启动直接返回当前状态 |
| `core.stop` | — | `{}` | 释放 host 与数据库句柄 |
| `core.info` | — | `{api_version, core_version, features[]}` | 启动时版本协商 |
| `account.me` | — | `{account_id, device_id, display_name}` | |
| `dm.sendText` | `peer, text, reply_to?` | `{msg_uuid}` | 立即入库并返回 uuid，发送状态走事件 |
| `dm.sendFile` | `peer, path, mime?` | `{msg_uuid}` | `path` 必须是应用可读的绝对路径 |
| `dm.sendGroupText` | `group_id, text` | `{msg_uuid}` | |
| `msg.list` | `conversation_id, before_id?, limit` | `{items[], has_more}` | 倒序分页 |
| `msg.listSince` | `conversation_id, after_seq` | `{items[]}` | 事件触发的增量拉取 |
| `msg.markRead` | `conversation_id, up_to_id` | `{}` | |
| `msg.search` | `q, limit` | `{items[]}` | FTS5 |
| `contact.list / add / block` | | | |
| `group.create` | `title, members[]` | `{group_id}` | |
| `group.setStorage` | `group_id, endpoint, bucket, prefix, region, ak, sk` | `{}` | 凭证只在 Go 内使用，不回传 |
| `group.members` | `group_id` | `{members[]}` | |
| `storage.test` | `endpoint, bucket, prefix, region, ak, sk` | `{ok, latency_ms, writable, listable}` | 配置页自检 |
| `backup.export` | `passphrase_b64, path` | `{path}` | 口令用 `Uint8List` 传入并清零 |
| `backup.import` | `passphrase_b64, path` | `{}` | |
| `diag.export` | `path` | `{path}` | 脱敏日志 |
| `rtc.sendSignal` | `peer, payload_b64` | `{}` | SDP/ICE 透传 |

### 6.4 事件清单与错误码

| type | data | 触发 |
|---|---|---|
| `state.changed` | `{state}` | `init/starting/online/degraded/offline/stopped` |
| `message.new` | `{conversation_id, msg_uuid, direction}` | 新消息入库（**只给指针**） |
| `message.updated` | `{conversation_id, msg_uuid, state}` | pending→sent→acked→failed |
| `conversation.changed` | `{conversation_ids[]}` | 未读数/标题变化（100ms 合并） |
| `ack` | `{msg_uuid, code}` | 应用层回执 |
| `transfer.progress` | `{msg_uuid, done, total}` | 200ms 节流 |
| `rtc.signal` | `{peer, payload_b64}` | 对端信令 |
| `error` | `{code, message, retryable}` | 非请求上下文的异步错误 |
| `resync_required` | `{reason}` | 事件缺口/缓冲溢出 |

错误码（14 个）：`INVALID_ARG` `UNAUTHORIZED` `NOT_STARTED` `NOT_ONLINE` `PEER_UNREACHABLE` `OFFLINE_STORAGE_DISABLED` `S3_AUTH` `S3_QUOTA` `S3_IO` `DB_ERROR` `CRYPTO_ERROR` `RATE_LIMITED` `UNSUPPORTED_VERSION` `RESYNC_REQUIRED`。其中 `UNAUTHORIZED` 专用于 Web 网关访问令牌无效/轮换，不可重试。

### 6.5 线程模型（本项目最容易出错的地方）

三条硬规则：

1. **Flutter 的 channel 只能在 platform thread（Android 主线程 / iOS 主队列）调用**。Go 的回调来自任意 goroutine，必须切线程。
2. **Channel 的 handler 里不能跑阻塞调用**（数据库读、网络、解压），否则 ANR / 掉帧。统一丢到单线程执行器，结果回主线程 `reply`。
3. **Go 的 Listener 回调必须立即返回**，禁止在回调里同步等待 Dart。回调内部只做「加 seq + 入缓冲」。

Go 侧适配（`core/mobile/bridge.go`）：

```go
// 由 Kotlin/Swift 实现的接口，gomobile 会把它桥回来
type EventSink interface {
    Emit(eventType string, payloadJSON []byte) // 实现方必须立即返回
}

type bridge struct{ sink EventSink }

func (b *bridge) OnEvent(ev gateway.Event) { // 可能运行在任意 goroutine
    b.sink.Emit(ev.Type, ev.JSON)
}
```

Android（`NexmemPlugin.kt`）：

```kotlin
class NexmemPlugin(private val core: NexmemCore) :
    FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val ring = EventRing(capacity = 512)   // 环形缓冲，带 seq
    private var sink: EventChannel.EventSink? = null

    // 由 Go 的 goroutine 调用
    override fun emit(type: String, payload: ByteArray) {
        val framed = ring.append(type, payload)    // 分配 seq、非阻塞；溢出则置 resync 标记
        main.post { sink?.success(framed) }        // 切到 platform thread
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            try {
                val resp = core.gatewayHandle(call.method, call.arguments.toString())
                main.post { result.success(resp) }
            } catch (e: Throwable) {
                main.post { result.error(errCode(e), e.message, errRetryable(e)) }
            }
        }
    }

    override fun onListen(args: Any?, events: EventChannel.EventSink?) {
        sink = events
        val lastSeq = (args as? Map<*, *>)?.get("lastSeq") as? Long ?: 0L
        if (!ring.replayFrom(lastSeq) { main.post { events?.success(it) } }) {
            main.post { events?.success(mapOf("type" to "resync_required")) }
        }
    }

    override fun onCancel(args: Any?) { sink = null }
}
```

iOS（`NexmemPlugin.swift`）同构，只是把 `main.post` 换成 `DispatchQueue.main.async`，`worker` 换成 `DispatchQueue(label: "nexmem.core")`。

Desktop（`core/ffi/capi.go` + `apps/flutter/lib/core/native_ffi.dart`）：

```go
//export nexmem_call
func nexmem_call(req *C.char, reqLen C.int, out **C.char, outLen *C.int) C.int

//export nexmem_set_event_cb
func nexmem_set_event_cb(cb C.nexmem_event_cb)
```

```dart
final _lib = DynamicLibrary.open('nexmem.dll');
final _call = _lib.lookupFunction<
    Int32 Function(Pointer<Uint8>, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>),
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Int32>)>('nexmem_call');
```

桌面端没有 platform thread 约束，但事件回调仍在 Go 线程触发，Dart 侧需通过 `ReceivePort` 转回主 isolate。

### 6.6 启动 / 关闭时序

```
Dart                          Kotlin/Swift                    Go core
 |-- core.info --------------> | ----------------------------> | 返回 api_version
 |-- core.start(cfg) --------> | 创建/复用 NexmemService ----> | 建库、生成密钥、起 host
 |                            |                             | DHT bootstrap
 |<-- event state.starting --- | <-------------------------- |
 |<-- event state.online ----- | <-------------------------- | DHT 就绪
 |-- event listen(lastSeq) --> | 重放缓冲 / 补 resync
 |-- msg.list(conv) ---------> |
```

- `core.start` 幂等：Android 上 core 由 `NexmemService` 持有，UI 进程重连只重新 attach，不重建 host。
- Flutter 启动时**先 `core.info` 校验 `api_version` 一致**，不一致直接阻断并提示升级，避免跨版本字段错位。
- 关闭：Android 仅在用户「退出登录」或设置里「彻底断开」时 `core.stop`；App 退到后台不停 core。iOS 进后台由系统挂起，`core.stop` 不主动调用（否则推送唤醒后重建成本高）。
- 状态机：`init → starting → online ⇄ degraded → stopped`；`degraded` 表示 DHT 不可达但本地读写可用（索引服务挂了也进入此态，UI 只降级离线投递提示）。

### 6.7 事件缓冲、重放与热重启

Flutter 的 hot restart 会销毁 Dart 侧但**不会销毁 native 里的 core**，因此必须解决「事件丢给谁」：

- Native 侧维护容量 512 的环形缓冲，每条事件带全局 `seq`。
- Dart 每次 `listen({"lastSeq": n})`：缓冲能补齐则重放缺口，否则下发 `resync_required`。
- Dart 收到 `resync_required` 时：清空本地列表 → 重新 `msg.list` 各会话首页 → 更新 `lastSeq = max(seq)`。
- 缓冲溢出策略：丢弃最旧事件并置 `overflow=true`，绝不阻塞 Go 侧。

### 6.8 大数据与文件传递

- **单次过通道的数据 ≤ 64 KiB**，禁止传图片/文件字节/大 JSON。
- 发送文件：Flutter 先用 `ContentResolver` 把 `content://` 复制到 `cacheDir/out/{uuid}`，把**绝对路径**传给 `dm.sendFile`；Go 直接读文件流分片加密。iOS 用 `UIDocumentPicker` + `startAccessingSecurityScopedResource` 后复制到沙盒再传路径。
- 接收文件：Go 解密后写入 `cacheDir/inbox/{msg_uuid}/`，事件只返回路径；UI 用 `Image.file` 渲染或引导另存。
- 备份包、诊断包同理，只传路径。
- 列表一律分页 + 增量，不整表序列化。

### 6.9 安全约束

- 通道上**永不传私钥、S3 凭证、群密钥**；这些只存在于 Go 进程内存与加密数据库。
- 口令类参数用 `Uint8List` 传入（Dart 的 `String` 无法清零），Go 用完 `crypto/subtle` 清零切片。
- Android：`NexmemService` 标记 `android:exported="false"`，并加自定义 signature 级权限，防止第三方 App bind 后读事件。
- 桌面：同进程 FFI，不监听任何端口。
- 日志：channel 层打印请求时只记录 `method` 与耗时，不记录 params 正文。

### 6.10 Flutter 侧分层

```
lib/core/
├── bridge.dart      # MethodChannel('nexmem/core') 唯一出口，负责 id 分配、超时、错误映射
├── events.dart      # EventChannel('nexmem/events')：单订阅流 → 广播 + seq 去重 + resync 处理
├── models/          # freezed 模型（只从 JSON 生成，不持有数据库）
└── native_ffi.dart  # 桌面端实现，向上暴露与 bridge.dart 相同的接口
```

- 业务层只依赖抽象 `NexmemClient`，移动端与桌面端各注入一份实现，`features/` 下代码零平台分支。
- 事件订阅在 `AppShell` 统一建立，页面级只订阅对应会话的派生流（`select` 过滤），避免每页各开一个 channel。
- 所有 UI 变更由 `message.new` 指针事件触发一次 `msg.listSince` 拉取，不做「事件带全量正文」的设计。

### 6.11 契约测试

- 单一真源：`contract/api.json` 存方法名、参数 schema、错误码；`contract/cases/*.json` 存请求/响应样例。
- Go 侧 golden test 校验 `gateway.Handle` 对每条 case 的输出。
- Dart 侧同一批 case 跑 `bridge` 的解码逻辑。
- Kotlin/Swift 只做「收发不丢字节」的透传测试，不复制业务断言。
- 任一平台单独跑通不算完成，**必须有 `integration_test` 在真机 Android + iOS 各跑一遍完整收发流程**。


### 6.12 导出层实现约束（gomobile）

Gateway 的对外形态只有两个方法 + 一个回调，避免 gomobile 反复踩坑：

```go
package mobile

// 由 Kotlin/Swift 实现，Go 侧调用
type EventSink interface {
    Emit(eventType string, payloadJSON []byte)
}

type Core struct{ gw *gateway.Gateway }

func NewCore() *Core
func (c *Core) SetSink(s EventSink)
func (c *Core) Handle(method string, paramsJSON []byte) ([]byte, error)
func (c *Core) Version() string
func (c *Core) Close() error
```

gomobile 限制（不遵守会直接编译失败）：

- 导出签名不得含 `context.Context`、泛型、`chan`、函数类型，也不得导出未定义的方法集接口。
- 返回值只支持基础类型、`string`、`[]byte`、结构体、导出接口与 `error`。
- `[]byte` 会做一次拷贝，不要指望零拷贝；大对象走文件路径。
- 不得导出包级可变状态；`Core` 必须是单实例，由 Kotlin/Swift 侧持有。

桌面 `core/ffi` 用同一 `gateway`，只多一层 C 字符串编解码：

```c
// nexmem.h（c-shared 生成）
int  nexmem_call(const char* req, int req_len, char** out, int* out_len);
void nexmem_free(char* p);
void nexmem_set_event_cb(void (*cb)(const char* type, const char* payload, int len));
```

对应的 Go 侧实现要点：`C.CString` 分配的内存必须由 `nexmem_free` 释放（Dart 侧 `malloc.free`），否则每请求泄漏一次；回调函数指针用 `runtime/cgo.Handle` 保存，`Close` 时释放。

---

## 7. 里程碑与门禁

> 顺序按"先验证风险，再堆功能"重排。每阶段必须有可演示闭环，未达标不进入下一阶段。
> 任务级拆解与状态跟踪见 [开发进度文档.md](file:///D:/wwwroot/nexmem/docs/%E5%BC%80%E5%8F%91%E8%BF%9B%E5%BA%A6%E6%96%87%E6%A1%A3.md)。

### P0 连通性验证（不做完不立项）

**任务**
- `tools/spike-nat`：双节点 DHT 寻址 + 打洞 + Relay 回退，输出 CSV。
- 覆盖：同局域网、家宽 NAT、公司 NAT、4G/5G、双端对称 NAT。
- 对比 `go-libp2p` QUIC 与 TCP 的直连率、首包时延。
- `deploy/docker-compose.yml` 起 bootstrap + relay + directory + minio。

**门禁（Go/No-Go）**
- 直连成功率 ≥ 60%，中继兜底后可达率 ≥ 95%。
- 直连 P95 建连 < 3s，中继 P95 < 6s。
- 若未达标：先调优（AutoNAT、QUIC 端口、relay 数量、TURN 备选），仍不达标则重新评估方案。

### P1 内核（身份 + 存储 + 单聊直连）

- 身份生成、DeviceCert、Keystore 信封加密、密钥备份包（Argon2id + XChaCha20-Poly1305）。
- SQLite 迁移与 DAO；protobuf 生成流水线（`make proto`）。
- 双节点文本直连 + 心跳 + 结构化日志。
- **通道打通**：`gateway` + `MethodChannel('nexmem/core')` + `EventChannel('nexmem/events')`，跑通「一次请求往返 + 一条事件回传 + hot restart 后 seq 重放」，Android/iOS 各验证一次。

**门禁**：两设备互加好友后 1000 条文本不丢不乱序；杀进程重启后消息完整；备份导入到新设备可恢复；hot restart 后不丢事件、无重复消息。

### P2 可靠性 + 文件

- ACK/重传/去重/保序（按 `sent_at, msg_uuid` 排序）+ 断线重连补发。
- 文件分片（1 MiB/片，AES-GCM 逐片）+ 进度事件 + 断点续传。
- 好友/黑名单/备注/本地全文搜索（FTS5）。

**门禁**：拔网线 30 秒、切 Wi-Fi/蜂窝、锁屏 5 分钟三种场景下无丢消息；1 GB 文件传输可断点续传。

### P3 离线闭环

- `blob`：S3 客户端抽象（R2 / MinIO 优先）、presign、票据池、生命周期规则检测。
- 接收方上线扫描 `inbox/` → 解密 → 入库 → 推进游标；超限/非本账号对象丢弃。
- `server/directory` 完整实现 + 签名鉴权 + 限流。
- 未开启离线存储时的降级提示文案（与原文档一致）。

**门禁**：A 离线 → B 发送 → A 上线 5s 内可见；重复拉取不重复入库；桶用量与票据消耗可观测；索引服务宕机时在线聊天 100% 不受影响（回归用例）。

### P4 群聊

- GossipSub 接入 + 私有主题 + 消息验签 + TTL/指纹去重。
- 群密钥生成、分发、入群授权、退群轮换（`key_version`）。
- 群盘写入/拉取/游标；群成员地址预热。

**门禁**：50 人群在线广播覆盖率 100%；踢人后离群者无法解密新消息（用旧密钥解密必须失败）；群主未配盘时离线成员上线看到明确提示。

### P5 中继与穿透调优

- Relay 服务开关（默认关）、官方兜底的限额与告警、AutoRelay 策略。
- 移动端功耗采样（中继开启 vs 关闭的每小时耗电与流量）。

**门禁**：对称 NAT 双端可达率 ≥ 95%；中继开启时移动端待机功耗增量 < 5%/小时。

### P6 多端打包与体验

- Android 前台服务、iOS 推送唤醒、桌面（可选 Tauri/原生壳）打包。
- 云厂商接入引导页（R2 / MinIO / OSS / COS）、计费归属提醒。
- 诊断日志导出（脱敏）、举报入口、拉黑屏蔽。

**门禁**：四端安装包可自签名安装；冷启动到可发消息 < 3s；引导页可按厂商完成配置并自检通过。

---

## 8. 构建与 CI

```makefile
proto:      protoc -I core/proto --go_out=core/api --go_opt=paths=source_relative core/proto/*.proto
test:       cd core && go test ./... -race
lint:       cd core && golangci-lint run
android:    cd core && gomobile bind -target=android/arm64,android/arm -androidapi 24 -o ../apps/flutter/android/libs/nexmem.aar ./mobile
ios:        cd core && gomobile bind -target=ios/arm64 -o ../apps/flutter/ios/Frameworks/Nexmem.xcframework ./mobile
desktop:    cd core && go build -buildmode=c-shared -o ../apps/flutter/desktop/lib/nexmem.dll ./ffi
app:        cd apps/flutter && flutter build apk --release
e2e:        docker compose -f deploy/docker-compose.yml up -d && go test ./test/e2e -tags=e2e
contract:   go test ./gateway/... -run Contract && cd apps/flutter && flutter test test/contract
```

CI 必过项：`go vet`、`golangci-lint`、`go test -race`、`buf lint` + `buf breaking`、`flutter analyze`、`flutter test`、gomobile 双端构建、`-buildmode=c-shared` 桌面构建、契约测试。

测试分层：
- 单元：crypto 向量、protobuf 编解码、游标推进、去重。
- 契约：`contract/cases/*.json` 同时驱动 Go gateway 与 Dart bridge。
- 集成：docker 起 3 节点（bootstrap/relay/directory）+ 2 个 core 实例跑消息流。
- E2E：真实两设备/两模拟器（含 hot restart、后台切回、事件重放）。

---

## 9. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 打洞率不达标 | 项目不可用 | P0 门禁前置；TURN 作为最后兜底 |
| Android 后台被杀 | 离线延迟 | 前台服务 + 厂商白名单引导 + 可选推送 |
| iOS 无法后台常驻 | 实时性 | 推送唤醒 + 明确文案 |
| 票据池被刷 | 接收方账单 | 单账号限流、票据 TTL、桶用量告警 |
| 索引服务成为单点/合规靶点 | 可用性/合规 | 支持自建与多实例；仅存公钥类数据；备案 |
| 群密钥分发依赖管理员在线 | 新成员进群受阻 | 邀请人代发（任一持有密钥成员可转封） |
| 静态密钥无前向保密 | 长期密钥泄露即历史全失 | 写进威胁模型；P7 规划 prekey 池 |

---

## 10. 与原设计文档的差异对照

| 原设计 | 本方案 | 原因 |
|---|---|---|
| 发送方持接收方 S3 凭证上传 | 上传票据池（presigned PUT） | 凭证不可公开 |
| 同一密钥多端同一 PeerID | 账号密钥 + 设备密钥 + DeviceCert | Relay reservation 冲突、身份歧义 |
| 已读后删除对象 | 本地 per-device 游标 + 生命周期清理 | 多端会互相删消息 |
| 阶段五才做 NAT 穿透 | 前移为 P0 门禁 | 否则前后阶段无法验证 |
| 未提音视频方案 | flutter_webrtc + libp2p 信令 | 补齐空白 |
| 未提移动端后台 | 前台服务 + 可选推送 | 补齐硬约束 |
| SQLite 明文/未定加密 | 纯 Go sqlite + Keystore 信封加密 + 字段加密 | gomobile 兼容性 |
| Flutter 全端同一套绑定 | 移动端 gomobile + 桌面 c-shared/dart:ffi | gomobile 不支持桌面平台 |
| 未定义 Go↔UI 通道 | gateway 统一契约 + MethodChannel/EventChannel + seq 重放 | 避免 hot restart 丢事件、跨版本字段错位 |
