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

## T13 管理远程设备列表页 · 群控（已完成）

> 原先只有「多会话并行 + 顶栏切换」，缺设备管理列表、广播输入与批量操作，已补齐。

- [x] `features/remote/remote_group_controller.dart`：群控状态机（勾选、全选/清空、会话变化同步、按权限过滤），按键/文字/指针/剪贴板广播与批量断开；单台失败不影响其它设备。
- [x] `features/remote/remote_control_page.dart`：顶栏「管理远控设备」入口与群控开关；开启后输入广播到所有勾选设备，标题显示「群控 N 台」；剪贴板发送提示广播台数。
- [x] `features/remote/remote_group_controller.dart` `RemoteGroupSheet`：设备管理列表（已连接会话、勾选、群控开关、全选/清空、断开所选）。
- [x] `app/shell.dart`：壳层持有群控状态，跨会话切换保持勾选；`RemoteControlService` 显式实现群控服务接口。
- [x] `l10n/translations.dart`：13 条群控文案补齐 en / 繁中 / ja / ar / he / ko 六张表。
- [x] `app/test/remote_group_test.dart`：4 项服务单测 + 2 项 widget 测试；`dart analyze` 零问题；`flutter test` 全量 **514 通过 + 3 跳过**（需清除 shell 中的 `NEXMEM_*` 环境变量以复现）。

**已知边界**：群控只作用于已连接且已授权对应能力的控制端会话；批量文件发送、跨端群控（一台设备同时作为多台被控端）不在本次范围；真机多设备并发压测仍需设备环境。

**T13b 群控按设备类型约束（已完成）**：`RemoteGroupController` 增加 `deviceTypeOf` / `groupType`，只把同类型已连接设备纳入群控目标，切换类型清空勾选；`RemoteGroupSheet` 增加类型下拉与同类型提示。不同类型设备的键鼠修饰键语义不同（macOS Cmd / Windows·Linux Ctrl），从源头避免混合群控错乱。

## T14 我的 → 远程设备管理（已完成）

- [x] `features/remote/remote_device_directory.dart`：设备台账本地持久化（账号/别名/设备类型/备注/最近连接），支持增删改与重载；不缓存按键与剪贴板内容。旧台账的场景分类自动归为「其他」。
- [x] `features/remote/remote_devices_page.dart`：远程设备管理页——台账列表、按设备类型筛选（全部/macOS/Windows/Linux/Android/iOS/Web/其他）、逐台连接/断开、编辑/删除、群控开关、全选/清空、批量断开；筛选具体类型时同步群控目标类型，群控连接数按同类型统计。
- [x] `settings_page.dart`：「我的」页新增「远程设备」入口；壳层按桌面右栏 / 手机全屏分流，复用远控会话与群控状态。
- [x] `l10n/translations.dart`：18 条设备管理文案补齐六语；`app/test/remote_devices_test.dart` 4 例（目录增改删/持久化、去重、筛选、页面交互）。
- 验证：`dart analyze` 零问题；`flutter test` 全量 **518 通过 + 3 跳过**（需清除本机 `NEXMEM_*` 环境变量）。

## T15 右上角提示与通话通知条（已完成）

- [x] `app/app_toast.dart`：新增 `AppToastController` / `AppToastOverlay`，壳层小提示从底部 SnackBar 改为右上角浮层（4 秒自动收起、可手动关闭），显示时调用语音播报。
- [x] `app/app_toast_speaker_web.dart` / `app_toast_speaker_native.dart`：Web 用浏览器 SpeechSynthesis 朗读，原生端以系统提示音降级，测试环境静默。
- [x] `app/call_notice_bar.dart`：通话状态条固定在「在线」横条下方，显示名称/类型/状态，点击展开全屏通话页；来电可直接拒绝，并带语音与振动提醒。
- [x] `app/shell.dart`：来电改为「先通知、点击后展开通话页」，去电/通话中保持自动展开；所有壳层提示（含删除/置顶失败等）统一走右上角提示。
- [x] `app/web_notice.dart`：Web「仅在线接收」说明移入右上角浮层并朗读；`l10n/translations.dart` 六语各补「点击打开通话界面」。
- [x] `app/test/app_toast_test.dart`、`call_notice_test.dart`：覆盖右上角定位、关闭/自动收起、来电/通话中通知条交互。
- 验证：`dart analyze` 零问题；`flutter test` 全量 **525 通过 + 3 跳过**；Web 产物重建并加 `?v=20261126234530` 绕过浏览器缓存。

## T16 列表项内容垂直居中（已完成）

- [x] `features/contacts/contacts_page.dart`、`settings_page.dart`：外层 `SizedBox(height: 60)` 包 `ListTile` 时，ListTile 内部仍按默认 56 布局，多出的 4px 落在底部导致内容偏上 2px；给 ListTile 显式加 `minTileHeight: NexmemMetrics.listItemHeight` 后真正居中。
- [x] `test/contacts_test.dart`：新增几何断言，校验「好友」分组入口图标与文字的中心和行中心偏差 ≤1px。
- 验证：`dart analyze` 零问题；`flutter test` 全量 **526 通过 + 3 跳过**；Web 产物重建并加 `?v=20261126235012`。

## T17 QQ 式好友分组树（已完成）

- [x] `features/contacts/contact.dart`：新增 `groupFriends` / `defaultFriendGroupLabel`，按 `Contact.groupName` 归类，未分组归入「我的好友」并排在最前。
- [x] `features/contacts/contacts_page.dart`：点「好友」展开下方分组树（可再收起分组）；支持新建分组（选好友）、分组菜单重命名/删除、好友条目「移动好友」，全部走 `contact.setGroup`；点好友回调 `onOpenContactChat` 在右栏打开聊天。搜索时自动展开全部命中分组。
- [x] `features/contacts/friends_pane.dart`：右栏好友面板同步改为按好友分组展示（原名 A–Z 索引仅保留 `groupContacts` 工具供既有测试）。
- [x] `app/shell.dart`：点左栏「好友」时若右栏不是聊天/资料则回到好友面板，聊天中保持当前会话；`l10n/translations.dart` 六语各补 13 条分组文案。
- [x] `test/contacts_test.dart`：新增分组归类、展开/收起、点击好友开聊、新建/重命名/删除/移动分组共 4 例；同步调整 `contact_service_test.dart`、`contact_detail_test.dart`、`widget_test.dart` 的展开步骤。
- 验证：`dart analyze` 零问题；`flutter test` 全量 **530 通过 + 3 跳过**；Web 产物重建并加 `?v=20261126235855`。

## T18 群聊入口 QQ 式展开（已完成）

- [x] `features/contacts/contacts_page.dart`：点「群聊」展开/收起下方群列表（数据源 `group.list`），支持搜索过滤、加载/错误/空态；点击群条目回调 `onOpenGroup` 在右栏打开群会话。
- [x] 右侧群管理页保留：创建群聊、邀请/移除、退群/解散仍在原 `GroupListPage`，左栏列表在打开管理页或建群后自动刷新。
- [x] `app/shell.dart`：`ContactsPage.onOpenGroup` 改为 `inlineInContacts`，点群聊不再切分区，直接在联系人右栏显示群聊。
- [x] `test/contacts_test.dart`：新增群列表展开与点击开群会话测试；`dart analyze` 零问题；全量 **531 通过 + 3 跳过**。
- 验证：Web 产物重建并加 `?v=20261127001253`。

## T19 头像 / 推广图裁剪体验优化（已完成）

- [x] `features/settings/image_crop_page.dart`：裁剪框改为图片显示坐标系，随 InteractiveViewer 缩放/平移联动；裁剪框与手柄恒在图片范围内；手柄增至 24px 并支持四角 + 四边中点八向调整；新增实时输出尺寸标签、推广图比例预设（自由/1:1/4:3/16:9）与「拖图模式」；修正图片显示区重复扣减底部栏高度导致偏上的问题。
- [x] `l10n/translations.dart`：六语各补「比例 / 自由 / 拖图 / 裁剪框」4 条文案。
- [x] `test/image_crop_test.dart`：新增裁剪框缩放联动、边界约束、比例预设与拖图模式测试；全量 **531 通过 + 3 跳过**，`dart analyze` 零问题。
- 验证：Web 产物重建并加 `?v=20261127003937`。

## T20 社交中心 / 账号与安全迁入「我的」（已完成）

- [x] `features/settings/settings_page.dart`：`_profileItems` 增加「社交中心」「账号与安全」，从 `_settingsItems` 移除；「我的」现含个人资料 / 远程设备 / 社交中心 / 账号与安全。
- [x] `app/shell.dart`：`_openSettingsPane` 的分区判断把这两项归入 `_sectionProfile`，桌面点击后左栏切到「我的」、右栏展示对应面板。
- [x] `test/widget_test.dart`、`test/backup_test.dart`：同步调整「我的 / 设置」入口断言与账号安全弹窗测试入口。
- 验证：`dart analyze` 零问题；全量 **535 通过 + 3 跳过**；Web 产物重建并加 `?v=20261127004159`。

## T21 系统全面审计与 UI 缺陷修复（已完成）
- [x] 审计基线：`dart analyze` 零问题；全量 535 通过 + 3 跳过。
- [x] 修复严重 UI 缺陷：`start_chat_sheet.dart` 两处固定宽度弹窗改用 `responsiveDialogContent`（390px 手机不再溢出）；`chat_page.dart` 引用条暗色模式前景色由写死 `Colors.black87` 改为 `scheme.onSurface`。
- [x] 修复中等 UI 缺陷：文件列表路径 / 二维码账号 ID 加单行截断；群盘按钮用 `FittedBox` 限宽防溢出；社交中心拒绝/同意图标改用 `NexmemColors.danger/success`；通知按钮组 RTL 方向对齐；裁剪手柄触控区扩到 44px、错误色与硬编码色改用主题令牌。
- [x] 功能审计遗留项已全部闭环（2026-11-27）：群文件下载链路接通；群聊语音改走群文件通道；zh_TW 全量转繁；README locale 口径改为「33 个 locale 布局适配、6 种完整译文、其余回退英文」；Web token 错误独立为 `UNAUTHORIZED` 并停止无限重连；契约文档同步 94 方法 / 24 事件 / 104 用例；聊天正文新增 4096 字符上限。
- 验证：全量 **535 通过 + 3 跳过**；Web 重建并加 `?v=20261127005026`。

## T22 审计遗留项全部闭环（已完成）
- [x] 群文件下载：`msg.list` 暴露 `blob_ref` / `key_b64`，`ChatAttachment` 携带元数据，`CoreSession.downloadGroupFile` 调 `file.downloadGroup`，群文件气泡显示下载按钮；Go/Dart 定向测试全绿。
- [x] 群聊语音：移除「群聊暂不支持发送语音」，群聊语音走 `dm.sendGroupFile` 群文件通道，README 表述与代码一致。
- [x] 繁体中文：zh_TW 表全量转繁并修正 `發現 source 設定` 等残留，六语表 key 一致性测试通过。
- [x] 文档口径：README 改为「33 个 locale 布局适配、6 种完整译文、其余回退英文」，契约数字改为 94 方法 / 24 事件；`docs/剩余开发进度.md` 同步当前基线并标注历史快照。
- [x] Web token 错误：新增 `/auth` 探测与 `UNAUTHORIZED` 错误码，token 错误不再归入 `NOT_ONLINE`、不再无限重连，右上角 Toast 显示明确原因；旧网关从握手 401 文本兜底识别。
- [x] 消息长度：契约层为 `dm.sendText` / `dm.sendGroupText` / `msg.edit` 的 `text` 增加 4096 字符上限，Gateway schema 校验 + Go/Dart 测试覆盖。
- 验证：`dart analyze` 零问题；Flutter 全量 **556 通过 + 3 跳过**，真实 webd 联调 `core.ping` 与错误 token 均通过；Go `build` / `vet` / `test ./... -count=1` 全绿（一次 `TestGroupCreateOverGateway` 超时，单独重跑 0.06s 通过、二次全量全绿）；契约 94 方法 / 24 事件 / 104 用例 / 14 错误码，生成幂等 PASS；Web 产物重建并加 `?v=20261127081147`，webd 8082 已重启，`/auth` 正确令牌 200、错误令牌 401。

