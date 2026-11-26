# 在线状态 + 语音修复 · 任务清单

> 对应 spec：[spec.md](file:///Users/huangyu/nexmem/spec.md)

## 已完成（语音相关代码改动）

- [x] T1 Android 音视频权限声明（`AndroidManifest.xml`）。
- [x] T2 媒体层缓冲早到 ICE 候选（`rtc_media.dart`）。
- [x] T3 通话状态机修正，杜绝假「通话中」（`call_service.dart`）。

## T4 内核 presence：并发解析 + 真实连通校验

- [x] `core/internal/social/service.go` `ListPresence`：并发解析账号，顺序写 `UpsertPresence`；`(false, nil)` 覆盖缓存，错误保留缓存。
- [x] `core/internal/coreapp/app.go` `Online`：`resolvePeer` 成功后检查 `Connectedness`，未连接则 `host.Connect`（3.5s）判断真实在线；失败返回 `(false, nil)`。
- 验收：`cd core && go test ./internal/social ./internal/discovery ./internal/coreapp` 通过。

## T5 应用层 presence：轮询并落到列表 / 头部 / 联系人

- [x] `app/lib/features/social/social_service.dart`：`listPresence` 支持 30s 超时。
- [x] `app/lib/features/chats/conversation_store.dart`：新增 `applyPresence(Map<String, PresenceStatus>)`，仅在状态变化时通知。
- [x] `app/lib/app/shell.dart`：`_presenceTimer`（20s）+ `_refreshPresence` + `ValueNotifier<Map<String, bool>> _presence`；`dispose` 取消；`ContactsPage` 传入。
- [x] `app/lib/features/contacts/contacts_page.dart`：好友头像显示在线/离线状态点（未知状态不显示）。
- 验收：`cd app && flutter analyze` 无新增错误。

## T6 重建两端并验证在线状态

- [x] 重建 macOS release（复制 dylib + 临时签名）并启动。
- [x] 重建并安装 Android APK（无线 adb）。
- [x] 关闭 Android 应用 → Mac 40～60s 内转离线；重开 → 20s 内转在线。
- [x] 反向：关闭 Mac → Android 转离线；重开 → 转在线。
- [x] 联系人列表、会话列表、聊天头部三处状态一致。

## T7 语音/文字回归（最终复测）

- [ ] Mac → Android 语音：接听后双方有声，3s 内「通话中」。
- [ ] Android → Mac 语音：同上；静音/取消静音生效；挂断两端同步。
- [ ] 三端文字消息正常收发；好友申请/备注正常。
- [ ] 截图与日志归档到 `/tmp/nexmem-e2e/`。

## T8 通话失败可见化与对端名称解析

- [x] `call_service.dart`：`_send` 失败向 UI 上报；`startOutgoing` 媒体/信令失败 → `CallState.ended(failed)`。
- [x] `shell.dart`：`_onRtcSignal` 按 `dm:<peer>` + 遍历 `item.peer` 解析名称。
- [x] `shell.dart`：拨打失败弹 SnackBar（媒体不可用 / 对方不可达）。
- 验收：拒绝麦克风权限后发起语音，主叫出现明确错误提示。

## T9 通话状态扩展：结束原因 + 计时

- [x] `call_service.dart`：新增 `CallEndReason`、`CallInfo.endReason/startedAt/elapsed`；`endCall({reason})`；结束时保留 1.5s 快照。
- [x] 主叫 45s 振铃超时 → `noAnswer`；接听/connected 取消超时定时器。
- [x] 被叫拒绝 → `rejected`；呼叫中挂断 → `canceled`。
- [x] 新增 `end` 信令（`rtc_signal.dart`），拒绝/取消/挂断即时同步对端。

## T10 来电页 QQ 化（含视频接听按钮）

- [x] `call_page.dart`：来电全屏头像 + 昵称 + 「邀请你进行视频/语音通话」+ 底部固定红色拒绝 / 绿色接听（视频显示「视频接听」）。
- [x] 按钮移出视频视图覆盖区域；视频小窗仅 connected 后显示。
- [x] 呼叫中显示「正在呼叫…」+取消；接通后 `mm:ss` 计时（`StatefulWidget` + 1s Timer）。
- [x] 结束态展示结束原因文案。
- 验收：视频来电按钮可点、接听成功；小屏不遮挡。

## T11 来电铃声/振动与通话记录

- [x] `call_page.dart`：来电每 2s 系统提示音 + 移动端振动，离开来电态停止（≤30s）。
- [x] `shell.dart`：`_appendCallRecord` 用 `ChatStore.receive` 写入通话记录（接通/未接/拒绝/取消/失败）。
- 验收：双方会话结束各出现一条记录；被叫未接也能看到「未接来电」。

## T12 重建与两端实测

- [ ] `cd core && go build -buildmode=c-shared -o ../bin/libnexmem.dylib ./ffi/capi`，复制进 Mac .app 并 `codesign --force --deep --sign -`。
- [ ] `flutter build macos --release`；`make android-aar` + `flutter build apk --debug` 安装。
- [ ] Mac → Android、Android → Mac 各测语音/视频：来电可见、可接听、双方有声、计时、静音、挂断、通话记录。
- [ ] 回归在线状态与文字消息；日志归档 `/tmp/nexmem-e2e/`。
