# 在线状态 + 语音通话修复 Spec

> 当前优先级：**先修在线状态**（判断对方能否收消息 / 接语音视频），语音修复已完成代码改动，待重建后一并复测。

## 0. 当前任务：在线 / 离线状态

### 0.1 现象

- 同一 Wi-Fi 下，Mac 的会话列表/聊天头部对 Android 恒显示「离线」，Android 端看 Mac 同样恒为「离线」。
- 两端头像状态点永远不可信；用户无法据此判断对方能否收消息、能否接语音/视频。
- 旁证：Android 端看「自己」永远显示在线（头像默认值），与对端无关。

### 0.2 根因（按证据排序）

#### R0-1 应用层从未调用 `presence.list`（决定性）

全仓检索 `listPresence` 只有定义，没有任何调用点：

- 定义：[social_service.dart](file:///Users/huangyu/nexmem/app/lib/features/social/social_service.dart#L164-L169)
- 会话模型默认值恒为离线：[conversation.dart](file:///Users/huangyu/nexmem/app/lib/features/chats/conversation.dart#L21)
- 会话列表映射不写 presence：[conversation_service.dart](file:///Users/huangyu/nexmem/app/lib/features/chats/conversation_service.dart#L28-L51)
- 头像/头部/面板只读 `item.presence`：[chats_page.dart](file:///Users/huangyu/nexmem/app/lib/features/chats/chats_page.dart#L634-L639)、[chat_page.dart](file:///Users/huangyu/nexmem/app/lib/features/chat/chat_page.dart#L796-L801)
- 「自己在线」是头像组件默认值：[avatar.dart](file:///Users/huangyu/nexmem/app/lib/app/avatar.dart#L20-L21)

结论：内核有没有正确结果都不会显示出来，UI 永远离线。

#### R0-2 账号编码不一致

实测 `conversation.list`（本地 webd）单聊 `peer` 为 base64url（如 `gEI-OLqnIZ_XiBGb1wqx_EftOeygoqJJ_JuZqK6UpPI`），而 `presence.list` 的 `accounts` 要求十六进制（`presence.list` 返回的 `account` 也是 hex）。若直接拿 `peer` 查询，内核按 hex 解码失败 → 恒离线。

#### R0-3 内核 presence 语义与耗时

- [service.go](file:///Users/huangyu/nexmem/core/internal/social/service.go#L344-L361) `ListPresence` **串行**解析每个账号，单账号解析器超时 12s（[resolver.go](file:///Users/huangyu/nexmem/core/internal/discovery/resolver.go#L57-L62)）；2 个不可达好友即 24s，超过 WS 15s / 原生 20s 的传输超时 → 整个请求失败。
- [app.go](file:///Users/huangyu/nexmem/core/internal/coreapp/app.go#L790-L793) 的 `Online` 只判断「能否解析到地址」，目录里的历史地址也算在线，设备已关机时仍报在线。
- 实测（本地 webd `presence.list` 两个账号）均返回 `online=true`，说明目录/DHT/mDNS 链路本身可用，问题集中在「UI 不查 + 编码 + 语义」。

### 0.3 修复方案（决策完整）

#### 0.3.1 `core/internal/social/service.go` · `ListPresence`

- 并发解析所有账号（`sync.WaitGroup`，结果按下标写入独立槽位，不共享 map）。
- 解析完成后**顺序**写 `UpsertPresence`（避免 SQLite 并发写）。
- 单账号语义：`s.online` 返回 `(false, nil)` 视为「确定离线」，覆盖缓存；返回 `err != nil` 时保留缓存值并 `known=true`。
- 返回结构不变：`{"account": hex, "online": bool, "known": bool}`。

#### 0.3.2 `core/internal/coreapp/app.go` · `Online` 回调

- `resolvePeer` 失败 → `(false, nil)`。
- 解析成功且 `a.host != nil`：
  - `host.Network().Connectedness(peerID) == network.Connected` → `(true, nil)`；
  - 否则 `host.Connect` 以 3.5s 超时实际拨号，成功 → `(true, nil)`，失败 → `(false, nil)`。
- `a.host == nil` 时退回「解析成功即在线」。
- 新增 import：`github.com/libp2p/go-libp2p/core/network`、`github.com/libp2p/go-libp2p/core/peer`（若未引入）。

#### 0.3.3 `app/lib/features/chats/conversation_store.dart`

新增：

```dart
/// 应用在线状态（按对端账号 base64url 或 hex 均可匹配 item.peer）。
void applyPresence(Map<String, PresenceStatus> byPeer) {
  bool changed = false;
  for (final item in _items.values.toList()) {
    if (item.isGroup) continue;
    final status = byPeer[item.peer] ?? byPeer[normalizeAccountHex(item.peer)];
    if (status == null || status == item.presence) continue;
    _items[item.id] = item.copyWith(presence: status);
    changed = true;
  }
  if (changed) notifyListeners();
}
```

（`normalizeAccountHex` 来自 `features/contacts/contact_service.dart`，会话层直接 import，不复制编码逻辑。）

#### 0.3.4 `app/lib/app/shell.dart`

- 新增字段：
  - `Timer? _presenceTimer;`
  - `bool _presenceBusy = false;`
  - `final ValueNotifier<Map<String, bool>> _presence = ValueNotifier(<String, bool>{});`（key 为 hex，供联系人页复用）
- `_boot` 成功后启动：`_startPresencePolling(session)`：立即刷新一次 + `Timer.periodic(20s)`。
- `_refreshPresence(session)`：
  1. `_presenceBusy` 守卫；
  2. 从 `_conversations.sorted` 取单聊 `peer`，`normalizeAccountHex` 后收集 hex 列表（去重）；
  3. 调 `session.social.listPresence(hexList)`（30s 超时）；
  4. 构建 `hex → bool` 与 `peer(base64url) → PresenceStatus`；
  5. `_presence.value = hexMap`；`_conversations.applyPresence(peerMap)`；
  6. 失败仅 `_logDegradation('刷新在线状态', ...)`。
- `dispose`：`_presenceTimer?.cancel(); _presence.dispose();`
- `ContactsPage` 调用处传入 `presence: _presence`。

#### 0.3.5 `app/lib/features/social/social_service.dart`

- `listPresence` 增加 `Duration timeout = const Duration(seconds: 30)`，透传 `_transport.call(..., timeout: timeout)`；`_call` 增加可选 `timeout` 参数。

#### 0.3.6 `app/lib/features/contacts/contacts_page.dart`

- 构造参数新增 `ValueListenable<Map<String, bool>>? presence`。
- `_ContactTile` 新增 `bool? online`，`AppAvatar(showPresence: online != null, presence: online == true ? AvatarPresence.online : AvatarPresence.offline)`。
- 好友分组列表用 `ValueListenableBuilder` 包裹（或页面 build 内监听），按 `contact.id`（hex）取状态；未知状态不显示状态点（避免误报离线）。

### 0.4 验收标准

1. 对方应用在前台/后台运行（同一 Wi-Fi）时，本端 20s 内把会话列表、聊天头部、联系人列表状态点更新为「在线」；关闭对方应用后 20s～40s 内变为「离线」。
2. Mac ↔ Android 双向互显一致（两端各自能看到对方在线 / 离线切换）。
3. 断开 Wi-Fi 或退出对端应用时不再出现「在线但消息发不出」的错报。
4. `cd core && go test ./internal/social ./internal/discovery ./internal/coreapp` 通过（或仅既有并发敏感用例失败，单独跑通过）。
5. `cd app && flutter analyze` 无新增错误。
6. 业务回归：文字消息收发、好友申请/备注、语音/视频通话不受影响。

### 0.5 验证步骤

```bash
# 1) 内核
cd /Users/huangyu/nexmem/core && go test ./internal/social ./internal/discovery ./internal/coreapp

# 2) 前端静态检查
cd /Users/huangyu/nexmem/app && flutter analyze

# 3) 重建 macOS（release）
cd /Users/huangyu/nexmem/app && flutter build macos --release
cp /Users/huangyu/nexmem/bin/libnexmem.dylib \
   build/macos/Build/Products/Release/nexmem_app.app/Contents/Frameworks/
codesign --force --deep --sign - build/macos/Build/Products/Release/nexmem_app.app

# 4) 重建 Android（需手机重新开启无线调试 / 插 USB）
cd /Users/huangyu/nexmem/app
flutter build apk --debug \
  --dart-define=NEXMEM_DIRECTORY_URL=http://103.119.14.14:8081 \
  --dart-define=NEXMEM_BOOTSTRAPS=/ip4/103.119.14.14/tcp/14001/p2p/12D3KooWFV5aGaZ9nFepfiJaPkM18EzmFVC34Lg2LAY8Cv5JKrU2 \
  --dart-define=NEXMEM_RELAY_ADDRS=/ip4/103.119.14.14/tcp/14002/p2p/12D3KooWS3cnEVm6z4XQQB9nXs9WBb5sfaHnck5TRCAfxEKZQFKm,/ip4/103.142.103.6/tcp/14002/p2p/12D3KooWCv4mouxCSAK6CXJ4B5gZbpjB2pdxVLu8DTz4jViLVvsJ \
  --dart-define=NEXMEM_MDNS=true
/opt/homebrew/share/android-commandlinetools/platform-tools/adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

验证：两端进入会话列表 → 关闭 Android 应用 → 观察 Mac 状态点在 20～40s 内转灰；重开 Android → 20s 内转绿；反向重复。日志中可见 `presence` 调用无超时错误。

---

## 1. 语音通话无声（代码已改，待重建复测）

### 1.1 现象

- 同一 Wi-Fi 下，Mac 主叫 Android 语音通话：Android 弹出接听页并显示「通话中」，Mac 一直停在「正在呼叫…」，两端都听不到任何声音。
- 旁证：Android 端 `getUserMedia` 若失败不会有任何提示，UI 状态仍显示「通话中」。

### 1.2 根因

#### R1 Android 缺少音视频权限声明（决定性）

[AndroidManifest.xml](file:///Users/huangyu/nexmem/app/android/app/src/main/AndroidManifest.xml#L2-L9) 只声明了网络、mDNS、前台服务等权限，没有 `RECORD_AUDIO` / `CAMERA` / `MODIFY_AUDIO_SETTINGS`。

[rtc_media.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/rtc_media.dart#L143-L148) 的 `start()` 直接调用 `getUserMedia({'audio': true})`。Android 上未声明录音权限时该调用失败 → 被叫端 [call_service.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/call_service.dart#L437-L455) 的 `_acceptOffer` 在 `media.start()` 处抛异常 → 根本不发 `answer` → 主叫永远收不到远端描述 → 无媒体、无声音。

#### R2 状态机伪造「通话中」

[call_service.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/call_service.dart#L211-L248) 的 `answer()` 不管 `_acceptOffer` 是否成功，最后都无条件 `_emit(CallState.connected)`，所以被叫 UI 显示「通话中」，掩盖了媒体根本没起来的事实。
[call_service.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/call_service.dart#L383-L419) 的 `_startSession` 同样吞掉 `media.start()` 异常，主叫停留 `outgoing`。

#### R3 早到的 ICE 候选被丢弃或拆掉整通

[call_service.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/call_service.dart#L295-L316) 中，候选到达时若会话不存在直接 `return`；会话存在但 `setRemoteDescription` 尚未执行时，[rtc_media.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/rtc_media.dart#L182-L190) 的 `addCandidate` 会抛异常，`handleSignal` 捕获后执行 `_failSession` → 整通被拆。此时即使 SDP 协商成功，ICE 也永远连不上。

#### R4 候选与 SDP 的发送顺序无保证

[call_service.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/call_service.dart#L458-L474) 用 `unawaited` 立即发候选，而 [call_service.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/call_service.dart#L400-L415) 是 `await` 发 offer/answer，候选常常先于 SDP 到达对端，触发 R3。

### 1.3 已实施改动

- `AndroidManifest.xml`：新增 `RECORD_AUDIO`、`CAMERA`、`MODIFY_AUDIO_SETTINGS`、`BLUETOOTH_CONNECT`。
- `rtc_media.dart`：候选排队；`addCandidate` 未就绪入队、失败不抛；`setRemoteDescription` 成功后 flush；`start`/`dispose` 重置；`getUserMedia` 失败抛带上下文异常。
- `call_service.dart`：`_startSession`/`_acceptOffer` 返回 `bool`；`answer` 仅成功才 `connected`，否则 `endCall`；候选失败不拆会话；关键路径 `debugPrint`。
- `shell.dart`：`_onEvent` 增加调试事件日志。
- macOS `Info.plist`：`NSLocalNetworkUsageDescription`、`NSBonjourServices _nexmem._udp`。
- 内核 resolver：DHT 失败保留 PeerID；DHT 地址并入 mDNS（[resolver.go](file:///Users/huangyu/nexmem/core/internal/discovery/resolver.go#L71-L104)）。

### 1.4 验收标准（重建后复测）

1. Android 首次语音通话弹出麦克风授权；允许后 Mac ↔ Android 双向可听到声音。
2. 被叫接听后，主叫在 3 秒内从「正在呼叫…」变为「通话中」；被叫不再出现「假通话中」。
3. 任一端静音，对端立即无声；取消静音恢复。
4. 日志可见 `ice state=connected`，且不再出现早到候选导致的拆会话。
5. 回归：文字消息收发不受影响。

---

## 2. 语音/视频通话 QQ 化修复（当前任务，最高优先级）

### 2.1 现象

- 发起视频通话后，通话页**没有接听按钮**（被叫端也收不到来电页）。
- 主叫点语音后，对端界面没有任何来电提示或消息，看起来「呼叫消失」。
- 期望：仿 QQ——被叫全屏来电页（头像/昵称 + 绿色接听 / 红色拒绝）、主叫「正在呼叫…」可取消、接通后计时、结束后双方会话里留下通话记录。

### 2.2 代码现状与根因（已核对）

- 来电链路本身是通的：`rtc.sendSignal` → 内核 `dm.SendSignal` → 对端 `rtc.signal` 事件 → [shell.dart](file:///Users/huangyu/nexmem/app/lib/app/shell.dart#L1014-L1033) `_onRtcSignal` → [call_service.dart](file:///Users/huangyu/nexmem/app/lib/features/rtc/call_service.dart#L286-L320) `handleSignal` → `_emit(CallState.incoming)` → `_callInfo` → `_buildCallOverlay`。
- **R0 macOS FFI 事件 `data` 被二次编码成 base64（决定性）**：[capi.go](file:///Users/huangyu/nexmem/core/ffi/capi/capi.go#L87-L93) 在事件回调里先 `json.Marshal(data)` 得到 `[]byte`，再交给 `eventbuf.Emitter` 又 Marshal 一次，`event.Data` 变成 base64 字符串；Dart [CoreEvent.fromJson](file:///Users/huangyu/nexmem/app/lib/transport/transport.dart) 只接受 Map，于是 `data = {}`。实测 `rtc.signal` 帧为 `data: eyJwYXlsb2FkX2I2NCI6...`，`_onRtcSignal` 拿到 `peer=null/payload=Null` → 主叫永远收不到 answer、来电端收不到任何事件数据。Android（gomobile）与 webd 都直接传 `data`，因此只有 macOS 受影响。
- **R1 主叫侧媒体失败 = 静默失败（决定性）**：`_startSession` 在 `media.start()` 抛错时只 `debugPrint` 并返回 false，`startOutgoing` 随即 `endCall()`；release 包无可见提示 → 用户看到「点了没反应，对方也没收到」。macOS 麦克风/摄像头 TCC 未授权、Android 录音权限被拒、无可用采集设备都会走到这里（实测 macOS 首次发起会弹麦克风授权，拒绝即静默失败）。
- **R2 信令失败同样静默**：`_send` 失败仅在启动阶段被 `_startSession` 吞掉，结束原因未传给 UI，也没有重试或提示。
- **R3 来电页按钮不可见/被遮挡**：`CallPage` 的接听/拒绝按钮在 `Column` 底部 `Wrap` 内，且视频小窗叠在其上方区域；小屏/视频时按钮可能被挤出视口或平台视频视图覆盖。视频与语音共用同一布局，没有专门为「视频接听」放大按钮。
- **R4 无超时、无结束原因、无通话记录**：主叫 45s 无人接听不会自动结束；结束后被叫会话里没有任何记录，用户无法感知「刚才有人来电」。
- **R5 对端名称解析不生效**：[shell.dart](file:///Users/huangyu/nexmem/app/lib/app/shell.dart#L1020) 用 `_conversations.byId(peer)`，而会话 id 是 `dm:<peer>`，来电页常常显示裸账号。

### 2.3 修复方案（决策完整）

#### 2.3.1 `app/lib/features/rtc/call_service.dart`

1. 新增结束原因枚举与字段：

```dart
enum CallEndReason { none, hangup, rejected, canceled, noAnswer, failed }
```

`CallInfo` 增加 `CallEndReason endReason`、`DateTime? startedAt`；`copyWith` 透传。
2. `_emit` 增加 `endReason` 参数；`startOutgoing`/`startGroupOutgoing` 在媒体或首条信令失败时 `_emit(CallState.ended, endReason: CallEndReason.failed)` 并清理会话。
3. `_send` 失败向上抛（保持 `rethrow`），使 `_startSession` 的失败路径能区分「媒体失败 vs 信令失败」，统一走 `failed`。
4. 主叫振铃超时：`startOutgoing`/`startGroupOutgoing` 成功后启动 `Timer(const Duration(seconds: 45))`；若仍处于 `outgoing` → `endCall(reason: CallEndReason.noAnswer)`。收到 answer / connected 时取消该 Timer。
5. `reject()` 发送结束语义：被叫拒绝后 `_emit(CallState.ended, endReason: CallEndReason.rejected)`；主叫主动挂断 `endCall()` 默认 `hangup`（呼叫中挂断为 `canceled`）。
6. `endCall({CallEndReason reason = CallEndReason.hangup})` 保留 1.5s 的 ended 快照（不在 `endCall` 内立即把 `_current = null`，由 UI 计时收起），并释放媒体。
7. 通话计时：新增 `DateTime? connectedAt`，`_emit` 时写入 `startedAt`，供 UI 计算时长；`CallInfo` 增加 `Duration get elapsed`。

#### 2.3.2 `app/lib/features/rtc/call_page.dart`

1. **来电态（QQ 风格）**：`_incoming` 时全屏深色，中部大头像 + 昵称 + `邀请你进行视频通话` / `邀请你进行语音通话`；底部固定两枚 72px 圆按钮：红色「拒绝」、绿色「接听」（视频未接听时图标 `videocam`，文案「视频接听」）。
2. 按钮区域改为 `SafeArea` 包裹的固定底部 `Row`，不放进可滚动/可被视频视图覆盖的区域；视频小窗仅在 `connected` 后显示，避免遮挡来电按钮。
3. 呼叫中：显示「正在呼叫…」+ 取消按钮；接通后显示通话时长（`mm:ss`，由 `CallInfo.elapsed` 每秒刷新，`CallPage` 改为 `StatefulWidget` + `Timer.periodic`）。
4. 结束态：显示结束原因文案（已挂断/对方已拒绝/无人接听/呼叫失败），1.5s 后由壳层收起。
5. 来电提示音：进入 `incoming` 时每 2s `SystemSound.play(SystemSoundType.alert)` + `HapticFeedback.vibrate()`，离开来电态即停止，最多 30s。

#### 2.3.3 `app/lib/app/shell.dart`

1. `_onRtcSignal` 名称解析：先按 `dm:<peer>` 取会话标题，再回退遍历 `_conversations` 匹配 `item.peer == peer`。
2. `_callChanges` 监听：`ended` 时按 `info.endReason` 组装记录文案并写入会话（见下）；并用 `Timer(const Duration(milliseconds: 1600))` 收起 `_callInfo`（替换 `_buildCallOverlay` 内立即清空逻辑）。
3. `startOutgoing` 失败时弹 SnackBar：`拨打失败：媒体不可用（请检查麦克风/摄像头权限）` 或 `拨打失败：对方不可达`。
4. 通话记录：新增 `_appendCallRecord(String conversationId, String text)`：
   - 构造 `ChatMessage(id: 'call-${millisecondsSinceEpoch}', conversationId: conversationId, text: text, sentAt: now, senderId: '', senderName: '', isMine: true, isGroup: conversationId.startsWith('group:'), status: MessageStatus.sent)`；
   - `_chatFor(item).receive(message)`；`_conversations.touch(conversationId, text)`。
   - 文案：主叫接通后 `语音通话 00:12` / `视频通话 01:03`；主叫未接通 `对方无应答` / `已取消` / `对方已拒绝` / `呼叫失败`；被叫 `未接来电（语音/视频）` / `已拒绝来电` / `通话时长 00:12`。
   - 消息仅存内存（重启不保留），不做 schema/DB 变更。
5. `dispose` 取消新增的计时器。

#### 2.3.4 `core/ffi/capi/capi.go`（R0 根因修复）

事件回调改为直接把 `data any` 交给 `emitter.Emit(eventType, data)`，删除中间的 `json.Marshal(data)`，避免 `event.Data` 被二次编码为 base64 字符串；删除不再使用的 `encoding/json` 导入。修复后 macOS 的 `rtc.signal`（以及消息等所有事件）`data` 恢复为 JSON 对象，Dart 侧 `CoreEvent.fromJson` 才能解析出 `peer/payload_b64`。Android（gomobile）与 webd 原本就直传 `data`，行为不变。

### 2.4 验收标准

1. 视频通话：被叫全屏来电页可见，**视频接听按钮可点**；接听后双方进入「通话中」并计时。
2. 语音通话：被叫收到来电页；接听后 Mac ↔ Android 双向有声；静音/取消静音生效；任意一端挂断，两端 2s 内结束。
3. 主叫 45s 无人接听自动结束并提示「无人接听」；主叫可在呼叫中取消。
4. 结束后双方会话各出现一条通话记录文本（接听/未接/拒绝/时长）。
5. 媒体或信令失败时主叫有可见错误提示，不再出现「无反应」。
6. 回归：在线状态、文字消息、好友备注不受影响。

## 3. 不在本次范围

- `NEXMEM_MDNS` 两端默认关闭时同网段发现策略的进一步优化。
- 桌面端新消息、好友申请/备注不实时刷新（事件消费问题）。
- Android 聊天页把 `nexmem:social:` 协议控制消息渲染成气泡。
- 群聊成员在线状态（当前仅单聊联系人）。