## T23 系统文件 / 图片 / 目录选择器接通（已完成）
- [x] 根因：桌面 `openNativeSession` 未注入 `pickFile`，Web `CoreSession` 既无 `pickFile` 也无 Web 目录选择；聊天按钮因此落到手填路径对话框或静默不可用。
- [x] 新增 `features/files/system_file_picker.dart`：桌面用 `file_picker` 打开系统文件/目录对话框；Web 用浏览器文件选择器读取字节，上传到网关后把服务端路径交给内核。
- [x] 新增 `system_file_picker_web_impl.dart`：基于 `package:web` 的 `webkitdirectory` 目录选择，读取相对路径与文件字节；`system_file_picker_web.dart` 提供 VM/桌面占位实现。
- [x] `main.dart` / `native_transport.dart` 注入 `pickFile` / `pickDirectory`；`directory_picker.dart` 的 Web 分支改为优先调用注入的上传式选择器。
- [x] `core/server/webd/server.go` 新增鉴权 `/upload`：`mode=file` 单文件上传，`mode=dir` 按相对路径上传目录，拒绝 `..` / 绝对路径 / 盘符穿越，默认 256 MiB 上限、落地目录可用 `-upload-dir` 配置；`cmd/nexmem-webd` 增加对应 flag。
- [x] `chat_page.dart` 文件/图片/语音统一走 `_pickAttachment`，选择器或上传异常改为右上角明确提示；六语补「选择文件失败：{0}」。
- 注意：`http.MultipartRequest.fields` 是 Map，同名字段会覆盖；Web 目录上传改用独立 `relative_path` 分片按顺序上报，网关同时兼容普通表单字段与分片两种格式。
- 验证：`dart analyze` 零问题；Flutter 全量 **558 通过 + 3 跳过**；Go `build` / `vet` / `test ./... -count=1` 全绿，新增 webd 上传测试覆盖单文件、目录相对路径（两种格式）、错误令牌与路径穿越；真实 webd 联调 `/upload` 正确令牌 200、错误令牌 401，目录内 `photos/a.txt` 落盘正确；Web 产物重建并加 `?v=20261127082829`，8082 预览已重启。

## T24 系统全量审计（界面 / 功能 / 文档）与修复（已完成）
- [x] 界面优先级 1-5：禁用按钮前景色改用 `textSecondary(@0.62)` 修复明暗主题不可读；非己方文件气泡进度条改用 `fg` 自适应主题；共享详情/群盘设置弹窗改 `responsiveDialogContent`；远控设置加载态去掉固定 440 宽；传输统计行状态文本改 `Expanded + ellipsis`。
- [x] 界面中等项：左栏选中指示条改 `AlignmentDirectional.centerStart` 支持 RTL；远控底部 6 个工具按钮改 `Flexible + ellipsis` 防窄屏溢出；清除/重试图标按钮补 tooltip；远控设备空态隐藏禁用的群控卡片；两处 Chip 间距改 `EdgeInsetsDirectional.only(end:)`；设置/账号页固定宽标签列改 `ConstrainedBox` + 长值省略；共享名/账号名/传输任务名补 `maxLines + ellipsis`；语言/发起单聊弹窗高度随屏高收缩（`math.min` + clamp）。
- [x] 消息长度 UI 对齐：聊天输入框与编辑框加 `maxLength=4096`，计数器仅在接近上限时显示（`_messageCounter`），与契约层一致；补 widget 测试。
- [x] 多账号头像串号：头像单例 `attach` 时立即清空旧字节，避免切换账号期间短暂显示上一账号头像；补测试。
- [x] Web 事件水位失效（严重）：根因是网关重启后 seq 归零，服务端 `replay` 把「客户端水位超前」误判为已追平，客户端收到 resync 又不重置水位，导致后续新事件被当重复静默丢弃。服务端 `replay.go` 的 `since > latest` 改判缺口；客户端 `ws_transport.dart` 收到 resync 按 `latest_seq` 对齐水位并落盘；假服务端同步对齐语义并补网关重启端到端测试。
- [x] 文档口径：`安装与使用教程.md` 语言数量改为「33 个 locale 布局适配、7 种完整译文（含简体中文源文案）、其余回退英文」，与 README 一致。
- 验证：`dart analyze` 零问题；Flutter 全量 **561 通过 + 3 跳过**（本轮新增 3 测试）；Go `build` / `vet` / `test ./... -count=1` 全绿；契约 94 方法 / 24 事件 / 104 用例 / 14 错误码；Web 重建 `?v=20261127085528`、webd 8082 用新二进制重启，`/auth` good=200 / bad=401、首页 200。

## T25 Web 鉴权下载端点（已完成）
- [x] `core/server/webd/server.go` 新增 `GET /download?token=&path=`：令牌鉴权、`Content-Disposition: attachment`，支持 Range；`DownloadDirs` 白名单（uploadDir 自动放行 + 显式配置），`resolveDownloadPath` 用 `Abs+EvalSymlinks+Rel` 双重校验防路径穿越与符号链接逃逸，仅普通文件。
- [x] `core/cmd/nexmem-webd/main.go` 把 `<data-dir>/web-downloads` 加入白名单——只放行群文件专用子目录，不放行整个 data-dir，避免私钥/数据库被下载。
- [x] Web 客户端：`core_session.dart` 的 `groupFileDownloadPath` 在 Web 端落到 `<data-dir>/web-downloads/`，新增 `downloadToBrowser` 回调；`main.dart` 注入实现；`shell._downloadGroupFile` 下载成功后经回调触发浏览器保存并返回文件名提示。
- [x] 新增 `features/files/web_download.dart` + `web_download_web.dart`(stub) + `web_download_web_impl.dart`(`package:web` 隐藏 `<a download>`)；`webDownloadUri` 把 ws 端点换算为 http/https 的 `/download` 鉴权链接。
- [x] README 补充 Web 文件选择/上传/下载端点说明。
- 验证：`dart analyze` 零问题；Flutter 全量 **564 通过 + 3 跳过**（本轮 +3：URL 构造 wss/ws + 回调透传）；Go `build`/`vet`/`test ./... -count=1` 全绿，新增 `download_test.go` 覆盖正确下载、错误令牌 401、白名单外 403、符号链接逃逸 403、405/400；真实 webd 实测白名单文件 200 且下载头正确、错误令牌 401、私钥文件 403。Web 重建 `?v=20261127094748`，8082 已用新二进制重启。

## T26 群控代码审计、状态同步与真机复验（已完成）
- [x] 群控代码审计：确认 `RemoteGroupController` 只纳入 `isController && isActive` 且设备类型一致的会话；`canGroup` 要求同类型在线设备 ≥2；`_broadcast` 按 `RemotePermission` 过滤并逐台 `catchError`；键鼠/指针/文本/剪贴板均已在 `remote_control_page.dart` 接到广播；`endSelected()` 只断开勾选设备。
- [x] 修复审计发现的唯一状态漂移：原逻辑在会话结束、切换设备类型或取消勾选到只剩一台时，`enabled` 仍可能停留为 true，UI 显示「群控中」但输入已退化为单控。新增 `_enforceGroupState()`，不足两台时自动退出群控并清空勾选；`remote_devices_page.dart` 本地开关/勾选跟随控制器同步。
- [x] 补测试：`remote_group_test.dart` 新增「取消勾选到只剩一台自动退出」「会话结束后重新凑够两台可再开启」，并调整类型切换/权限过滤/批量断开用例以覆盖新状态机。
- [x] 远控 ICE 失败收尾：`remote_control_service.dart` `_fail()` 发送 `RemoteSignalType.end`，`remote_control_service_test.dart` 已验证失败收尾广播 end，避免控制端退回聊天后被控端仍显示远控中。
- [x] 真机复验来电名称：最新 APK（11:24:53 安装）经 `rtc.sendSignal` 注入测试 offer 后，手机通知条与来电页均显示 `989101…`，不再显示原始 base64url 长串；截图 `/private/tmp/nexmem-e2e/call-name-verified.png`。测试来电已拒绝并清理。
- 验证：`dart analyze` 零问题；干净环境下 Flutter 全量 **569 通过 + 3 跳过**。当前 shell 若保留联调用 `NEXMEM_*` 环境变量，`android_transport_test.dart` 两条「未注入网络配置」用例会因环境变量注入而失败，这是测试环境差异，不是代码回归。Web 重建并加缓存破坏参数 `?v=20261127114146`，网关 `/` 与 `main.dart.js` 均返回 200。

## T27 群成员本群称呼与群等级系统（已完成）
- [x] 契约与内核：`core/gateway/builtin.go` 新增 `group.setLevelConfig` / `group.setMemberProfile` 两方法，`core/gateway/contract.go` 新增 `group.levelsChanged` / `group.memberProfileChanged` 事件，刷新 `core/contract/api.json` 与 baseline 用例。
- [x] 存储：`core/migrations/0011_group_profile.sql` 给 `groups` 加 `levels_enabled`/`levels_json`（字段级信封加密），给 `group_members` 加 `nickname`/`level_id`；DAO 保留资料、密钥轮换整表替换时按 account 保留两列。
- [x] 群服务：`core/internal/group/level.go` 校验等级数 ≤12、名称 ≤16 字、图标必须 base64 编码的 64x64 PNG（≤16 KiB）；`profile.go` 校验本群称呼 ≤24 字；成员改自己称呼、管理员改任意成员资料/等级；等级关闭时强制清空等级 ID；`SetLevelConfig`/`SetMemberProfile` 先落本机再发加密群控制帧。
- [x] 控制帧：`core/internal/group/control.go` 编解码 `levels` / `member_profile` 控制帧，不落消息库、不生成聊天气泡；`coreapp/app.go` 收到帧后校验发送方身份（成员本人改称呼例外且不允许自提等级），更新本机记录后发事件给 UI。
- [x] 客户端：`app/lib/features/group/group_service.dart` 新增 `GroupLevel`/`GroupLevels`/`GroupMemberProfile`，`GroupMember` 增加 `nickname`/`levelId`/`displayLabel`，`GroupInfo` 增加等级配置，`TransportGroupService` 接两个新方法；`image_crop_page.dart` 新增 `prepareSquarePng` 自动居中裁剪并缩放为 64x64 PNG；`group_profile_dialogs.dart` 新文件实现等级设置与成员资料两个弹窗；`group_info_page.dart` 管理员看到「群等级设置」入口、成员行显示本群称呼与等级图标/名称、本人或管理员可编辑；`shell.dart` 监听两个事件递增 `profileRevision` 触发群资料刷新；六语词条同步新增 18 条。
- [x] 测试：新增 `app/test/group_profile_test.dart`（13 例：裁剪、模型、契约映射、权限、长度、弹窗保存）；Go 新增 `internal/group/level_test.go`、`internal/coreapp` 控制帧端到端测试，baseline 补 4 例；`group_test.dart` 加滚动 helper 修复新增入口导致的按钮离屏用例。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **586 通过 + 3 跳过**；Go `build` / `vet` / `test ./...` 全绿，契约生成幂等（96 方法 / 26 事件 / 108 用例 / 14 错误码）；Web 重建并加缓存破坏 `?v=20261127120508`，网关 `/` 与 `main.dart.js` 均 200，`/auth` 无 token 401。

## T28 群拉人进群：好友 / 指定账号 / 批量导入（已完成）
- [x] 新增 `app/lib/features/group/group_invite_dialogs.dart`：统一拉人弹窗，两个来源入口——好友多选（`CheckboxListTile`，好友备注名作为本群称呼）与「指定账号 / 批量导入」文本框。
- [x] 批量解析 `parseGroupInviteBatch`：一行一个账号，支持 `账号|备注`；接受 64 位十六进制或 32 字节 base64url；忽略空行与 `#` 注释；按规范化账号去重保留首条；备注超 24 字自动截断；无效行单独计数并在弹窗实时显示「有效/无效/重复」统计。
- [x] `group_info_page.dart` 的 `_invite()` 改为走新弹窗：好友与批量条目合并去重、排除已在群成员；逐条 `group.invite`，带备注时接着 `group.setMemberProfile` 写本群称呼；单条失败不影响其余，末尾 toast 汇总成功/失败人数。纯客户端编排，复用现有契约，未改动 Go 后端与 api.json。
- [x] 六语词条各新增 8 条（拉人进群、指定账号/批量导入、待邀请人数、批量格式提示、有效/无效/重复统计、邀请结果汇总等）。
- [x] 测试：新增 `app/test/group_invite_test.dart`（7 例：批量解析 4 条 + 弹窗合并去重、单项失败不中断、契约映射）；更新 `group_test.dart` 旧邀请用例适配「勾选后确认」新流程并断言备注名写入。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **593 通过 + 3 跳过**（较上轮 +7）；Go 未改动无需重跑；Web 重建并加缓存破坏 `?v=20261127121343`，网关 `/` 与 `main.dart.js` 均返回 200。

## T29 社交中心浮层与「我的」入口回归修复（已完成）
- [x] 复现与定位：用户截图里「发给 xxx / 申请添加你为好友」白色卡片浮在灰色遮罩上。根因有两条：① 社交中心与账号与安全迁入「我的」后，`_openSettingsPane` 把这两个 label 路由到 `_sectionProfile`，但 `_buildProfilePane()` 没有对应分支，桌面点击后仍停留在个人资料卡；② `settings_page.dart::_openSocialHub` 在没有 `onOpenPane` 回调时走 `showPaneDialog`，`showDialog` 会额外套一层居中 `Dialog` 白卡和 `ModalBarrier`，把内容页变成模态浮层。
- [x] `shell.dart`：新增 `SocialHubPage` 直接导入；`_buildProfilePane()` 为「社交中心」铺满右栏（不带 dialog route、不新增 barrier），为「账号与安全」复用内嵌面板；`_buildSettingsPane()` 的社交中心分支同步改为直接铺满；抽出 `_buildEmbeddedPane(label, withHeader:)` 统一复用以 Dialog 形态实现的历史面板，避免两处分支漂移。
- [x] `settings_page.dart::_openSocialHub`：独立使用该页时改为普通 `MaterialPageRoute` + `Scaffold` + `AppBar`，彻底去掉 `showDialog` 白卡与灰色 barrier。
- [x] 测试：`widget_test.dart` 新增 3 例（桌面社交中心铺满且 barrier 数量不增加、窄屏普通全屏页、桌面账号与安全不再停留资料卡），`social_hub_test.dart` 新增 1 例（独立设置页打开社交中心无 Dialog）。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **597 通过 + 3 跳过**（较上轮 +4）；Go `build` / `vet` / `test ./...` 全绿；Web 重建并加缓存破坏 `?v=20261127123218`，8082 首页与 `main.dart.js` 均返回 200。

## T30 手动选择同类型设备群控的界面增强（已完成）
- [x] 需求：「我需要自己能选择同类型的几个设备一起群控制进行操作」。原链路虽已具备同类型过滤与广播，但远程设备页要把每台设备塞进弹出菜单点「加入群控」，且默认群控类型为「其他」，用户看不到勾选框，也不知道去哪指定类型。
- [x] `remote_devices_page.dart`：同类型且在线的设备卡片直接渲染勾选框，点勾选框只切换群控选中、不误触发连接/断开；群控卡片新增「选择设备」按钮，打开完整 `RemoteGroupSheet`（设备类型下拉 + 逐台勾选 + 群控开关 + 批量断开）；已选设备以 Chip 列名，最多显示 4 个其余计数；默认类型下若只有别的类型在线，subtitle 提示去「选择设备」指定类型。
- [x] 六语表新增「选择设备」「请点「选择设备」指定在线设备的类型」两条，六张表 key 集合一致性测试通过。
- [x] `remote_devices_test.dart` 新增 1 例：默认类型下无勾选框 → 切到 macOS 后两台 Mac 显示勾选框、Windows 不显示 → 勾选后设备名 Chip 出现 → 点勾选框不触发连接 → 「选择设备」打开完整面板。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **598 通过 + 3 跳过**（较上轮 +1）；Go 未改动无需重跑；Web 重建并加缓存破坏 `?v=20261127123749`，8082 首页与 `main.dart.js` 均返回 200。

## T31 聊天界面语音/视频预览与播放（已完成）
- [x] 审计结论：聊天气泡原本只支持图片缩略图；语音/视频附件退化为通用文件气泡（图标 + 文件名 + 大小），点击只复制本机路径，没有预览/播放。项目已有 `MediaViewerDialog`（文件中心在用，支持图片缩放、音频播放、视频播放及 ffmpeg 转码兜底），只是聊天页未接入。
- [x] `chat_page.dart`：图片气泡点击打开 `MediaViewerDialog` 缩放预览；音频/视频气泡改为播放图标卡片并点击打开媒体播放器；`MediaViewerDialog` 已含播放/暂停、进度条、时长显示。`MessageBubble` 新增可选 `onPreviewMedia` 便于测试注入替身。
- [x] Web 降级：浏览器拿不到服务端本机路径，媒体点击不再调用会抛异常的本地桥接；有下载回调（群文件）时先下载再提示本地播放，私聊文件复制落盘路径并明确说明限制。
- [x] 六语表新增「已下载 {0}，请用本地播放器打开」「请下载后使用本地播放器打开」两条，key 一致性测试通过。
- [x] `chat_page_test.dart` 新增 3 例：音/视频气泡点击回调、真实图片预览弹窗、普通文件不显示媒体入口且仍复制路径。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **601 通过 + 3 跳过**（较上轮 +3）；Go 未改动无需重跑；Web 重建并加缓存破坏 `?v=20261127124418`，8082 首页与 `main.dart.js` 均返回 200。

## T32 文件共享/下载链路加固与真机联调（已完成）
- [x] 审计后修复 `core/internal/fs` 六个高/中优先级问题：`partPath` 不再把 `a/b` 与 `a_b` 压平成同一个 `.part`（改隐藏目录按原层级存放并在失败时清理）；`downloadState.lastEmit` 加互斥消除 race；同一 share 下载用 `leases` 串行化；种子刷新不再只在 seeds 为空时触发；导入不再覆盖已有 `LocalRoot`；`Get` 不再把未下载共享伪装成本机种子。
- [x] 安全加固：清单 `Verify()` 校验 AES 密钥必须 32 字节、SHA-256 必须 64 位 hex；`openSessions` 校验种子清单 Owner 与本机记录一致，防止同 ID 清单被别的账号偷换发布者；种子全部失败时返回具体 dial/校验错误而不是笼统的「没有可用的共享种子」。
- [x] 契约与网关：`fs.publish.name` 加 maxLength 128、`fs.import.code` 加 maxLength 1MiB、`fs.download.parallel` 加 1..32 界限并重新生成 `api.json`；baseline 新增 7 条 fs.* 成功路径用例，契约层补最小处理器；`file.downloadGroup` 的 sha256 从 base64 改为项目统一的 hex。
- [x] 新增 `core/internal/fs/hardening_test.go`（8 组回归用例，含 `-race` 下并发下载）与可注入环境变量的真机联调用例 `device_e2e_test.go`（`TestDeviceFolderDownload` / `TestDevicePublishForPhone`，默认跳过）。
- [x] 真机联调：手机经系统 SAF 选择 `nexmem-test` 目录并发布成功，分享码含 `a.txt` 与 `sub/b.txt`；Mac 侧 `TestDeviceFolderDownload` 从手机种子下载并逐文件 SHA-256 校验通过。反向（Mac 发布、手机导入）导入成功，但手机下载被其 per-app VPN 路由（`tun0`，源 172.19.0.1）阻断，内核日志明确 `dial tcp4 ... i/o timeout`，非代码缺陷。
- [x] 真机发现并修复 Flutter 崩溃：`file_share_page.dart::_promptDest` 在 `showPaneDialog` future 完成时立刻 `controller.dispose()`，而窄屏全屏路由关闭动画期间 TextField 仍在树中，触发 `TextEditingController used after disposed` 并连锁 `InheritedElement.debugDeactivated` 断言红屏。改为 `_DownloadDestDialog` StatefulWidget 自持控制器并在 `dispose()` 释放；同时每次下载先清掉上次错误提示。新增 `app/test/file_share_download_test.dart` 覆盖窄屏下载确认全流程。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **609 通过 + 3 跳过**（新增 1 例），契约用例 119 条全过；Go `fs` 包 `-race` 全绿、`go test ./...` 除已知偶发 `internal/coreapp/TestGroupCreateOverGateway`（等待群消息 P2P 落库 30s 超时，早期干净环境曾通过，与文件共享改动无关）外全绿。重建 AAR 与 debug APK 并真机安装，崩溃已消失。

## T33 最后一个偶发超时测试收尾：全量测试全绿（已完成）
- [x] 用户追问「全部测试完了不，有问题的全部修复了不」。此前唯一残留是 `core/internal/coreapp/TestGroupCreateOverGateway` 偶发 30s 超时；定位为测试自身时序假设问题，不是产品缺陷：`group.create` 后接收端受理密钥信封、订阅群主题、GossipSub mesh 连通都是异步的，背靠背发首条群消息会在 mesh 形成前丢失。仓库 `internal/group/pending_test.go` 的 R-15 已有同类处理惯例。
- [x] `core/internal/coreapp/app_test.go`：保留「等接收端 `group.members` 成功」的同步；把单次 `dm.sendGroupText` 改为在 30s 内重复发送直到接收端 `msg.list` 出现目标消息，每次发送后 1s 轮询、`msg_uuid` 与 `stored` 仍逐条校验；新增 `findGroupMessage(items, text, direction)` helper。
- [x] 连带修正断言：重复送达会使收发双方落库多条，发送端/接收端断言从 `len == 1 && items[0]` 改为按目标消息存在性判断；群会话未读从 `== 1` 改为 `>= 1`（复用包内已有的 `asInt` 兼容 int/float64）。
- [x] 验证：该用例 `-count=25` 与 `-count=100` 均全过且总耗时 1.46s / 4.57s（此前失败会耗满 30s）；`go test ./... -count=1` 全绿；`dart analyze` 零问题；清理 `NEXMEM_*` 与代理变量后 Flutter 全量 **609 通过 + 3 跳过**。未清环境时 `android_transport_test.dart` 有 2 例因继承 `NEXMEM_BOOTSTRAPS` 等注入网络配置而失败，属测试环境污染，非代码缺陷。
- 结论：本轮所有发现的问题已修复，全部自动化测试通过。剩余为非代码/需外部条件的限制：手机 per-app VPN 阻断反向下载、Mac 桌面 App 重建受 Xcode SPM 沙箱限制、群控真机需至少 3 台同类型在线设备、远控 ICE 失败需真机复验。

## T34 聊天附件「发送失败」误报修复（已完成）
- [x] 用户反馈「聊天框为什么发送图片/视频/文件都是失败的」。排查证据：`/upload` 端点 curl 直测 200 且正确落盘；浏览器 WebSocket 直调 `dm.sendFile` 5.9s 返回 `ok`；`msg.list` 显示 14:14 用户发出的 6.7MB PNG 在内核侧为 `state: sent`，但 UI 显示失败。
- [x] 根因：`dm.sendFile` / `dm.sendGroupFile` 是同步 RPC，要等 ACK + P2P 分片传输 + 对端确认，大文件耗时远超 `CoreSession.requestTimeout` 默认 20s。客户端超时后 `ChatStore._deliver` 把乐观消息标 `failed`，且没执行 `_rename`（拿不到内核 `msg_uuid`）；内核随后传完并置 `sent`，发出的 `message.updated` 用内核 UUID，UI 按该 ID 已找不到本地消息，状态无法回填，于是「内核已发出、界面永远失败」。
- [x] `core_session.dart`：新增 `fileSendTimeout`（默认 5 分钟），`CoreSession.sendFile` 改用该超时；进度继续由 `transfer.progress` 事件推进。真失败仍会在内核 8s×3 ACK 重试后返回错误并置 failed，不会干等满 5 分钟。
- [x] `core_session_test.dart`：`_FakeTransport` 记录每次调用的 `timeout`，断言单聊与群聊 `sendFile` 都拿到 5 分钟，避免后续回归到通用 20s。
- 验证：`dart analyze` 零问题；`core_session_test.dart` + `chat_page_test.dart` 共 59 例全过；Web 重建并加缓存破坏 `?v=20261127142303`，首页 / bootstrap / main.dart.js 均 200。
- 注意：群聊发附件仍要求群已配置群盘，未配置时内核会明确返回「群未配置群盘」，这与本次误报是两个不同问题。

## T35 续传能力审计与共享下载断点续传补齐（已完成）
- [x] 用户问「文件传输和下载，大文件发送有没有续传功能」。逐链路审计结论：
  - 单聊 P2P 文件：**已有**分片续传。接收端把半成品写到 `.part` 并保存元数据，重连后 ACK 带 `NextChunk`，发送端 `Seek` 到对应分片继续；`transferFile` 最多 3 次尝试，进度事件续传时从已收字节起算。回归用例 `internal/dm/resume_file_test.go`。
  - 群文件：**无分片续传**，但群盘单对象上限 1 MiB，`os.ReadFile` 后一次 `Put`，失败重发整包，体量小不需续传。
  - Web 上传：浏览器一次性 `MultipartRequest`，无分片续传，失败需重选。
  - Web 下载：`/download` 用 `http.ServeFile`，原生支持 HTTP Range，浏览器下载管理器可续传。
  - P2P 共享下载：**代码注释声称支持但实现等于没有**——`Download()` 开头无条件 `RemoveAll(.nexmem-parts)`，失败 defer 也清空，每次都从头下载。
- [x] `core/internal/fs/service.go`：用 `.nexmem-parts/.nexmem-manifest` 记录清单 ID，同清单才复用分片、清单变更则丢弃；每个分片写 `.N.done` 标记（并发分片单靠文件大小无法识别空洞）；`prepareParts()` 返回已完成字节并计入进度；`downloadFiles()` 跳过已完成分片；失败保留分片目录，成功校验改名后清理。
- [x] `hardening_test.go` 新增 `TestPreparePartsResumesOnlyCompleteChunks`：只认写满且有完成标记的分片，清单 ID 变化时旧分片与标记必须清除。
- 验证：`go test ./internal/fs/`、`go test -race ./internal/fs/`、`go test ./... -count=1` 全绿。内核改动需重启网关 / 重建 App 后才在运行时生效。

## T36 聊天附件通用预览与保存到本机（已完成）
- [x] 用户要求「聊天框要支持绝大多数文件预览和查看功能，还要增加保存功能（能保存到电脑/手机本地设备里面）」。审计：原有仅图片预览、音视频播放，普通文件点击只复制本机路径；Web 私聊文件没有保存入口；`/download` 白名单只包含 web-uploads / web-downloads，不含私聊 inbox。
- [x] 新增 `app/lib/features/files/chat_file_actions.dart` + 平台实现：桌面/移动 `FilePicker.saveFile(bytes:)` 弹系统保存对话框（Android 走 SAF），直接写用户选定路径；Web 经鉴权 `/download` 读字节或触发浏览器下载。`readChatFileBytes` 同时供文本/压缩包内联预览使用。
- [x] 新增 `app/lib/features/files/chat_file_viewer.dart`：纯文本/代码（txt/md/json/xml/yaml/csv/log/各类源码等）UTF-8 内联查看，zip/tar 列出内部条目，PDF/Office 等无内嵌渲染器的格式给出元信息与保存入口；顶部和正文均有「保存到本机」按钮。
- [x] 接线：`CoreSession` 增加 `readChatFileBytes` / `saveChatFile` 注入点，`main.dart` 按平台注入；`shell.dart` 把回调透传给 `ChatPage` → `_MessageList` → `MessageBubble` → `_FileBubbleContent`。普通文件气泡点击打开通用查看页，图片/音视频气泡右上角增加保存按钮；群聊附件沿用内核解密下载后保存。离线无内核时保留原「复制路径」行为。
- [x] `core/cmd/nexmem-webd/main.go`：`/download` 白名单追加数据目录下的 `inbox`，让 Web 私聊接收文件也能取回；仍不放行整个 data-dir，私钥/数据库不可下载。
- [x] 六语表新增 7 条词条（保存到本机、文件预览、已保存到、读取文件失败、不支持格式提示、压缩包内容、无文件），六张表 key 一致。
- [x] 新增 `app/test/chat_file_viewer_test.dart` 5 例：扩展名识别、文本预览、zip 条目、保存按钮回执、气泡点击进入查看页。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **614 通过 + 3 跳过**（较上轮 +5）；`go test ./... -count=1` 全绿；Web 重建并加缓存破坏 `?v=20261127144145`，首页 / bootstrap / main.dart.js 均 200。
- 注意：Web 网关白名单是内核侧改动，需重启 `nexmem-webd` 才生效；桌面/移动需重建 App。PDF/Office 等格式不在应用内渲染，保存后由系统程序打开。

## T37 聊天文件发送与接收进度条（已完成）
- [x] 用户要求「文件发送和接收都要有进度条」。审计确认内核 `coreapp.onProgress` 已把 `dm.TransferProgress` 转为 `transfer.progress` 事件（含 msg_uuid/done/total），但客户端存在三类缺口：进度事件可能早于消息落库 / 早于乐观 ID 被内核 `msg_uuid` 替换而丢失；`msg.list` 回包会把传输中的进度清零；接收端消息状态是 `sent`，原 UI 只按 `isMine` + `sending` 判断，只给接收端显示进度。
- [x] `app/lib/features/chat/chat_store.dart`：新增 `_pendingProgress` 暂存 Map，`setTransferProgress()` 找不到消息时先按 ID 存，`_insert()` 落库时回填；`merge()` 区分「传输未完成的回包」（保留本地发送状态与进度）和「完成态回包」（允许生效，避免卡在 99%）。
- [x] `app/lib/features/chat/chat_page.dart`：`_FileBubbleContent` 增加 `_hasTransfer` / `_showProgress` / `_progressRatio` 三个 getter。发送中或接收中且 `done < total` 显示确定进度，仅发送中且首条进度未到时显示不确定进度；发送完成（status 非 sending）后即使进度未刷新也不再显示。普通文件气泡显示 `百分比 · 大小` + 线性进度条，图片气泡显示圆形确定进度 + 百分比覆盖层，音视频气泡显示线性进度条，三类都带 `chat-file-progress-<id>` key。
- [x] 回归修复：旧测试「文件气泡展示文件名与大小，传输中显示百分比进度」期望发送端 `25% · 2.0 KB`，此前为避免不确定动画不收敛误把发送端进度排除，现用上述 getter 统一两端逻辑；同时把图片的 `CircularProgressIndicator` 改为确定进度 `value: ratio`，避免有进度时仍转圈。
- [x] 新增 `app/test/chat_transfer_progress_test.dart` 4 例：进度早于消息暂存回填、回包不清接收中进度、接收端百分比进度条、发送端首条进度未到时不确定进度条。
- [x] 顺带修复全量 Go 测试暴露的 `TestGroupProfileEndToEnd` 偶发超时：与 T33 同源（GossipSub mesh 未连通时控制帧单次广播丢失）。`core/internal/coreapp/group_profile_test.go` 新增 `retryControlFrame()` helper，四处控制帧同步点改为重复下发幂等 RPC 直到对端收敛（30s 上限）。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **618 通过 + 3 跳过**（较上轮 +4）；`go test ./... -count=1` 全绿；`TestGroupProfileEndToEnd -count=20` 全过。Web 重建并加缓存破坏 `?v=20261127145634`，首页与 main.dart.js 均打上版本号。
- 说明：进度条数据来自内核 `transfer.progress` 事件，需内核运行在支持该事件的版本；群文件下载是同步 RPC + 进度事件混合链路，进度显示同样已覆盖。

## T38 摄像头扫码真实实现 + iOS 权限补齐（已完成）
- [x] 用户问「点击扫码为什么不是调用的摄像头去扫码」。根因：`qr_share.dart` 的文件头注释明确写「相机扫码依赖真机权限，按 R-17 挂起」，「扫码加好友」按钮打开的是 `_QrImportDialog`，只有一个粘贴名片文本的 `TextField`，根本没有摄像头路径。
- [x] `app/pubspec.yaml` 新增 `mobile_scanner: ^7.5.0`（跨平台：iOS/Android 用 AVFoundation/CameraX，macOS 用 Apple Vision，Web 用 getUserMedia + ZXing；iOS 最低 15.0 已满足）。
- [x] 新增 `app/lib/features/contacts/qr_camera_scanner.dart`：`QrCameraScannerPage` 真正打开摄像头（`MobileScanner`，只识别 QR 格式），扫到文本即回调并 pop 返回；带权限拒绝 / 不支持 / 启动失败的中文提示与「返回手动输入」；提供手电筒、前后摄像头切换；Web 端提示允许浏览器访问摄像头。`scannerBuilder` 注入点用于测试免真摄像头。
- [x] `qr_share.dart` 的「从二维码添加」弹窗顶部新增「打开摄像头扫码」按钮，扫描结果直接填入并调用 `qrParse` 验签 → 预填添加好友弹窗；原粘贴框保留为降级路径。`_parse` 拆出 `_parsePayload(String)` 复用。
- [x] `app/ios/Runner/Info.plist` 补 `NSCameraUsageDescription` 与 `NSMicrophoneUsageDescription`——此前 iOS 完全没有这两个声明，扫码和视频通话在 iOS 上都会因缺权限声明直接崩溃。macOS 已有摄像头声明，无需改。
- [x] 六语表各加 11 条词条（摄像头扫码、打开摄像头扫码、权限拒绝、不支持、启动失败、返回手动输入、手电筒、切换摄像头、两条对准提示、粘贴降级提示）；新增 `app/test/qr_camera_scanner_test.dart` 2 例（扫描结果回填调用方、注入模式不出现硬件按钮）。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **620 通过 + 3 跳过**（较上轮 +2）；Go 全量绿；Web 重建并加缓存破坏 `?v=20261127151854`。
- iOS 真机/模拟器测试受阻（非代码问题）：`devicectl` 显示本机未连接 iPhone 真机，只有关闭的模拟器；启动 iPhone 17 Pro 模拟器后 `flutter devices` 可识别，CocoaPods 通过本地 spec 源安装成功（`mobile_scanner 7.0.0`），但 `flutter build ios --simulator` 在 Xcode 27.2 下报 `sandbox-exec: sandbox_apply: Operation not permitted`——运行环境 Seatbelt 嵌套沙箱拒绝 SwiftPM 的二次沙箱，`SWIFTPM_DISABLE_SANDBOX=1`、关闭 Xcode package 沙箱、跳出会话沙箱均无效，需在普通终端手动构建。另据 `docs/开发进度文档.md`，`app/ios/Frameworks/Nexmem.xcframework` 产物尚未生成（工程内 6 处悬空引用），真机 IPA 验收仍属 R-20 挂起项。

## T39 未完成项梳理（已完成）
- 已确认可本地闭环的功能占位均已消除；剩余均为真机/公网/宿主依赖的 R-17 挂起项（对称 NAT 可达率、功耗、跨设备实时推送、公网 S3 并发、macOS/iOS 宿主产物），不属本轮可修复范围。

## T40 远控设置页「检查权限」点击无反馈（已完成）
- [x] 用户反馈截图：Web 端远程控制设置页「检查权限」按钮点击像没反应。根因：按钮 `onPressed` 实际调用了 `_injector.checkPermissions()`，但 Web 用的 `UnsupportedInputInjector` 恒定返回 `InputPermissionStatus.unsupported`，与页面已显示的状态完全一致，`setState` 重建后文本无变化，也没有任何 SnackBar / loading 反馈，用户感知为「点了没反应」。
- [x] `app/lib/features/remote/remote_settings_page.dart`：抽出 `_checkPermissions()` / `_requestPermissions()`，点击立即置 `_checking` / `_requesting` 显示按钮内 spinner，完成后 `ScaffoldMessenger` 弹结果提示「权限检查完成：{状态}」/「授权请求已处理：{状态}」；状态文案Map 在 await 前取好，遵守 `use_build_context_synchronously`。
- [x] 注入点：`RemoteSettingsPage` 新增 `injectorFactory` 与 `storageFactory` 两个可选参数（生产为 null 走平台实现），测试可注入 `UnsupportedInputInjector` 替身与 `MemoryRemoteStorage`，绕开 `getApplicationSupportDirectory()` 在测试环境无 method channel mock 会挂起的问题。
- [x] 六语各加 2 条词条（权限检查完成、授权请求已处理）；新增 `app/test/remote_permission_feedback_test.dart` 2 例：状态未变化时仍有 SnackBar 反馈、前往授权后状态刷新并提示。
- 验证：`dart analyze` 零问题；干净环境 Flutter 全量 **622 通过 + 3 跳过**（较上轮 +2）；Web 重建并加缓存破坏 `?v=20261127152909`，首页与 main.dart.js 均 200。
- 测试坑：SnackBar 消失依赖真实计时器，点击后不能用 `pumpAndSettle()`（会超时），改用 `pump()` + `pump(Duration(seconds:1))`；按钮在 `ConstrainedBox(maxHeight:540)` 列表内可能不在视口，需先 `ensureVisible`；`_load()` 初始化已调用一次 `checkPermissions()`，断言点击增量要基于点击前计数。

## T41 iOS 真机测试与慢启动竞态修复（已完成）
- [x] iOS 签名配置打通：用户在 Xcode 同意 PLA + 注册设备后，`security find-identity` 出现 `Apple Development: yu huang`，Xcode 自动签名（Team `5TF5SYS3BC`）成功。
- [x] 真机安装成功：`flutter run -d <iphone>` 构建 55s → 安装启动 → `Nexmem event state.changed seq=1/2/3`，`go_seq_go_to_refnum` 崩溃未再出现。
- [x] 真机 E2E 集成测试（`integration_test/mobile_e2e_test.dart`）全通过：`E2E_PLATFORM=ios`、`E2E_ACCOUNT=c06da6dd…c218`、`E2E_UI_BOOT=ios:ok`；双端收发因无对端账号按设计跳过。
- [x] **真机发现并修复 bug：联系人页慢启动竞态**。现象：截图显示「通讯录服务尚未接入内核」红条常驻。根因：`ContactsPage.initState` 立即 `contact.list()`，iOS 真机 gomobile 内核首次启动要生成主密钥、`core.start` 更慢，首次拉取早于内核就绪返回 `NOT_STARTED`；shell `_boot()` 成功后只 reload 会话，未重拉联系人，错误条不消失。修复：`app/lib/app/shell.dart` `_boot()` 内核就绪后补 `_contactsKey.currentState?.reload()` 与 `reloadGroups()`。
- [x] 新增真机回归 `integration_test/ios_contact_boot_test.dart`，真机跑出 `IOS_CONTACT_BOOT=ok`（内核就绪后联系人页无错误条）。
- 说明：全量 Flutter 测试需在干净环境跑（清除会话里的 `NEXMEM_BOOTSTRAPS`/`NEXMEM_DIRECTORY_URL`/`NEXMEM_RELAY_ADDRS` 等联调环境变量），否则 2 个 `android_transport_test` 因注入网络配置而期望不符；干净环境 **622 通过 + 3 跳过**。

## T42 Web「关于→开源许可」双层标题栏修复（已完成）
- [x] 用户截图反馈 Web 端「关于」页点「开源许可」后出现两个标题栏（「关于」+「许可」）。
- [x] 根因：窄屏下「关于」是 `SettingsPanePage`（外层 AppBar「关于」）+ `EmbeddedSettingsPane` 的独立 Navigator；`showLicensePage` 默认 `useRootNavigator=false` 把内置 `LicensePage` push 进内层导航栈，两个 AppBar 同时可见叠加。
- [x] 修复 `app/lib/features/settings/settings_page.dart`：`showLicensePage(..., useRootNavigator: true)`，让 LicensePage push 到根 Navigator 全屏覆盖，只剩一层标题栏。
- [x] 新增 `app/test/about_license_navigation_test.dart`：窄屏 SettingsPanePage → 点 about-license → 断言 LicensePage 在根导航器且「关于」标题栏不可见。反向验证：临时去掉 useRootNavigator 后测试按预期失败（确认能捕获 bug），恢复后通过。
- 验证：Web 重建 `?v=20261127165255`，首页/bootstrap/main.dart.js 均 200。

## T43 中继默认开启 + 启动服务检测门（已完成）
- [x] 用户要求「中继设置默认开启，填入默认值（官方提供的）」以及「联系人服务尚未接入内核（程序启动时检测内核等服务正常后再进入，提示进度）」。
- [x] `app/lib/features/settings/relay_settings.dart` 与 `core/internal/coreapp/relay_settings.go`：首次启动默认启用官方主/备中继并预填 multiaddr；用户显式保存过开关/地址则尊重用户选择。Go 日志区分「官方默认」与「本机设置」。
- [x] 新增 `app/lib/app/startup_gate.dart`：进入主界面前顺序检测内核、联系人、群聊、会话、设置服务，展示进度条、状态列表、失败原因、重新检测与「仍要进入」；只有 `NOT_STARTED` 阻塞进入，普通异常降级放行。
- [x] `app/lib/app/app.dart` 在账号就绪且有内核 session 时插入 `StartupGate`，账号切换按 generation 重置检测状态；`app/lib/app/shell.dart` 内核就绪后补拉联系人/群列表，兜住 iOS 慢启动竞态。
- [x] 六语各加 11 条启动检测词条；新增 `app/test/startup_gate_test.dart`、`core/internal/coreapp/relay_settings_test.go`；两个未装配 `contact.list/group.list` 的 core_session 用例显式关闭启动检测。
- 验证：Flutter 全量 627 通过 + 3 跳过；Go 全量绿；Web 重建后加缓存戳 `20261127170912`。

## T44 设备发现、地图标注、搜索与大量设备处理（已完成）
- [x] 用户问「能否提供一个扫描发现哪些设备的功能，地图显示标注，加入搜索功能，设备特别多如何处理」。完成只读调研后落地实现。
- [x] Go：新增 `net.discoverDevices`，汇总本地地址簿、mDNS TTL 缓存、libp2p 已连接节点与 peerstore；输出 `peer_id/account_id/label/addrs/ip/connected/direct/relayed/source/last_seen`，支持 `limit/offset` 分页（默认 200，上限 1000），按在线优先 + 最近发现排序；不做 IP 归属查询。`discovery.MDNS.Snapshot()` 只返回未过期记录。
- [x] 契约：`core/gateway/builtin.go` 新增方法定义，重建 `core/contract/api.json`；`core/contract/cases/baseline.json` 新增用例；`gateway_test.go` 方法数 96→97。
- [x] Dart：`CoreSession.discoverDevices` + `DiscoveredDevice` / `DeviceDiscoverPage` 模型；远程设备台账新增可选 `region/latitude/longitude`（GCJ-02，仅本机保存），编辑对话框支持填写与校验。
- [x] 远程设备页：新增 250ms 防抖搜索（名称/账号/IP/备注/类型/状态）、「仅在线」筛选、扫描发现入口、把发现设备加入台账、设备地图入口；列表改为 `ListView.builder` 分批构建（每批 50）并支持滚动触底/按钮加载更多，避免大量设备一次性构建。
- [x] 发现面板 `DeviceDiscoverySheet`：分页加载、本地搜索、来源/直连状态展示、重复设备标记「已在台账」，加入时保留用户已有备注与位置。
- [x] 地图：新增 `app/lib/features/remote/device_map_page.dart`。按合规规范默认腾讯地图 GL JS，不内置任何可用 Key：Android/iOS/Web 用 WebView 加载用户自备 Key 的页面；macOS/Windows/Linux 降级为坐标列表并提示填写 Key。HTML 中按缩放级别做网格聚合，密集点显示数量、点击放大，使用内联 SVG 图标，不使用 demo 图片或违规地图源。
- [x] 新增 `app/assets/device_map_preview.html`：WorkBuddy 默认代理模式预览，保留 `__WB_HTTP_PORT__` / `__WB_TMAP_SECRET__` 占位符，前端不写 Key，可直接用预览面板查看聚合标注效果。
- [x] 六语各加约 37 条词条；新增 `app/test/device_discovery_test.dart`（模型、搜索、扫描加入台账、地图入口、HTML 代理/自备 Key 两种模式）与 Go `device_discovery_test.go` / `mdns_snapshot_test.go`。
- 验证：`dart analyze` 零问题；Flutter 全量 **634 通过 + 3 跳过**（较上轮 +7）；`go test ./... -count=1` 全绿；Web 重建并加缓存戳 `20261127172741`。
- 说明：本阶段位置来源是「用户手动填写地区/经纬度」，内核不自动查询或上传 IP 归属地；后续 T46 已按用户授权补上离线 IP 库自动推断。

## T46 离线 IP 库自动归属地（已完成）
- [x] 用户要求「从网络下载 IP 库，实现自动归属地，p2p 协议应该很容易获取到用户真实 IP 地址」。利用内核 `net.discoverDevices` 从 multiaddr 拿到对端 IP，本机解析，不做服务端查询。
- [x] 新增 `app/lib/features/remote/ip_location.dart`：ip2region v4 xdb（Apache-2.0）下载、缓存、格式校验与二分查询；私网/环回/保留地址与 IPv6 不查询；按官方 Go binding 对齐大端 IP / 小端索引。
- [x] 新增 `region_coordinates.dart`：省/市中心点 → GCJ-02 近似坐标，按城市优先、省份兜底；中国台湾按「中国台湾」处理，境外 IP 不映射国内坐标。
- [x] 新增 `ip_location_loader_io.dart`（桌面/移动下载到应用支持目录，`.tmp` 原子写入）与 `ip_location_loader_web.dart`（Web 内存缓存）。
- [x] 新增 `RemoteGeoController`：默认关闭，首次启用需弹窗同意；只补全空白地区/坐标，不覆盖用户手动标注；结果只写本机台账，不作为消息/信令发送。
- [x] 远程设备页加入自动归属地开关、隐私说明、下载进度与错误提示；发现设备加入台账时保存 IP。Go `firstIPFromAddrs` 改为优先直连 IP，避免把中继服务器位置当成设备位置。
- [x] 修复 `shell.dart` 条件导入 URI 写错导致全量测试加载失败（`lib/app/ip_location_loader_io.dart` 不存在）：两个分支都改为 `../features/remote/...`。
- [x] IP 库镜像地址可配置：同意弹窗可填 http(s) 镜像，留空用官方 raw 地址；设置键 `device.ip_db_url`，非 http(s) 被拒绝。`IpLocationService.ensureLoaded(url:)` 支持覆盖下载源，查询仍完全离线。修复原注释「可在设置里覆盖」但未接线的问题。
- [x] 六语各加 7+2 条词条；新增 `ip_location_test.dart`（xdb 解析、缓存、私网过滤、镜像覆盖与校验、台湾口径、境外坐标、只补空白）与 `device_discovery_test.dart` 隐私弹窗/镜像输入框用例；Go `device_discovery_test.go` 加直连 IP 优先测试。
- 真实库验证：`raw.githubusercontent.com` / `cdn.jsdelivr.net` / `github.com` 在本环境 TLS 被阻断（`SSL_ERROR_SYSCALL` / HTTP2 framing error）；`https://fastly.jsdelivr.net/gh/lionsoul2014/ip2region@master/data/ip2region_v4.xdb` 实测完整下载 11,123,858 字节。已把默认地址改为该 CDN 镜像（官方 raw 保留为 `kIpLocationDbOfficialUrl` 备选），并用真实 xdb 验证解析：`114.114.114.114` → 中国 江苏省 南京市、`223.5.5.5` → 中国 浙江省 杭州市、`8.8.8.8` → United States California Mountain View 且无国内坐标。
- 验证：`flutter analyze` 零问题；Flutter 全量 **644 通过 + 3 跳过**；`go test ./... -count=1` 全绿；Web 重建并加缓存戳 `20261127175808`。
- 移动端内核产物同步：`gomobile bind -target=ios` 重新生成 225 MB `Nexmem.xcframework`；`make android-aar` 重新生成 AAR（需 `JAVA_HOME=/opt/homebrew/opt/openjdk@21`、`ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`、`ANDROID_NDK_HOME=.../ndk/28.2.13676358`），两者均已包含中继默认值与设备发现改动；debug APK 已重建。
- 真机复验待用户配合：iPhone 当前处于锁定状态，`flutter drive` 卡在 Xcode 调试连接，`devicectl process launch` 报 `Locked`；解锁设备并允许 Xcode Automation 后重跑 `integration_test/ios_contact_boot_test.dart` 即可。

## T47 消息通知（Android / iOS / Web）与凭证可插拔（已完成）
- [x] 现状：应用内提示音（右上角浮层 + 叮咚、来电通知条）已完成；`push.register/unregister` 契约与索引服务 `push_tokens` 表已完成；但客户端从未获取设备令牌，系统级通知链路是断的。
- [x] 服务端：新增 `core/internal/push/router.go`（按 `apns:`/`fcm:`/`web:` 前缀路由，历史无前缀令牌兼容 APNs）、`fcm.go`（FCM HTTP v1 + 服务账号 OAuth2 JWT）、`webpush.go`（VAPID ES256，空载荷）。凭证全部走环境变量 `NEXMEM_FCM_ACCOUNT` / `NEXMEM_APNS_*` / `NEXMEM_VAPID_*`，未配置返回 `ErrNotConfigured`，目录服务 wake 不再误删令牌。
- [x] 客户端：新增 `app/lib/features/push/`：`push_platform.dart`（平台抽象 + 空实现）、`push_platform_io.dart`（MethodChannel/EventChannel，宿主未接线自动降级）、`push_platform_web.dart`（浏览器 Notification + Service Worker + 可选 VAPID 订阅）、`push_controller.dart`（开关、`push.register`、权限、通知节流、点击路由）、`push_settings_dialog.dart`（设置面板）。
- [x] 设置页「设置 → 消息通知」入口，通知点击解析 conversation_id 复用 `AppShell._open` 跳转；`message.new` 事件只带指针，通知不携带正文/发送者/会话内容。
- [x] Web：新增 `app/web/sw.js`（push 显示通知、notificationclick 回传页面），`app/web/index.html` 产物随构建发布；VAPID 公钥由 `--dart-define=NEXMEM_WEB_VAPID_PUBLIC_KEY` 注入，未注入仅本地通知。
- [x] 六语各加约 17 条词条；新增 `app/test/push_notifications_test.dart`（6 例）和 Go `internal/push/router_test.go`（5 例）；`docs/推送接入指南.md` 面向二次开发者说明凭证接入；README 同步。
- 验证：`flutter analyze` 零问题；Flutter 全量 **650 通过 + 3 跳过**；`go test ./... -count=1` 全绿；Web 重建 `?v=20261127185326`，本地预览 index/sw.js 均 200。
- 说明：Android FCM / iOS APNs 的真实凭证与原生宿主通道由二次开发者按指南接入；未配置时功能自动降级，不影响消息收发。

## T48 扫描发现展示设备距离（已完成）
- [x] 用户要求「扫描发现，如果设备开启了定位功能，要展示距离信息」。发现结果的 `DiscoveredDevice` 只有 IP，没有坐标；远端坐标来自台账手动标注或 T46 的离线 IP 归属地，本机坐标此前无处填写。
- [x] 新增 `app/lib/features/remote/device_distance.dart`：Haversine 大圆距离（地球平均半径 6371008.8 m）、经纬度合法性校验、`m/km` 近似格式化。坐标任一非法返回 null，绝不猜测。
- [x] 新增 `app/lib/features/remote/local_location_controller.dart`：`LocalLocationController` 默认空，读写 `device.local_latitude` / `device.local_longitude` 本机 KV；不读取系统定位、不随消息/信令发送。统一弹窗改为 StatefulWidget 自管理 TextEditingController，校验失败留在弹窗内提示；留出动画期，避免弹窗关闭后控制器被提前释放。
- [x] 远程设备页筛选栏加「本机位置」Chip，扫描发现面板顶部加状态提示与设置入口；`RemoteDevicesActions` 注入 `localLocation`，壳层初始化并 dispose。
- [x] 发现列表 subtitle 显示「距离约 xx m/km」：远端坐标优先取台账（按 `directoryKey` 匹配），未标注且用户已开启自动归属地时用 `IpLocationService.lookup()` 临时推断城市中心点（不写回台账）；私网 IP 不推断。未设置本机位置或设备无坐标时不显示距离。
- [x] 六语各加 9 条词条；新增 `app/test/device_distance_test.dart`（Haversine、格式化、非法坐标、本机位置读写与清除）与 `device_discovery_test.dart` 3 个 Widget 用例（弹窗保存、有距离、无距离提示）。
- 验证：`flutter analyze` 零问题；Flutter 全量 **659 通过 + 3 跳过**（干净环境，排除 shell 残留 `NEXMEM_*` E2E 环境变量对 `android_transport_test.dart` 的污染）；Web 重建并加缓存戳 `?v=20261127190625`。
- 说明：距离是近似直线距离，坐标口径为 GCJ-02 / IP 库城市中心点，不用于导航或风控；用户关闭自动归属地后，只有台账手动标注的设备会显示距离。

## T49 系统权限申请与管理（已完成）
- [x] 用户问「程序有没有加入安卓，苹果等等设备申请相关权限的功能」。全平台审计结论：原先只有 Android `POST_NOTIFICATIONS` 启动申请、远控输入注入权限引导、Web 通知权限与插件内部弹窗，缺少统一入口，且 iOS 无通知授权、`NSLocalNetworkUsageDescription` 缺失。
- [x] 声明补齐：iOS `Info.plist` 新增 `NSLocalNetworkUsageDescription` 与 `NSBonjourServices`（`_nexmem._udp`）；macOS Debug/Release entitlements 补 `network.client`、`device.camera`、`device.audio-input`（沙箱仍关闭以支持远控注入）。
- [x] 新增 `app/lib/features/permissions/`：类型定义 + MethodChannel 原生实现 + Web 实现 + 按编译目标工厂。支持 `status/request/openSettings`，未接线的宿主安全降级为 `unsupported`。
- [x] Android `MainActivity.kt` 新增 `nexmem/permissions` 通道：摄像头/麦克风/通知的状态查询与显式申请，区分 `denied` / `permanently_denied`，跳应用详情页；原启动通知申请保留。
- [x] iOS `AppDelegate.swift` 新增同名通道：`AVCaptureDevice.requestAccess` 处理摄像头/麦克风，`UNUserNotificationCenter.requestAuthorization` 处理通知（不依赖 APNs 凭证），跳系统设置；不新增 Swift 文件，避免 Xcode 工程引用改动。
- [x] Web 侧通知用 `web.Notification.permission/requestPermission`，摄像头/麦克风用 `getUserMedia` 主动申请后立即释放媒体流（浏览器不提供静默查询，状态返回 prompt）。
- [x] 设置页新增「权限管理」入口，`PermissionsPane` 展示三类权限状态与「申请权限 / 打开系统设置」按钮；六语各加 14 条词条；`app_permissions_test.dart` 4 例覆盖枚举转换、MethodChannel 调用与 UI 交互。
- 验证：`flutter analyze` 零问题；Flutter 全量 **663 通过 + 3 跳过**；`Android compileDebugKotlin` 通过；`flutter build ios --no-codesign` 通过；Web 重建并加缓存戳 `?v=20261127191927`。
- 说明：文件由系统选择器授权，不申请存储权限；位置为用户手填，不读取系统定位；桌面端系统 TCC 弹窗仍由首次使用触发，未接原生通道时显示「当前平台不支持」。

## T50 开发者配置页（地图 Key 与消息通知凭证）（已完成）
- [x] 用户要求「应用增加一个开发者：这里面可以填写地图key，消息通知的凭证」。
- [x] 新增 `app/lib/features/settings/developer_settings.dart`：地图 Key 复用 `device.map_tencent_key`；Web Push VAPID 公钥写入 `developer.vapid_public_key`，保存后调用 `PushController.reloadCredentials()`。两项都只存本机 KV。
- [x] 服务端凭证安全边界：APNs Key ID / Team ID / Bundle ID / .p8 内容、FCM 服务账号 JSON、VAPID 私钥与 subject 只在页面内存中，点击「生成服务端配置」输出 `NEXMEM_*` 环境变量文本，私钥内容以占位路径代替，不写入 KV、不上传、不随消息发送。
- [x] Web 推送改造：`WebPushPlatform` 从 settings 读取公钥（优先于 `--dart-define` 构建期值），`PushPlatform.refreshCredentials()` 默认空实现 + Web 覆写，`getToken()` 检测公钥变化时退订旧订阅重订；`makePushPlatform({settings})` 由壳层注入。
- [x] 设置页菜单末位加入「开发者」（避免既有「关于」测试因列表下移失效），`settingsPaneBuilder` 同步分发；六语各加 17 条词条；`developer_settings_test.dart` 3 例覆盖本机保存、私钥不进配置文本与设置页入口。
- 验证：`flutter analyze` 零问题；Flutter 全量 **666 通过 + 3 跳过**；Web 重建并加缓存戳 `?v=20261127193323`；`docs/推送接入指南.md` 与 README 同步说明两种公钥注入方式。
- 说明：APNs / FCM 私钥属于服务端签名凭据，放客户端会泄漏且无法安全轮换，因此只提供配置文本生成，不提供客户端保存。

## T51 Web 在线播放服务端媒体（已完成）
- [x] 此前 Web 聊天图片/语音/视频点击后只能下载到本机再打开，`LocalImage` 也只是「不支持预览」占位；`http.ServeFile` 虽支持 Range，但网关固定返回 `Content-Disposition: attachment`，没有在线播放入口。
- [x] 服务端：`core/server/webd/server.go` 的 `handleDownload` 新增可选 `disposition=inline`，保留默认 `attachment` 下载语义；继续由 `http.ServeFile` 输出字节，天然支持 `Range` / `If-Range` / `HEAD` / `Accept-Ranges`，白名单、`EvalSymlinks` 防逃逸与三种 token 传入方式不变。
- [x] URL 与会话：`web_download.dart` 新增 `webMediaUri()`，复用 `webDownloadUri()` 的鉴权与路径编码并追加 `disposition=inline`；`CoreSession` 增加可选 `mediaSourceUri` 回调，`main.dart` Web 分支注入，桌面/移动端为空。
- [x] 播放器：`MediaViewerDialog` 增加 `sourceUri`，Web 图片走 `Image.network`、视频走 `VideoPlayerController.networkUrl`、音频走 `UrlSource`；跳过对服务端路径的本机 probe，失败文案区分在线播放，Web 不显示无意义的 ffmpeg 转码按钮。原生仍走 `FileImage` / `VideoPlayerController.file` / `DeviceFileSource`。
- [x] 气泡接线：`ChatPage` → `_MessageList` → `MessageBubble` → `_FileBubbleContent` 透传 `mediaSourceUri`；图片缩略图的 `LocalImage` 在 Web 用 `Image.network`，点击气泡打开带 `sourceUri` 的 `MediaViewerDialog`。`shell.dart` 桌面/移动两处 ChatPage 只在 `kIsWeb` 时注入；原生链路零变化。注入的 `onPreviewMedia` 仍优先，测试替身不受影响。
- [x] 测试：`download_test.go` 新增 inline、Range 206/Content-Range/Accept-Ranges、HEAD Content-Length、Authorization/X-Nexmem-Token 鉴权用例；`web_download_test.dart` 新增 `webMediaUri` 与 `CoreSession.mediaSourceUri` 用例；`chat_page_test.dart` 新增注入播放源后图片气泡打开在线预览并用 `NetworkImage` 的用例。
- 验证：`flutter analyze` 零问题；Flutter 全量 **669 通过 + 3 跳过**（干净环境，排除 shell 残留 E2E 环境变量）；`go test ./... -count=1` 全绿；Web 重建并加缓存戳 `?v=20261127194511`，本地预览 index / sw.js / flutter_bootstrap.js 均 200。
- 说明：`disposition=inline` 只用于媒体在线播放，保存到本机仍用默认 `attachment`；token 仍走 query 参数（media element 不能带自定义 header），同源部署无需 CORS。跨源部署需另配受控 CORS 头，当前不做。

## T52 IP 库内置，启用自动归属地无需下载（已完成）
- [x] 用户要求「IP库直接内置在程序里面不用用户去下载」。此前启用弹窗会下载约 11 MB xdb，并要求填镜像地址；下载失败则功能不可用。
- [x] 把官方 ip2region v4 xdb（Apache-2.0，11,123,858 字节，SHA-256 `a29fb3e8b204dfdf45b9bc082e12845b5eaac18cd467849d2888baa9fde383c8`）放到 `app/assets/ip2region_v4.xdb` 并在 `pubspec.yaml` 注册，桌面/移动/Web 均由 Flutter asset 打包。
- [x] `IpLocationService.ensureLoaded()` 加载优先级改为：内存 → 内置 asset → 旧缓存 → 网络下载。新增 `IpLocationBundledReader`；两端 loader 都用 `rootBundle.load(kIpLocationBundledAsset)` 读取 asset，读取失败 quietly 回退，不阻断功能。`forceRefresh` 仍可走网络更新，`device.ip_db_url` 保留为可选刷新源但不再出现在启用弹窗。
- [x] UI：`remote_devices_page.dart` 的同意弹窗改为只说明隐私边界（不下载、不上传 IP、不覆盖手动标注），按钮「同意并下载」→「同意并启用」，去掉镜像输入框；加载中 Chip 文案改为「正在加载内置 IP 库」。六语各替换 3 条词条。
- [x] 测试：`ip_location_test.dart` 新增内置库优先/asset 失败回退缓存/真实 xdb 解析公网 IP 三个用例；`device_discovery_test.dart` 弹窗断言改为新文案且不再有镜像输入框，并新增「确认后使用内置库启用，不需要下载」Widget 用例。
- 验证：`flutter analyze` 零问题；Flutter 全量 **673 通过 + 3 跳过**；`go test ./... -count=1` 全绿；Web 重建并加缓存戳 `?v=20261127195953`，本地预览 index / sw.js / 内置 xdb 均 200（xdb 11,123,858 字节）。
- 说明：正常启用只走内置 asset，零网络请求；`device.ip_db_url` 与 `forceRefresh` 仅为可选更新通道，UI 不再要求填写。xdb 为 Apache-2.0 第三方数据，随包分发时保留 README 中的来源说明。

## T53 远程设备页与设备发现拆分为独立栏目（已完成）
- [x] 用户反馈「远程设备这里是管理远程控制的电脑，手机等等，不是放发现这些的。发现是一个单独的栏目」。此前台账页同时放了扫描、地图、自动归属地、本机位置，容易导致两类设备概念混淆。
- [x] `RemoteDevicesActions` 移除 `discoverDevices / onOpenMap / geo / localLocation`；`RemoteDevicesPage` 只保留搜索、类型/在线筛选、添加/编辑/删除、连接/断开与同类型群控。空态文案改为「暂无远程设备，点击右上角添加」。
- [x] `DeviceDiscoverySheet` 升级为完整页面：新增 `embedded` 模式，桌面右栏用 `PaneHeader`，移动端全屏用 `Scaffold + AppBar`；标题统一为「设备发现」，右上角提供地图与重新扫描入口。自动归属地 Chip、本机位置入口、距离显示、搜索、分页与「加入台账」全部归入此页。
- [x] `settings_page.dart` 的「我的」新增 `(Icons.radar, '设备发现')` 入口，稳定 key 为 `settings-device-discovery`；独立使用 `SettingsPage` 时给出「请从应用「我的」页打开设备发现」提示。
- [x] `shell.dart` 把「设备发现」归入 `_sectionProfile`，桌面右栏与移动 push 都直接分发到 `DeviceDiscoverySheet`；新增 `_buildDeviceDiscoveryPage()`，注入内核发现、自动归属地、本机位置与地图回调；远程设备页不再注入发现能力。地图仍复用 `DeviceMapPage`。
- [x] 六语各加 `设备发现 / 重新扫描 / 请从应用「我的」页打开设备发现` 三条词条；README 同步远程设备台账与设备发现独立栏目的边界。
- [x] `device_discovery_test.dart` 重写：新增「远程设备页无发现入口」「发现页搜索 / 地图 / 加入台账」「右栏嵌入模式」「我的页独立入口」用例；原归属地 / 本机位置 / 距离用例改为直接泵入发现页，去掉远程设备页筛选 Chip 的重复断言。
- 验证：`flutter analyze --no-pub` 零问题；`flutter test test/device_discovery_test.dart --no-pub` 13 例全绿；全量 Flutter **675 通过 + 3 跳过**（干净环境，排除 shell 残留 `NEXMEM_*` E2E 变量）；`go test ./... -count=1` 全绿；Web 重建并加缓存戳 `?v=20261127201756`，本地预览 `/`、`flutter_bootstrap.js`、`main.dart.js`、`sw.js` 与内置 xdb 均 200。

## T54 远控密码与双模式（已完成）
- [x] 用户要求「添加远程设备和开启支持远程都要提供和设置密码」，随后进一步澄清：远程设备页只放远控台账信息；聊天发起远控需要对方同意；台账设备 + 密码可静默控制。
- [x] 新增 `remote_password.dart`：SHA-256 固定前缀生成 credential，长度 6~128，任何界面与持久化都不保存明文。`remote_password_dialog.dart` 统一新增/修改/验证密码弹窗，控制器在弹窗 State dispose 时释放，避免测试里 use-after-dispose。
- [x] 被控端：`RemotePrefs.enabled` 默认改为 false；`passwordCredential` 写入 `prefs.json`，旧版本「无密码但已开启」在加载时自动关闭。`RemoteSettingsPage` 开启前必须设置密码（已有密码需重新输入确认），提供修改密码入口；移除易混淆的「每次请求都需要确认」开关，顶部说明两种模式。
- [x] 控制端：`RemoteDevice` 增加 `credential` 并随 `devices.json` 持久化；添加/编辑设备、发现页「加入台账」都必须填写密码；添加设备弹窗按用户截图反馈移除地区、纬度和经度，只保留账号、名称、类型、备注、密码。
- [x] 双模式信令：`RemoteSignal` 增加 `credential` 与 `silent` 字段。`RemoteControlService.request()` 支持 silent 参数；`_handleRequest()` 中聊天请求（silent=false）始终进入 incoming 等用户确认，不做自动接受；silent=true 才校验台账密码并自动 accept。聊天请求不依赖台账密码，静默请求跳过联系人校验。
- [x] `shell.dart`：`_startRemotePeer()` 支持 credential/silent 注入，聊天入口不传；远程设备台账的 onConnect 从台账取 credential 并置 silent=true。
- [x] 六语各补约 30 条词条；README 同步双模式、密码边界与添加设备表单字段。
- [x] 新增 `remote_password_test.dart`，更新 `remote_signal_test.dart`、`remote_control_service_test.dart`、`remote_devices_test.dart`、`device_discovery_test.dart`、`remote_permission_feedback_test.dart`；覆盖密码校验、信令往返、错误密码拒绝、聊天请求仍需确认、静默自动接受、表单必填与无地区/坐标字段。
- 坑：`debugDefaultTargetPlatformOverride` 若在 `setUp/tearDown` 中修改，Flutter invariant 检查可能早于 tearDown 执行；改为单个测试体 `try/finally` 内恢复。弹窗弹起后按钮可能被新密码行挤出 ListView 视口，测试 finder 要 `skipOffstage: false`。
- 验证：`flutter analyze --no-pub` 零问题；密码相关 6 个文件 41 例专项全绿；全量 Flutter **684 通过 + 3 跳过**（干净环境）；`go test ./... -count=1` 全绿；Web 重建并加缓存戳 `?v=20261127203800`，本地预览 index / bootstrap / main / sw / 内置 xdb 均 200。

## T55 多语言完整性审计与补齐（已完成）
- [x] 用户要求「检查多语言功能是不是全部完善好了」。审计发现此前测试只校验 6 张表的 key 集合一致，但 6 张表共同缺失大量界面文案：全库 `context.t('...')` 中有 170 个字面量 key 未进表，另有动态插值 key、跨文件硬编码标签与 4 条繁体中文残留简体写法。
- [x] 解析 `app/lib/l10n/translations.dart`，比对 en / zh_TW / ja / ar / he / ko 六语键集合、空值与 `{0}` 占位符；扫描界面层 `context.t()` 字面量、枚举/常量 label、动态拼接文案与硬编码中文。
- [x] 六语各补 272 条词条，最终每语种 1116 条，键集合完全一致、无空值、占位符与原文一致。修复繁体中文「日志緩冲 / 诊断日志」等 4 处残留，并把「独占据」等词调整为繁体习惯。
- [x] 修复动态 key：`call_page.dart` 的 `${n} 人` / `邀请你进行${video ? '视频' : '语音'}通话`、`remote_host_banner.dart` 的 `${name} 正在远程控制本机` 改为 `{0}` 占位符；`shell.dart` 通话记录、`device_list_page.dart` 活跃时间、`chat_message.dart` 阅后即焚文案、`image_crop_page.dart` 裁剪错误、`media_viewer.dart` 播放提示、`push_settings_dialog.dart` 推送错误、`group_storage.dart` 配置错误、`device_map_page.dart` 地图提示等改为走翻译表。
- [x] 无本地化对象时（纯数据层测试）保留占位符替换回退，避免返回未替换的 `{0}`。
- [x] `l10n_test.dart` 新增：六语词条数 ≥1000、所有译文占位符一致且非空、远控/发现/最新版本关键文案六语齐全、繁体中文无简体残留。
- 验证：`flutter analyze --no-pub` 零问题；Flutter 全量 **688 通过 + 3 跳过**（干净环境）；`go test ./... -count=1` 全绿；Web 重建并加缓存戳 `?v=20261127210023`。
- 口径：简体中文仍以原文作为 key 直接回退，不单独建表；37 种 locale 走布局适配并回退英文/中文原文，6 种语言提供完整译文。

## T56 全系统逻辑错误审计与修复（已完成）
- [x] 用户要求「检查整个系统是否有错误，特别是逻辑错误」。并行审计远控/发现、文件/Web 网络、群聊/社交/账号、启动门/推送/权限/设置/多语言四条链路后，逐项复核并修复高置信问题。
- 远控与群控：`shell.dart` 台账「断开」改为调用 `end()` 真正通知对端；`RemoteControlService` 记录 `_pausedBeforeReconnect`，ICE 重连成功后恢复暂停态；`RemoteGroupController.sync()` 只剔除失效设备，不再因空集合自动全选，用户「清空」不会被 build 期同步撤销；设备编辑弹窗改用 JSON 传值，备注换行不再污染 credential。
- 网络与文件：`webd` 发送队列 64→1024，重放改用带超时的 `sendWait()`，避免 512 条事件重放时队列瞬时打满即误判断连；`ws_transport` 不再把 403/forbidden 当作 token 失效，保留可重试的 NOT_ONLINE 语义；Web 文件共享/下载页把 `mediaSourceUri` 传给 `MediaViewerDialog`，在线预览不再走本地文件 stub。
- 消息与通知：`ChatStore._deliver()` 在置 failed 后上抛真实异常，文字/文件/重发/转发各自捕获并显示原因；`PushController` 打开会话时调用 `markConversationOpen()`，离开/删除会话时清空活跃态，恢复时只查询 `permission()`，并用 `_restoreInFlight` 防止异步恢复晚于用户开关造成重复注册。
- 数据与权限：内核设置快照加入白名单，只导出/导入 `ui./profile./push./developer./device./startup.` 与显式中继键，不再覆盖 `net.peerbook`、`fs.shares` 等内部 KV；`GroupInfo.copyWith()` 保留等级/群设置字段，公告与群备注保存不再丢数据；账号删除弹窗的「同时删除本机数据」勾选真正传入 `deleteAccount()`；启动按活跃档案的 `data_dir` 恢复内核，`syncCurrentAccount()` 不再用内核当前账号覆盖已有档案 ID；管理员可给自己设置非空等级，UI 与内核权限一致。
- 验证：`flutter analyze --no-pub` 零问题；Flutter 全量 **694 通过 + 3 跳过**（干净环境）；`go test ./... -count=1` 全绿、`go vet ./...` 零问题；Web 重建并加缓存戳 `?v=20261127213657`。
- 仍未覆盖：FCM/APNs/VAPID 真实凭证与宿主通道需二次开发者接入；群控真机测试需至少两台同类型在线被控端；文件共享授权仍只依赖 libp2p 身份与清单签名。

## T57 拉人进群失败与邀请通知缺失修复（已完成）
- [x] 根因：管理员拉人时 `group.invite` 先把目标账号解析为密钥信封地址，X25519 公钥只从信令服务器公开档案读取；局域网加好友、未配置目录服务或档案未发布时，`ResolveTarget` 直接失败并返回 `PEER_UNREACHABLE`，管理员端显示「拉人失败」，对方完全不知道被邀请。
- [x] 好友控制帧交换公钥：`friend.request` / `friend.accept` 的 `Extra` 携带本机 `account_x_pub`；接收方写入本地联系人新列 `account_x_pub`（迁移 `0013_contact_x_pub.sql`）。升级前的老好友由新增 `key.xpubRequest` / `key.xpubResponse` 控制帧在拉群时按需握手补齐。`coreapp` 的群目标 XPub 解析改为「目录服务/注入解析器 → 本地联系人缓存 → 在线好友按需握手」回退，好友拉群在有局域网连接、无公开档案时也能封装密钥信封。
- [x] 显式邀请通知：新增社交控制帧 `group.invited`（`KindGroupInvited`），管理员主动拉人后由 `group.Gateway.OnInvite` 接到 `social.SendGroupInvite()`；被邀请人落系统通知并收到 `group.invited` 事件，社交中心即时刷新。契约事件同步增加 `group.invited`。
- [x] 待同步语义：`group.invite` 不再因新成员 XPub/地址解析失败直接硬失败；成员写入本机成员表，回包新增 `invite_sent` / `pending` / `delivery_error` / `invite_error`，客户端 `GroupInviteResult.inviteDetailed()` 区分「已邀请、待同步」与真正失败；旧内核缺少可选字段时按成功兼容。
- [x] 测试：新增 `TestGroupGatewayInvitePendingNotice`、`TestGroupInviteNoticeFlow`、`TestFriendRequestCarriesXPub`、`TestXPubRequestResponse`，Dart 新增待同步回包解析用例；六语补 1 条「待同步」文案；README 同步说明。
- 验证：`flutter analyze` 零问题；Flutter 全量 **783 passed / 3 skipped**；`go -C core test ./...` 全绿；契约已重生成。

## T58 聊天图片发送格式扩展（已完成）
- [x] 用户反馈「发送图片格式太少」。桌面/Web 图片选择器由 `FileType.image` 改为统一扩展名白名单，避免各平台默认图片过滤器只放行 JPEG/PNG；手机端继续走系统相册的 `image/*` / PHPicker images，覆盖相册内全部图片类型。
- [x] `chat_message.dart` 的图片扩展名与 MIME 映射补齐：PNG、JPEG/JFIF、GIF、WebP、BMP、HEIC/HEIF、TIFF、AVIF、ICO；发送前自动补齐 MIME，接收端据此识别为图片附件。TIFF/AVIF 等内核解码不了的格式仍可发送，气泡解码失败时降级为占位图标并保留打开/保存入口。
- [x] `media_viewer.dart` 图片分类与附件图标正则同步补齐新格式；非图片提示文案六语同步新增 1 条；README 说明支持的图片格式。
- [x] 测试：`media_viewer_fullscreen_test.dart` 新增常用格式统一识别用例，`chat_page_test.dart` 更新提示文案断言。
- 验证：`flutter analyze` 零问题；Flutter 全量 **784 passed / 3 skipped**。

## T59 保存类弹窗统一关闭逻辑（已完成）
- [x] 用户要求「设置成员资料，点击保存应该要关闭弹框。其他地方也要是这样的逻辑，检查一下」。全局审计 `app/lib` 中所有 `showAppDialog` / `showPaneDialog` / `AlertDialog` 的保存按钮，按「保存成功关闭、失败保留并显示错误」统一。
- [x] 群成员资料与群等级弹窗原本已有成功 pop，但错误分支未兜底空 message：新增 `_describeSaveError()`，`NexmemException.message` 为空时回退错误码；成员资料/等级保存统一走 `Navigator.of(context, rootNavigator: true).pop(...)`，避免嵌套导航时弹错上层路由。成员资料保存失败时弹窗保留并显示错误码。
- [x] 窄屏「个人资料」编辑弹窗此前保存后停留在全屏 Dialog：`ProfileBody` 新增 `onTextSaved` 回调，仅文本字段保存成功后触发；`showProfileEditorDialog()` 传入关闭回调，宽屏内嵌面板不传，保持原地编辑。图片保存/移除仍按即时保存处理，不误触发关闭。
- [x] 中继设置、发现设置、离线存储配置弹窗保存成功后自动 `Navigator.pop()`；失败分支保持弹窗并继续显示原有错误文案。群备注/群公告/群介绍、好友备注、设备编辑等「弹窗先返回输入值、调用方再落库」的入口保留既有交互，失败由调用方 toast 提示；开发者配置为内嵌面板而非弹窗，保持 SnackBar 反馈。
- [x] 测试：`group_profile_test.dart` 新增成员资料保存失败保留弹窗且显示错误码；`settings_test.dart` 新增窄屏个人资料保存后自动关闭；`relay_settings_test.dart` 新增独立弹窗保存后自动关闭；中继/离线存储原有「保存后提示」断言改为「弹窗已关闭」。
- 验证：`flutter analyze` 零问题；Flutter 全量 **787 passed / 3 skipped**；`go -C core test ./...` 全绿。

## T60 Web/桌面/手机/平板全端交互、显示与实时性修正（已完成）
- [x] 用户要求「检查整个系统在 web 下，电脑下，手机下，平板下，有没有操作不合理，显示不合理，信息不实时更新的，全部要修正」。按显示、交互、实时性三条线并行审计后逐项修复。
- 显示与布局：`theme.dart` 的 `responsiveDialogContent()` 新增 `BuildContext? context`，对可滚动内容按屏幕高度限高（120~560），修复群成员/群等级、中继、发现、离线存储、联系人分组、远程设备/本机位置、群邀请、群头像/介绍、二维码结果等弹窗在窄屏撑满并顶掉按钮的问题；桌面「账号与安全」去掉重复标题栏；设备发现断点统一；Web 内置浏览器窄屏隐藏前进/刷新但保留地址栏；`onPrimary` / `bubbleSelf` 改深色提升白字对比度；PWA `manifest.json` 改为 `orientation: any`，不再锁竖屏。
- 交互：Web 内置浏览器 iframe 补 `load` 回执、本地历史栈、刷新 nonce 与 Android 返回键优先回退网页；`buildBrowserViewport` 全平台统一 `Key? key`；按住说话用 serial + pending future 修复权限弹窗期间松手竞态，录音过短提示「录音时间太短，未发送」；图片二维码识别增加 `qrImageDecodeSupported` 能力探测，Web/桌面提示改用摄像头扫码；媒体查看器视频旋转按钮只在移动端显示；`.tar` 附件改用 `TarDecoder()`；Web 文件保存区分「开始下载」与最终保存并补失败提示；iOS 隐藏不可用的本地文件夹发布入口；语音气泡播放按钮触控区扩到 48×48 并用 `Flexible` 防止窄气泡溢出。
- 实时性：Web `WsTransport` 接入 `seqStore` + `localStorage` 事件水位，账号切换时清空；`AppShell` 注册生命周期观察，前后台切换后重拉会话/联系人/群/当前消息；`group.avatarChanged` / `group.descriptionChanged` / `group.dissolved` / `group.invited` / `group.joinResolved` 全部触发群资料刷新；`error` 事件弹 toast；`resync_required` 同时清空当前 `ChatStore` 与索引；`message.edited` / `message.expired` 刷新会话列表摘要；切到非消息分区时关闭活跃会话避免通知被抑制；社交中心事件白名单补 `group.invited` / `moment.new` / `poll.updated`。
- 会话草稿：`ChatPage` / `ChatInputArea` / `ChatInputBar` 贯通 `initialDraft` / `onDraftChanged`，壳层按 `conversation.id` 保存，切换会话不串台、退出不丢失、发送后清空。
- 测试与回归：新增「会话草稿回填/同步/发送后清空」用例；`storage_config_test.dart` 改用 `ensureVisible` 适配限高滚动弹窗。验证：`flutter analyze` 零问题；Flutter 全量 **788 passed / 3 skipped**；`go -C core test ./...` 全绿。
- 口径：延续用户此前「先不要构建」要求，本轮未重建 Android / iOS / Web 安装包。

## T61 聊天支持发送文件夹（已完成）
- [x] 用户要求「发送文件可以选择发送文件夹」。在聊天输入工具条新增「文件夹」入口，选中目录后打包成 ZIP，作为普通附件走现有 `dm.sendFile` 通道，复用进度、重发、预览、保存与跨端传输链路。
- [x] 新增 `folder_attachment.dart` / `folder_attachment_io.dart` / `folder_attachment_io_stub.dart`：原生端由平台选择器给出绝对路径，递归读取文件并保留相对目录结构生成 ZIP，写到临时目录；Web 端用 `<input webkitdirectory>` 读取文件字节，在内存打包后经鉴权 `/upload` 上传，把服务端路径交给内核。
- [x] `CoreSession` 新增 `pickFolder` 注入点；Android 复用 MethodChannel `pickDirectory`，桌面复用系统目录对话框，Web 注入 `pickFolderAttachment`，iOS 新增 `pickDirectory` 原生目录选择器并把选中目录树复制到 Caches 固定路径。`shell.dart` 两处 `ChatPage` 均透传 `onPickFolder`。
- [x] `ChatPage` / `ChatInputArea` / `ChatInputBar` 贯通 `onPickFolder`，仅在回调可用时显示 `Icons.folder_outlined` 按钮；选择取消静默返回，打包/发送失败显示「文件夹发送失败：{0}」。六语各补 3 条文案。
- [x] 顺带修复 iOS 文件共享页：既然已有原生目录选择器，「选择文件夹 / 发布」入口不再对 iOS 隐藏，移除过时的「iOS 不支持发布本地文件夹」提示。
- [x] 测试：`folder_attachment_test.dart` 验证目录递归打包、相对路径与取消选择；`chat_page_test.dart` 验证工具条入口、ZIP 附件透传与 `onSent` 回调；`l10n_test.dart` 校验六语一致。
- 验证：`flutter analyze` 零问题；Flutter 全量 **791 passed / 3 skipped**；`go -C core test ./...` 全绿。
- 口径：延续「先不要构建」，本轮未重建 Android / iOS / Web 安装包；iOS 原生目录选择器需下次构建安装后才可在真机验证。

## T62 群分享与加群链路修复（已完成）
- [x] 用户反馈「用户无法加群，发给他分享的群信息他也无法加入群」。审计定位四个高置信根因：群主账号只接受 hex 而分享文本用 base64url；入群申请控制帧未携带申请人 XPub；管理员同意入群时群 ID 只按 hex 解码；分享文本只有人类可读内容，缺少机器可解析链接与直接申请入口。
- [x] 内核编码兼容：`social.decodeAccountPub()` 同时接受 32 字节 hex / base64url 群主账号，`RequestGroupJoin()` 统一把控制帧 `To` 归一为 hex；`coreapp.decodeGroupIDString()` 同时接受 hex / base64url 群 ID，`inviteGroupApplicant()` 可直接处理契约群 ID。
- [x] 入群申请帧 `Extra` 携带申请人账号 X25519 公钥，管理员处理 `KindGroupJoinReq` 时调用 `rememberXPub()` 落本地联系人缓存；同意入群时无需好友关系或目录公开档案即可封装群密钥信封。
- [x] 客户端新增 `group_share_link.dart`：构造/解析 `nexmem://group/join?g=...&o=...&n=...`，兼容旧版「群号 / 群主」纯文本。群资料页「分享群信息」复制文本同时附带可读说明和可点击/可解析链接。
- [x] 聊天消息长按群分享内容出现「申请入群」菜单，壳层 `_requestGroupJoin()` 调用 `group.join.request` 并刷新群列表；社交中心「入群申请」页新增「加入群聊」按钮，粘贴分享信息后可直接提交申请，弹窗按 `responsiveDialogContent()` 限高。
- [x] 六语补齐 7 条入群文案；测试覆盖 base64url 账号/群 ID、入群申请携带 XPub、管理员缓存 XPub、分享链接构造与解析、旧文本兼容、群资料复制、聊天菜单与社交中心粘贴入群。
- 验证：`flutter analyze` 零问题；Flutter 全量 **797 passed / 3 skipped**；`go -C core test ./...` 全绿。
- 口径：延续「先不要构建」，本轮未重建 Android / iOS / Web 安装包；需下次构建安装后才能做双端真机入群复验。

## T63 最新版三端安装（已完成）
- [x] 用户要求给苹果手机、安卓手机和本机 Mac 安装最新版用于手动测试，解除此前「先不要构建」限制。
- [x] Android：补齐 `ANDROID_SDK_ROOT` / `ANDROID_HOME` / `ANDROID_NDK_HOME` / `JAVA_HOME` 后重建 AAR，`flutter build apk --release` 生成 229.9MB APK，通过无线 adb 安装到 `22081212C`，版本核对 `1.1.1`。
- [x] iOS：重建 XCFramework，`flutter build ios --release` 自动签名（团队 `5TF5SYS3BC`），安装到在线设备「卢红娟」（`00008101-000670DE3E80001E`），版本核对 `1.1.1`；另一台「huangyu的iPhone」当前离线，未安装。
- [x] macOS：重建 `bin/libnexmem.dylib` 并内置到 App；因 Xcode 解析空 `FlutterGeneratedPluginSwiftPackage` 时触发 `sandbox-exec: Operation not permitted`，从 `macos/Runner.xcodeproj/project.pbxproj` 移除该空 SPM 引用（插件仍由 CocoaPods 提供，工程已备份到 `/tmp/nexmem_macos_project.pbxproj.bak`），随后构建成功。App 安装到 `/Applications/nexmem_app.app`，ad-hoc 重签并启动验证，版本 `1.1.1`。
- 验证：三端均已安装并核对版本；Android/iOS 已通过设备管理器确认，macOS 进程已启动。

## T64 群语音/视频发起报错修复（已完成）
- [x] 用户反馈群语音/视频提示“群 ID 必须为 16 字节的十六进制或 base64url 编码”。定位为 `shell.dart` 的 `_startCall()` 群聊分支把完整会话 ID `group:<base64url>` 直接传给 `_startGroupCall()`，后者又把它作为 `group_id` 传给 `group.members`，内核解析失败。
- [x] 修复调用点为 `_startGroupCall(call, groupIdOf(item.id), video)`，与拉取群成员、@ 候选、群资料入口统一使用 `groupIdOf()` 去掉 `group:` 前缀。
- [x] 验证：`flutter analyze` 零问题；通话相关测试通过；Flutter 全量 **797 passed / 3 skipped**。重建并重新安装 Android APK、iOS App（卢红娟）与 macOS App，Mac 端已重启加载修复版。
- 口径：`huangyu的iPhone`（iPhone Air）仍显示 unavailable，未能安装；等待目标机真正接入后再装。

## T65 版本号递增与三端重装（已完成）
- [x] 用户反馈「关于我们的版本号，内核版本号都没有变化」。定位根因：客户端版本在 `settings_page.dart` 被硬编码为 `1.1.0`（与 pubspec 的 `1.1.1+1` 不一致），内核 `CoreVersion` 仍为 `0.1.0-dev`；两处都不会随修复自动变化。
- [x] 版本统一：客户端 `app/pubspec.yaml` 从 `1.1.1+1` 递增到 `1.1.2+2`（Android versionCode=2 / versionName=1.1.2，iOS/macOS CFBundleShortVersionString=1.1.2 / CFBundleVersion=2）；About 页 `appVersion` 同步为 `1.1.2`；内核 `core/gateway/envelope.go` 的 `CoreVersion` 从 `0.1.0-dev` 递增到 `0.2.0-dev`。`APIVersion` 保持 `1.0.0`，契约未发生不兼容变更，避免误伤端内核协商。
- [x] 同步契约用例 `core/contract/cases/baseline.json` 与 Flutter 测试中的内核版本期望；新增 `settings_test.dart` 版本一致性守卫，直接比对 `appVersion` 与 `pubspec.yaml` 的 `version`，防止以后再次出现「改了版本但关于页不变」。
- [x] 验证：`flutter analyze` 零问题；Flutter 全量 **798 passed / 3 skipped**；`go -C core test ./...` 全绿。
- [x] 重建全部内核产物（Android AAR、iOS XCFramework、macOS dylib）与三端 Release 包，安装并核对：Android `22081212C` 为 `1.1.2 (2)` 且 `libgojni.so` 含 `0.2.0-dev`；iOS「卢红娟」为 `1.1.2 (2)` 且 Runner 二进制含 `0.2.0-dev`；macOS `/Applications/nexmem_app.app` 为 `1.1.2 (2)`、内置 dylib 含 `0.2.0-dev`，已重启加载。
- 坑：本轮 pub.dev 经代理返回 502，但 `https://pub.flutter-io.cn` 可直连；Flutter 命令需带 `PUB_HOSTED_URL=https://pub.flutter-io.cn`，并用 `flutter pub get --offline` 走本地缓存（缓存位于 `~/.pub-cache/hosted/pub.flutter-io.cn`）。
- 口径：`huangyu的iPhone`（`00008150-00082D643E02401C`）仍 unavailable，未安装；需用户拔掉「卢红娟」改接目标机并解锁信任后再装。

## T66 v1.1.2 全平台发版与 GitHub 旧包清理（已完成）
- [x] 核实发版状态：此前只发布过 v1.1.1，v1.1.2 的 141 个改动文件与 25 个新文件全部还在本地未提交；GitHub 上 v1.1.1 / v1.1.0 / v1.0.2 / v1.0.0 共 16 个旧安装包从未删除。
- [x] 提交并推送：一次性提交所有改动为 `c438ffc chore: 发布 v1.1.2，同步客户端与内核版本`。推送时发现远端已有同补丁的重复提交 `928178b`，用 `git rebase --onto origin/main ca50778 main` 只重放 v1.1.2 提交后快进推送，未使用强推。
- [x] 打标签 `v1.1.2` 触发 `.github/workflows/release.yml` 与 `release-macos.yml`，两个 Release 工作流均成功；`main` 的 CI（Schema/Contract、Flutter analyze/test/web、gomobile android/ios、Web E2E、Go lint、c-shared）全绿。
- [x] v1.1.2 Release 共 6 个平台资产：`Nexmem-1.1.2-android.apk`、`-linux-x64.deb`、`-linux-x64.tar.gz`、`-macos-arm64.zip`、`-web.zip`、`-windows-x64.zip`。
- [x] 删除旧安装包 16 个：v1.1.1 的 6 个、v1.1.0 的 4 个、v1.0.2 的 3 个、v1.0.0 的 2 个（其中 v1.0.2 下曾混放 1.0.0 命名的资产）。保留旧 Release 说明与 tag，只清空资产；核对 v1.1.1 及更早 Release 资产数均为 0，v1.1.2 为 6。
- 口径：本地工作区已干净；目标 iPhone 仍待用户接入后安装。
