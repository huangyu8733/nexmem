import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../features/account/account_manager.dart';
import '../features/account/account_manager_page.dart';
import '../features/account/app_exit.dart';
import '../features/chat/chat_message.dart';
import '../features/chat/chat_page.dart';
import '../features/chat/chat_profile_panel.dart';
import '../features/chat/chat_store.dart';
import '../features/chats/chats_page.dart';
import '../features/chats/conversation.dart';
import '../features/chats/conversation_store.dart';
import '../features/chats/read_marker.dart';
import '../features/contacts/add_friend_dialog.dart';
import '../features/contacts/contact.dart';
import '../features/contacts/contact_detail_page.dart';
import '../features/contacts/contact_service.dart';
import '../features/contacts/contacts_page.dart';
import '../features/contacts/device_list_page.dart';
import '../features/contacts/friends_pane.dart';
import '../features/files/file_hub_page.dart';
import '../features/files/transfer_store.dart';
import '../features/group/group_info_page.dart';
import '../features/group/group_list_page.dart';
import '../features/group/group_service.dart';
import '../features/rtc/call_page.dart';
import '../features/rtc/call_service.dart';
import '../features/rtc/call_video_view.dart';
import '../features/rtc/rtc_media.dart';
import '../features/remote/input/desktop_input_injector.dart';
import '../features/remote/device_map_page.dart';
import '../features/remote/ip_location.dart';
import '../features/remote/ip_location_loader_io.dart'
    if (dart.library.io) '../features/remote/ip_location_loader_io.dart'
    if (dart.library.js_interop) '../features/remote/ip_location_loader_web.dart'
    as ip_loader;
import '../features/remote/local_location_controller.dart';
import '../features/remote/remote_geo_controller.dart';
import '../features/remote/remote_control_page.dart';
import '../features/remote/remote_control_service.dart';
import '../features/remote/remote_device_directory.dart';
import '../features/remote/remote_devices_page.dart';
import '../features/remote/remote_group_controller.dart';
import '../features/remote/remote_host_banner.dart';
import '../features/remote/remote_incoming_dialog.dart';
import '../features/remote/remote_media.dart';
import '../features/remote/remote_session.dart';
import '../features/remote/remote_signal.dart';
import '../features/remote/remote_storage.dart';
import '../features/search/message_search.dart';
import '../features/settings/backup.dart';
import '../features/settings/diagnostics.dart';
import '../features/settings/profile_avatar.dart';
import '../features/settings/profile_panel.dart';
import '../features/settings/profile_view.dart';
import '../features/settings/report.dart';
import '../features/push/push_controller.dart';
import '../features/push/push_platform.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/settings_pane.dart';
import '../features/settings/settings_service.dart';
import '../features/settings/storage_config.dart';
import '../features/social/social_hub_page.dart';
import '../features/social/social_service.dart';
import '../l10n/l10n.dart';
import '../transport/transport.dart';
import 'app_overlay.dart';
import 'app_toast.dart';
import 'call_notice_bar.dart';
import 'message_notification_sound.dart';
import 'pane_header.dart';
import 'connection_status.dart';
import 'core_session.dart';
import 'theme.dart';
import 'web_notice.dart';
import 'web_notice_store.dart';
import 'app_dialog.dart';

/// A-06：把静默吞错改为可观测降级日志。
/// 只在调试构建输出，不改变原有「降级而非中断」的控制流。
void _logDegradation(String where, Object error, [StackTrace? stack]) {
  debugPrint('[nexmem:degrade] $where: $error');
  if (stack != null) {
    debugPrint('[nexmem:degrade] $where stack: $stack');
  }
}

/// 导航壳：`< 720px` 底部三 Tab，`>= 720px` 左栏 + 列表 + 聊天区三栏。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.overlay,
    this.session,
    this.search,
    this.readMarker,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
    this.accountManager,
  });

  /// 根导航浮层控制器：通知条 / 通话页 / 远控页 / toast 都经它提升。
  final AppOverlayController overlay;

  /// 内核会话；为空时保持离线占位（Widget 测试与未配置部署）。
  final CoreSession? session;

  /// 消息检索服务（P6-07）；为空时优先取 [session]，再退回不可用实现。
  final MessageSearchService? search;

  /// 已读推进通道（P6-07）；未接入时本地未读仍照常清零。
  final ReadMarker? readMarker;

  /// 当前外观主题（P6-15）；由 [NexmemApp] 持有并持久化。
  final ThemeMode themeMode;

  /// 设置页切换外观主题的回调。
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  /// 账号管理/临时锁：由应用入口持有，切换账号后整个壳会重建。
  final AccountManager? accountManager;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 分区索引：文件入口独立成栏，位置在「我的 / 设置」之前。
  static const int _sectionChats = 0;
  static const int _sectionContacts = 1;
  static const int _sectionFiles = 2;
  static const int _sectionProfile = 3;
  static const int _sectionSettings = 4;

  List<String> get _titles => <String>[
    context.t('消息'),
    context.t('联系人'),
    context.t('文件'),
    context.t('我的'),
    context.t('设置'),
  ];
  static const List<IconData> _icons = <IconData>[
    Icons.chat_bubble_outline,
    Icons.people_outline,
    Icons.folder_outlined,
    Icons.person_outline,
    Icons.settings_outlined,
  ];

  int _section = _sectionChats;

  /// 由 LayoutBuilder 在 build 时写入，避免行为分流再次读 MediaQuery
  /// 导致「看到移动布局却走桌面点击逻辑」。
  bool _desktopLayout = true;
  bool _wideLayout = true;

  /// 桌面切走再切回文件分区时保留 Tab / 筛选状态。
  Widget? _filePageCache;

  /// 连接状态由 P1-12 状态机的 `state.changed` 推送，导航壳先以在线占位。
  final ValueNotifier<LinkStatus> _link = ValueNotifier<LinkStatus>(
    LinkStatus.online,
  );

  /// 群公告版本号（A-03）：内核 `group.announcement` 事件到达时递增，
  /// 已打开的群资料页监听后重新拉取 `group.members` 刷新公告展示。
  /// 用全局单调计数而非按群计数——页面收到任意公告更新即 reload，成本低且避免漏刷。
  final ValueNotifier<int> _announcementRevision = ValueNotifier<int>(0);

  /// 群「允许成员加好友」开关版本号：管理员本机切换或成员收到控制帧时递增，
  /// 已打开的群资料页与聊天右侧面板监听后重新拉取群资料。
  final ValueNotifier<int> _allowFriendAddRevision = ValueNotifier<int>(0);

  /// 群等级配置 / 成员本群称呼与等级变更版本：内核控制帧到达时递增，
  /// 已打开的群资料页监听后重新拉取 `group.members`。
  final ValueNotifier<int> _groupProfileRevision = ValueNotifier<int>(0);

  /// 在线状态轮询：每 20s 拉一次 `presence.list`，落到会话头像/头部与联系人列表。
  Timer? _presenceTimer;
  bool _presenceBusy = false;

  /// 对端账号（十六进制）→ 是否在线；联系人页监听后渲染状态点。
  final ValueNotifier<Map<String, bool>> _presence =
      ValueNotifier<Map<String, bool>>(<String, bool>{});

  /// 会话数据由壳层持有，P1-16 传输层接通后在此写入内核推送。
  final ConversationStore _conversations = ConversationStore();

  /// 单聊显示信息（对端 base64url → 显示名、备注）：由联系人列表回填，
  /// 优先备注、其次昵称、最后账号短标签。加载会话与备注变更后刷新。
  final Map<String, ({String displayName, String remark})> _peerDisplay =
      <String, ({String displayName, String remark})>{};

  /// 会话页句柄：桌面快捷键（`Ctrl/Cmd + F/N`）直接复用页内入口。
  final GlobalKey<ChatsPageState> _chatsKey = GlobalKey<ChatsPageState>();
  final GlobalKey<ContactsPageState> _contactsKey =
      GlobalKey<ContactsPageState>();

  /// 首屏会话加载中：列表为空时展示骨架屏（ui-spec.md §8）。
  bool _loadingConversations = false;

  /// 内核版本与能力（P6-29）：boot 成功后异步拉取，仅供「关于」页展示。
  CoreInfo? _coreInfo;

  /// 每个会话一份消息列表，首次打开时创建，`ChatStore` 由壳层统一释放。
  final Map<String, ChatStore> _chats = <String, ChatStore>{};

  /// 对端输入状态的自动清除定时器（七-3）：停止输入事件或超时后清除。
  final Map<String, Timer> _typingTimers = <String, Timer>{};

  /// 群聊 @ 候选成员缓存（七-1），按会话 ID 索引，打开群聊时拉取。
  final Map<String, List<MentionCandidate>> _mentionCandidates =
      <String, List<MentionCandidate>>{};

  /// 桌面端当前打开的会话；移动端通过路由进入聊天页。
  ConversationItem? _selected;

  /// 桌面宽屏右侧资料面板开关（P6-22）。null 表示按会话类型自动决定：
  /// 群聊默认展开群信息/成员，单聊默认收起；用户手动切换后以显式值为准。
  bool? _profileOpenOverride;

  /// 会话的 @ 插入通道：群成员面板与聊天输入框共用同一个实例。
  final Map<String, MentionInsertController> _mentionControllers =
      <String, MentionInsertController>{};

  /// 从联系人右栏进入会话前所在的列表，供聊天页返回按钮恢复。
  String _contactsChatReturnPane = '好友';
  Object? _contactsChatReturnData;

  /// 「我的」右栏当前展示的设置面板 label；null 表示只读资料展示。
  /// 点击左栏头像 / 账号卡片重置为 null，点击设置列表项切换为对应 label。
  String? _settingsPane;

  /// 设置面板内部关闭（如选完外观/语言）后递增，强制重建以重新展示面板。
  int _settingsPaneRevision = 0;

  /// 「联系人」右栏当前展示的内容：好友 / 群聊 / 我的设备 / 好友资料 / 设备列表。
  String _contactsPane = '好友';

  /// 右栏内容附带参数：好友对象，或 `{peer, title}` 设备参数。
  Object? _contactsPaneData;

  /// Web 端「仅在线接收」提示（P6-23）：首次进入展开，关闭后落 `localStorage`。
  final WebNoticeStore _webNotice = const WebNoticeStore();
  bool _webNoticeOpen = false;

  /// 内核事件订阅（P1-20）。
  StreamSubscription<CoreEvent>? _events;

  /// 已拉过历史的会话，避免重复请求。
  final Set<String> _loaded = <String>{};

  /// 各会话是否还有更早的历史（P6-07 上翻分页）。
  final Map<String, bool> _hasOlder = <String, bool>{};

  /// 搜索命中直达时待定位的消息（会话 ID → `msg_uuid`，P6-07）。
  final Map<String, String> _highlights = <String, String>{};

  /// 各会话 `msg.listSince` 的 seq 基准（P6-31）。
  ///
  /// 缺失或 0 表示尚未建立基准，新消息走全量 `msg.list` 回退；
  /// 由 `msg.list` / `msg.listSince` 回包的最大 seq 建立并单调推进。
  final Map<String, int> _lastSeq = <String, int>{};

  /// 已完成传输、需要从内核回包补全附件落盘路径的消息。
  ///
  /// 内核在 `message.new` 时消息还没落盘，`transfer.progress(done==total)`
  /// 之后才把本地路径写回附件，但事件不带路径；此处记录待刷新的 msg_uuid，
  /// 避免重复拉历史。
  final Set<String> _attachmentRefreshPending = <String>{};

  MessageSearchService get _search =>
      widget.search ??
      widget.session?.search ??
      const UnavailableMessageSearchService();

  ReadMarker get _readMarker =>
      widget.readMarker ??
      widget.session?.readMarker ??
      const UnavailableReadMarker();

  /// 设置页与举报弹窗所需的内核服务（P6-04/05/06）。
  DiagnosticsService get _diagnostics =>
      widget.session?.diagnostics ?? const UnavailableDiagnosticsService();

  /// 内核连接自检（P6-34）：`core.ping`，未接入时给出显式失败。
  PingService get _ping =>
      widget.session?.ping ?? const UnavailablePingService();

  BackupService get _backup =>
      widget.session?.backup ?? const UnavailableBackupService();

  StorageTestService get _storage =>
      widget.session?.storageTest ?? const UnavailableStorageTestService();

  /// 举报上报（P6-06）：未接入内核时保持显式失败。
  ReportSink get _reportSink =>
      widget.session?.reportSink ?? const UnavailableReportSink();

  /// 通讯录（P2-06）：`contact.list/add/block/remark`。
  ContactService get _contacts =>
      widget.session?.contacts ?? const UnavailableContactService();

  /// 群聊（P4-09）：`group.create` / `group.members`。
  GroupService get _groups =>
      widget.session?.groups ?? const UnavailableGroupService();

  /// 音视频通话服务（P6-28）：`rtc.sendSignal` / `rtc.signal`。
  CallService? _call;
  StreamSubscription<CallInfo>? _callChanges;

  /// 当前通话快照，非空时在状态栏下方展示通话通知条。
  CallInfo? _callInfo;

  /// 通话页是否展开：来电先显示通知条，点击后才进入全屏通话页；
  /// 去电与通话中保持原有自动展开行为。
  bool _callPageOpen = false;

  /// 右上角小提示：替代底部 SnackBar，显示时朗读文案。
  final AppToastController _toasts = AppToastController();

  /// 入站消息「叮咚」提示音（QQ 风格），带节流避免群消息轰炸。
  final MessageNotificationSound _messageSound = MessageNotificationSound();

  /// 对端显示名（来电/去电时从会话列表解析）。
  String _callPeerName = '';

  /// 本地摄像头开关状态（多人通话全局生效）。
  bool _callCameraEnabled = true;

  /// 当前通话对应的会话 id（结束写通话记录用）。
  String? _callConversationId;

  /// 本通是否由本机发起。
  bool _callIsCaller = false;

  /// 已写记录的通话 callId，避免重复写入。
  String? _callRecordedFor;

  /// 结束页收起计时器。
  Timer? _callHideTimer;

  void _initCall(CoreSession session) {
    _call = CallService(
      transport: session.transport,
      mediaFactory: () => FlutterRtcMediaEngine(),
      selfAccount: session.accountId,
    );
    _callChanges = _call!.changes.listen((CallInfo info) {
      if (!mounted) {
        return;
      }
      if (info.state == CallState.incoming && _hasActiveRemote) {
        _showMessage(context.t('请先结束远程控制'));
        unawaited(_call?.reject());
        return;
      }
      final CallInfo? previous = _callInfo;
      setState(() => _callInfo = info);
      if (info.state == CallState.incoming) {
        // 来电先只出通知条，点击后再展开通话页。
        _callPageOpen = false;
        _callRecordedFor = null;
        _callIsCaller = false;
        _callConversationId =
            _conversationIdForPeer(info.peer) ?? _callConversationId;
        _callHideTimer?.cancel();
        _callHideTimer = null;
      } else if (info.state == CallState.outgoing ||
          info.state == CallState.connected) {
        // 去电由用户主动发起，接通后也直接展示通话页。
        _callPageOpen = true;
        _callHideTimer?.cancel();
        _callHideTimer = null;
        _callConversationId =
            _conversationIdForPeer(info.peer) ?? _callConversationId;
      } else if (info.state == CallState.ended) {
        _onCallEnded(info, previous);
      }
    });
  }

  /// 按对端账号找会话 id：优先 `dm:<peer>`，再按 `item.peer` 兜底遍历。
  String? _conversationIdForPeer(String peer) {
    if (peer.isEmpty) {
      return null;
    }
    final ConversationItem? direct =
        _conversations.byId('dm:$peer') ?? _conversations.byId(peer);
    if (direct != null) {
      return direct.id;
    }
    for (final ConversationItem item in _conversations.sorted) {
      if (!item.isGroup && item.peer == peer) {
        return item.id;
      }
    }
    return null;
  }

  /// 对端显示名：会话 id 是 `dm:<peer>`，同时兼容按 `item.peer` 匹配。
  String _conversationTitleForPeer(String peer) {
    final String? id = _conversationIdForPeer(peer);
    final String title = id == null
        ? ''
        : (_conversations.byId(id)?.title ?? '');
    return title;
  }

  /// 通话通知条/通话页显示名：会话标题 → 备注名 → 账号短标签。
  String _callDisplayName() {
    final String name = _callPeerName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    final String peer = _callInfo?.peer ?? '';
    final String display = _peerDisplay[peer]?.displayName ?? '';
    return display.isNotEmpty ? display : shortAccountLabel(peer);
  }

  /// 通话结束：写会话通话记录、失败提示，并在 1.6s 后收起结束页。
  void _onCallEnded(CallInfo info, CallInfo? previous) {
    final String callKey = info.callId.isEmpty
        ? '${info.peer}-${info.startedAt?.millisecondsSinceEpoch ?? 0}'
        : info.callId;
    if (_callRecordedFor != callKey) {
      _callRecordedFor = callKey;
      final String? conversationId = _callConversationId;
      final String? text = _callRecordText(info, context);
      if (conversationId != null && text != null) {
        _appendCallRecord(conversationId, text);
      }
      if (_callIsCaller && info.endReason == CallEndReason.failed) {
        _showMessage(context.t('拨打失败：请检查麦克风/摄像头权限，或对方当前不可达'));
      } else if (_callIsCaller && info.endReason == CallEndReason.noAnswer) {
        _showMessage(context.t('对方无应答'));
      } else if (_callIsCaller && info.endReason == CallEndReason.rejected) {
        _showMessage(context.t('对方已拒绝'));
      }
    }
    if (previous?.state == CallState.ended) {
      return;
    }
    _callHideTimer?.cancel();
    _callHideTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted || _callInfo?.state != CallState.ended) {
        return;
      }
      setState(() {
        _callInfo = null;
        _callPageOpen = false;
      });
    });
  }

  /// 组装通话记录文案；无需记录时返回 null。
  String? _callRecordText(CallInfo info, BuildContext context) {
    final String kind = context.t(info.video ? '视频通话' : '语音通话');
    final Duration elapsed = info.elapsed;
    if (info.startedAt != null && elapsed.inSeconds >= 1) {
      final String mm = elapsed.inMinutes.toString().padLeft(2, '0');
      final String ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
      return context.t('通话时长 {0}', [
        _callIsCaller ? '$kind $mm:$ss' : '$mm:$ss',
      ]);
    }
    if (_callIsCaller) {
      return switch (info.endReason) {
        CallEndReason.rejected => context.t('对方已拒绝'),
        CallEndReason.noAnswer => context.t('对方无应答'),
        CallEndReason.canceled => context.t('已取消'),
        CallEndReason.failed => context.t('呼叫失败'),
        CallEndReason.hangup => context.t('{0}已结束', [kind]),
        CallEndReason.none => null,
      };
    }
    return switch (info.endReason) {
      CallEndReason.rejected => context.t('已拒绝来电'),
      CallEndReason.canceled => context.t('主叫已取消'),
      CallEndReason.failed ||
      CallEndReason.hangup ||
      CallEndReason.noAnswer => context.t('未接来电（{0}）', [kind]),
      CallEndReason.none => null,
    };
  }

  /// 把一条通话记录写进会话（仅内存，重启不保留）。
  void _appendCallRecord(String conversationId, String text) {
    final ConversationItem? item = _conversations.byId(conversationId);
    if (item == null) {
      return;
    }
    final ChatMessage message = ChatMessage(
      id: 'call-${DateTime.now().microsecondsSinceEpoch}',
      conversationId: conversationId,
      text: text,
      sentAt: DateTime.now(),
      senderId: '',
      senderName: '',
      isMine: true,
      isGroup: item.isGroup,
      status: MessageStatus.sent,
    );
    _chatFor(item).receive(message);
    _conversations.touch(conversationId, text);
  }

  /// 远程控制服务：与通话共用 rtc 信令通道，但载荷带 `app:"rc"`。
  ///
  /// 被控端同一时间只接受一个控制端；控制端按对端账号各持一个服务实例，
  /// 因此可以同时控制多台设备（群控）。
  RemoteControlService? _remoteHost;
  StreamSubscription<RemoteInfo>? _remoteHostChanges;
  RemoteInfo? _remoteHostInfo;

  final Map<String, RemoteControlService> _remotePeers =
      <String, RemoteControlService>{};
  final Map<String, StreamSubscription<RemoteInfo>> _remotePeerChanges =
      <String, StreamSubscription<RemoteInfo>>{};
  final Map<String, RemoteInfo> _remotePeerInfos = <String, RemoteInfo>{};
  String? _activeRemotePeer;

  /// 群控：复用控制端服务表，勾选状态跨会话切换保持。
  RemoteGroupController? _remoteGroup;

  /// 「远程设备」台账：本机保存的设备、分类与备注。
  late final RemoteDeviceDirectory _remoteDevices = RemoteDeviceDirectory(
    createRemoteStorage(),
  );

  /// 默认关闭的自动归属地：库下载与查询都在本机完成。
  late final IpLocationService _ipLocation;
  late final RemoteGeoController _remoteGeo;

  /// 本机位置：用户主动填写，只用于估算发现设备距离。
  late final LocalLocationController _localLocation;

  /// 系统 / 浏览器消息通知：平台未接线时自动降级，不影响主流程。
  late final PushController _push;

  bool _remoteStarting = false;
  bool _remoteFileDialogOpen = false;

  /// 是否存在未结束的远控会话（用于与通话互斥）。
  bool get _hasActiveRemote =>
      (_remoteHostInfo != null && !_remoteHostInfo!.isTerminal) ||
      _remotePeerInfos.values.any((RemoteInfo info) => !info.isTerminal);

  void _initRemote(CoreSession session) {
    _remoteHost = _createRemoteService(session);
    unawaited(_remoteHost!.initialize());
    _remoteHostChanges = _remoteHost!.changes.listen(_onRemoteHostInfo);
    _remoteGroup = RemoteGroupController(
      services: _remotePeers.cast<String, RemoteGroupService>(),
      deviceTypeOf: (String peer) =>
          _remoteDevices.find(peer)?.type ?? RemoteDeviceType.other,
    );
  }

  RemoteControlService _createRemoteService(CoreSession session) {
    return RemoteControlService(
      transport: session.transport,
      mediaFactory: () => FlutterRemoteMediaEngine(),
      injector: createDesktopInputInjector(),
      selfAccount: session.accountId,
      selfName: session.account?.displayName ?? '',
      isContact: (String peer) async {
        final List<Contact>? friends = _contactsKey.currentState?.friends;
        // 通讯录尚未加载时不做拒绝，避免启动瞬间误伤；正常路径仍按联系人校验。
        if (friends == null || friends.isEmpty) {
          return true;
        }
        return friends.any(
          (Contact contact) => contact.peer == peer || contact.id == peer,
        );
      },
      canAccept: () => _callInfo == null || _callInfo!.state == CallState.ended,
      onFileOffer: _confirmRemoteFile,
    );
  }

  void _onRemoteHostInfo(RemoteInfo info) {
    if (!mounted) {
      return;
    }
    setState(() => _remoteHostInfo = info);
    if (info.isIncoming &&
        _callInfo != null &&
        _callInfo!.state != CallState.ended) {
      unawaited(_remoteHost?.reject(reason: '本机正在进行通话'));
      return;
    }
    if (info.isTerminal) {
      final String sid = info.sid;
      Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) {
          return;
        }
        if (_remoteHostInfo?.sid != sid ||
            !(_remoteHostInfo?.isTerminal ?? false)) {
          return;
        }
        setState(() => _remoteHostInfo = null);
        _remoteHost?.dismiss();
      });
    }
  }

  /// 取得（或创建）发往 [peer] 的控制端服务。
  RemoteControlService? _ensureRemotePeer(String peer, {String name = ''}) {
    final CoreSession? session = widget.session;
    if (session == null) {
      return null;
    }
    RemoteControlService? service = _remotePeers[peer];
    if (service == null) {
      service = _createRemoteService(session);
      _remotePeers[peer] = service;
      unawaited(service.initialize());
      _remotePeerChanges[peer] = service.changes.listen((RemoteInfo info) {
        _onRemotePeerInfo(peer, info);
      });
    }
    if (name.isNotEmpty) {
      service.updatePeerName(name);
    }
    return service;
  }

  void _onRemotePeerInfo(String peer, RemoteInfo info) {
    if (!mounted) {
      return;
    }
    setState(() {
      _remotePeerInfos[peer] = info;
      _activeRemotePeer ??= peer;
    });
    if (info.isTerminal) {
      final RemoteControlService? service = _remotePeers[peer];
      final String sid = info.sid;
      Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) {
          return;
        }
        // 期间可能已对同一对端重新发起会话，只有仍指向旧会话时才清理。
        if (!identical(_remotePeers[peer], service) ||
            _remotePeerInfos[peer]?.sid != sid) {
          return;
        }
        setState(() {
          _remotePeerInfos.remove(peer);
          final StreamSubscription<RemoteInfo>? sub = _remotePeerChanges.remove(
            peer,
          );
          if (sub != null) {
            unawaited(sub.cancel());
          }
          final RemoteControlService? removed = _remotePeers.remove(peer);
          if (removed != null) {
            unawaited(removed.dispose());
          }
          if (_activeRemotePeer == peer) {
            _activeRemotePeer = _remotePeerInfos.isEmpty
                ? null
                : _remotePeerInfos.keys.last;
          }
        });
      });
    }
  }

  Future<bool> _confirmRemoteFile(RemoteFileOffer offer) async {
    if (!mounted || _remoteFileDialogOpen) {
      return false;
    }
    _remoteFileDialogOpen = true;
    try {
      final bool? accepted = await showAppDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(context.t('接收文件')),
          content: Text(
            context.t('{0} 请求发送文件「{1}」（{2}），是否接收？', <String>[
              offer.peer,
              offer.name,
              _formatBytes(offer.size),
            ]),
          ),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('remote-file-reject'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.t('拒绝')),
            ),
            FilledButton(
              key: const ValueKey<String>('remote-file-accept'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.t('接收')),
            ),
          ],
        ),
      );
      return accepted ?? false;
    } finally {
      _remoteFileDialogOpen = false;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  void _startRemote(ConversationItem item) {
    if (item.isGroup || item.peer.isEmpty) {
      _showMessage(context.t('远程控制仅支持单聊'));
      return;
    }
    _startRemotePeer(item.peer, item.title);
  }

  void _startRemotePeer(
    String peer,
    String name, {
    String credential = '',
    bool silent = false,
  }) {
    if (peer.isEmpty) {
      _showMessage(context.t('会话缺少对端账号，无法发起远控'));
      return;
    }
    if (silent && credential.isEmpty) {
      _showMessage(context.t('请先为该远程设备设置控制密码'));
      return;
    }
    if (_callInfo != null && _callInfo!.state != CallState.ended) {
      _showMessage(context.t('请先结束当前通话'));
      return;
    }
    final RemoteControlService? existing = _remotePeers[peer];
    if (existing != null && existing.isBusy) {
      setState(() => _activeRemotePeer = peer);
      _showMessage(context.t('正在控制该设备'));
      return;
    }
    if (_remoteStarting) {
      return;
    }
    final RemoteControlService? remote = _ensureRemotePeer(peer, name: name);
    if (remote == null) {
      _showMessage(context.t('远程控制暂不可用'));
      return;
    }
    existing?.dismiss();
    setState(() => _activeRemotePeer = peer);
    _remoteStarting = true;
    unawaited(
      remote
          .request(peer, peerName: name, credential: credential, silent: silent)
          .whenComplete(() {
            if (mounted) {
              setState(() => _remoteStarting = false);
            }
          }),
    );
  }

  Future<void> _sendRemoteFile() async {
    final CoreSession? session = widget.session;
    final String? peer = _activeRemotePeer;
    final RemoteControlService? remote = peer == null
        ? null
        : _remotePeers[peer];
    final Future<ChatAttachment?> Function()? pick = session?.pickFile;
    if (remote == null || pick == null) {
      _showMessage(context.t('当前无法选择文件'));
      return;
    }
    final ChatAttachment? file = await pick();
    if (file == null || file.path.isEmpty) {
      return;
    }
    await remote.sendFile(file.path, name: file.name);
  }

  void _closeRemote() {
    final String? peer = _activeRemotePeer;
    if (!mounted || peer == null) {
      return;
    }
    setState(() {
      _remotePeerInfos.remove(peer);
      _activeRemotePeer = _remotePeerInfos.isEmpty
          ? null
          : _remotePeerInfos.keys.last;
    });
    _remotePeers[peer]?.dismiss();
  }

  void _selectRemotePeer(String peer) {
    if (!_remotePeerInfos.containsKey(peer)) {
      return;
    }
    setState(() => _activeRemotePeer = peer);
  }

  /// 发起通话：单聊直呼对端；群聊拉取成员后对每人各建一路 Mesh 会话。
  bool _callStarting = false;

  /// 右上角小提示：显示文案并朗读，不再使用底部 SnackBar。
  void _showMessage(String message) {
    if (!mounted) return;
    _toasts.show(message);
  }

  void _startCall(ConversationItem item, bool video) {
    if (_callStarting) return;
    if (_hasActiveRemote) {
      _showMessage(context.t('请先结束远程控制'));
      return;
    }
    final CallService? call = _call;
    if (call == null) {
      _showMessage(context.t('通话功能暂不可用'));
      return;
    }
    setState(() {
      _callPeerName = item.title;
      _callCameraEnabled = true;
      _callStarting = true;
      _callConversationId = item.id;
      _callIsCaller = true;
      _callRecordedFor = null;
    });
    if (item.isGroup) {
      unawaited(
        _startGroupCall(call, item.id, video).whenComplete(() {
          if (mounted) setState(() => _callStarting = false);
        }),
      );
      return;
    }
    if (item.peer.isEmpty) {
      if (mounted) setState(() => _callStarting = false);
      _showMessage(context.t('会话缺少对端账号，无法发送'));
      return;
    }
    unawaited(
      call.startOutgoing(item.peer, video: video).whenComplete(() {
        if (mounted) setState(() => _callStarting = false);
      }),
    );
  }

  /// 群聊通话：从 `group.members` 取成员账号，排除自己后交给 CallService。
  Future<void> _startGroupCall(
    CallService call,
    String groupId,
    bool video,
  ) async {
    try {
      final GroupInfo info = await _groups.members(groupId);
      final String self = widget.session?.accountId ?? '';
      final List<String> peers = info.members
          .where((GroupMember m) => m.account != self)
          .map((GroupMember m) => m.account)
          .toList(growable: false);
      if (peers.isEmpty) {
        if (mounted) _showMessage(context.t('群聊暂无其他成员'));
        return;
      }
      await call.startGroupOutgoing(peers, video: video);
    } on Object catch (error) {
      debugPrint('Nexmem 群聊通话发起失败：$error');
      if (mounted) {
        _showMessage(context.t('发起通话失败：{0}', <String>['$error']));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _webNoticeOpen = kIsWeb && !_webNotice.seen;
    unawaited(_remoteDevices.load());
    final ({
      IpLocationDownloader download,
      IpLocationBundledReader readBundled,
      Future<Uint8List?> Function() readCache,
      Future<void> Function(Uint8List bytes) writeCache,
    })
    loader = ip_loader.makeIpLocationLoader();
    _ipLocation = IpLocationService(
      downloader: loader.download,
      readBundled: loader.readBundled,
      readCache: loader.readCache,
      writeCache: loader.writeCache,
    );
    _remoteGeo = RemoteGeoController(
      service: _ipLocation,
      settings: widget.session?.settings ?? const UnavailableSettingsService(),
      directory: _remoteDevices,
    );
    unawaited(_remoteGeo.load());
    _localLocation = LocalLocationController(
      settings: widget.session?.settings ?? const UnavailableSettingsService(),
    );
    unawaited(_localLocation.load());
    _push = PushController(
      platform: makePushPlatform(settings: widget.session?.settings),
      settings: widget.session?.settings ?? const UnavailableSettingsService(),
      pushService: widget.session?.push,
      onOpenConversation: _openNotificationTarget,
    );
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    _loadingConversations = true;
    _initCall(session);
    _initRemote(session);
    _events = session.transport.events.listen(_onEvent);
    // 传输进度是全局状态：不打开文件分区也要订阅，避免下载期间切页丢进度。
    TransferStore.instance.attach(session.transport);
    // 头像：内核就绪后加载本机已保存头像，供左栏/资料卡等位置展示。
    ProfileAvatarStore.instance.attach(session.settings);
    unawaited(_boot(session));
  }

  /// 通知点击：找到对应会话后复用 _open 的既有跳转逻辑。
  void _openNotificationTarget(String conversationId) {
    final ConversationItem? item = _conversations.byId(conversationId);
    if (item == null) {
      _showMessage(context.t('会话不存在或已被删除'));
      return;
    }
    final bool desktop =
        !Navigator.of(context).mounted ||
        MediaQuery.sizeOf(context).width >= 720;
    _open(item, desktop);
  }

  @override
  void dispose() {
    widget.overlay.release(this);
    _push.dispose();
    _remoteGeo.dispose();
    _localLocation.dispose();
    TransferStore.instance.detach();
    _presenceTimer?.cancel();
    _callHideTimer?.cancel();
    unawaited(_events?.cancel());
    unawaited(_callChanges?.cancel());
    unawaited(_call?.dispose());
    unawaited(_remoteHostChanges?.cancel());
    unawaited(_remoteHost?.dispose());
    for (final StreamSubscription<RemoteInfo> sub
        in _remotePeerChanges.values) {
      unawaited(sub.cancel());
    }
    _remotePeerChanges.clear();
    for (final RemoteControlService service in _remotePeers.values) {
      unawaited(service.dispose());
    }
    _remotePeers.clear();
    _remoteGroup = null;
    for (final Timer timer in _typingTimers.values) {
      timer.cancel();
    }
    for (final ChatStore chat in _chats.values) {
      chat.dispose();
    }
    for (final MentionInsertController controller
        in _mentionControllers.values) {
      controller.dispose();
    }
    _conversations.dispose();
    _toasts.dispose();
    unawaited(_messageSound.dispose());
    _link.dispose();
    _presence.dispose();
    _announcementRevision.dispose();
    _allowFriendAddRevision.dispose();
    _groupProfileRevision.dispose();
    super.dispose();
  }

  /// 读取账号并拉取会话首页；连接未就绪时短暂重试，最终失败则状态条显示离线。
  Future<void> _boot(CoreSession session) async {
    try {
      for (int attempt = 0; attempt < 3 && mounted; attempt++) {
        try {
          // 上次活跃档案可能不是平台默认目录；未启动内核时用该目录启动。
          await session.bootstrap(
            startConfig: await widget.accountManager?.startupConfigForActive(),
          );
          // 内核就绪后回填当前账号 ID/数据目录，供多账号切换复用。
          unawaited(widget.accountManager?.syncCurrentAccount());
          // 头像缓存初始化早于 core.start，彼时 settings.get 会失败；
          // 内核就绪后必须重新读取一次，否则左栏/「我的」页一直显示占位图标。
          unawaited(ProfileAvatarStore.instance.reload());
          await _reloadConversations();
          // 联系人/群列表在页面 initState 时就会首次拉取；iOS 真机上
          // gomobile 内核首次启动需生成主密钥，core.start 完成更慢，首次
          // 拉取可能早于内核就绪并返回 NOT_STARTED，错误条一直挂着。
          // 内核就绪后主动重拉一次，覆盖慢启动竞态。
          unawaited(_contactsKey.currentState?.reload());
          unawaited(_contactsKey.currentState?.reloadGroups());
          // 在线状态依赖会话列表里的对端账号，加载完成后启动轮询。
          _startPresencePolling(session);
          if (mounted) {
            _link.value = LinkStatus.online;
          }
          // 版本协商（P6-29）：失败不影响上线，关于页按未知处理。
          unawaited(_loadCoreInfo(session));
          return;
        } on NexmemException catch (error) {
          if (error.code == 'UNAUTHORIZED' && mounted) {
            _showMessage(context.t('访问令牌无效或已轮换，请重新进入并填写 token'));
          }
          if (!error.retryable || attempt == 2) {
            break;
          }
          await Future<void>.delayed(
            Duration(milliseconds: 800 * (attempt + 1)),
          );
        } catch (error, stack) {
          _logDegradation('重连重试', error, stack);
          break;
        }
      }
      if (mounted) {
        _link.value = LinkStatus.offline;
      }
    } finally {
      if (mounted) {
        setState(() => _loadingConversations = false);
      }
    }
  }

  /// 拉取 `core.info` 供关于页展示版本与能力（P6-29）。
  Future<void> _loadCoreInfo(CoreSession session) async {
    final CoreInfo? info = await session.loadInfo();
    if (mounted && info != null) {
      setState(() => _coreInfo = info);
    }
  }

  /// 按 `conversation.list` 刷新会话列表，保留本地置顶与免打扰。
  Future<void> _reloadConversations() async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    try {
      final List<ConversationItem> items = await session.conversations.list(
        limit: 50,
      );
      for (final ConversationItem item in items) {
        final ConversationItem? existing = _conversations.byId(item.id);
        _conversations.upsert(
          existing == null
              ? item
              : item.copyWith(pinned: existing.pinned, muted: existing.muted),
        );
      }
    } catch (error, stack) {
      // 会话列表失败不阻断聊天页；状态条已由 state.changed / boot 反映。
      _logDegradation('加载会话列表', error, stack);
    }
    await _reloadPeerDisplay();
  }

  /// 从通讯录回填单聊显示名：优先备注，其次昵称，最后账号短标签。
  ///
  /// 内核 `conversation.list` 的单聊 title 常为空，聊天头部与会话列表据此
  /// 显示账号短串；这里用本机备注把展示名补齐，不改内核数据。
  Future<void> _reloadPeerDisplay() async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    try {
      final List<Contact> contacts = await session.contacts.list(limit: 1000);
      final Map<String, ({String displayName, String remark})> next =
          <String, ({String displayName, String remark})>{};
      for (final Contact contact in contacts) {
        final String peer = contact.peer.isNotEmpty
            ? contact.peer
            : normalizeAccountHex(contact.id);
        final String remark = contact.note.trim();
        final String nickname = contact.name.trim();
        final String displayName = remark.isNotEmpty
            ? remark
            : (nickname.isNotEmpty ? nickname : shortAccountLabel(peer));
        next[peer] = (displayName: displayName, remark: remark);
      }
      _peerDisplay
        ..clear()
        ..addAll(next);
      for (final ConversationItem item in _conversations.sorted) {
        if (item.isGroup || item.peer.isEmpty) {
          continue;
        }
        final String? displayName = _peerDisplay[item.peer]?.displayName;
        if (displayName != null && displayName != item.title) {
          _conversations.upsert(item.copyWith(title: displayName));
        }
      }
    } catch (error, stack) {
      // 通讯录读取失败只影响展示名，不阻断会话列表。
      _logDegradation('加载联系人显示名', error, stack);
    }
  }

  ({String displayName, String remark})? _peerDisplayFor(
    ConversationItem item,
  ) {
    if (item.isGroup || item.peer.isEmpty) {
      return null;
    }
    return _peerDisplay[item.peer];
  }

  /// 启动在线状态轮询：首次立即刷新，之后每 20s 刷新一次。
  void _startPresencePolling(CoreSession session) {
    _presenceTimer?.cancel();
    unawaited(_refreshPresence(session));
    _presenceTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_refreshPresence(session));
    });
  }

  /// 拉取单聊对端与好友的在线状态，写回会话列表（列表/聊天头部）与联系人页。
  ///
  /// `conversation.list` 的 `peer` 是 base64url，而 `presence.list` 使用十六进制，
  /// 统一用 [normalizeAccountHex] 换算；状态以十六进制为 key 供联系人页复用。
  Future<void> _refreshPresence(CoreSession session) async {
    if (_presenceBusy) {
      return;
    }
    final Set<String> hexIds = <String>{};
    final Map<String, String> peerByHex = <String, String>{};
    for (final ConversationItem item in _conversations.sorted) {
      if (item.isGroup || item.peer.isEmpty) {
        continue;
      }
      final String hex = normalizeAccountHex(item.peer);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
        continue;
      }
      hexIds.add(hex);
      peerByHex[hex] = item.peer;
    }
    try {
      // 好友可能还没有会话，一并探测，联系人列表才能显示状态点。
      for (final Contact contact in await session.contacts.list(limit: 1000)) {
        final String hex = normalizeAccountHex(contact.id);
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
          hexIds.add(hex);
        }
      }
    } catch (error, stack) {
      _logDegradation('加载联系人用于在线状态', error, stack);
    }
    if (hexIds.isEmpty) {
      return;
    }
    _presenceBusy = true;
    try {
      final List<Presence> list = await session.social.listPresence(
        hexIds.toList(),
      );
      final Map<String, bool> byHex = <String, bool>{};
      final Map<String, PresenceStatus> byPeer = <String, PresenceStatus>{};
      for (final Presence presence in list) {
        // known=false 表示既无探测结果也无缓存，保持未知，避免误报离线。
        if (!presence.known) {
          continue;
        }
        final String hex = normalizeAccountHex(presence.account);
        byHex[hex] = presence.online;
        final String? peer = peerByHex[hex];
        if (peer != null) {
          byPeer[peer] = presence.online
              ? PresenceStatus.online
              : PresenceStatus.offline;
        }
      }
      if (!mounted) {
        return;
      }
      bool same = _presence.value.length == byHex.length;
      if (same) {
        for (final MapEntry<String, bool> entry in byHex.entries) {
          if (_presence.value[entry.key] != entry.value) {
            same = false;
            break;
          }
        }
      }
      if (!same) {
        _presence.value = byHex;
      }
      _conversations.applyPresence(byPeer);
    } catch (error, stack) {
      _logDegradation('刷新在线状态', error, stack);
    } finally {
      _presenceBusy = false;
    }
  }

  /// 用消息回包建立并推进增量基准（取最大 seq）。
  ///
  /// `msg.list` 按时间倒序回包、`msg.listSince` 按 seq 升序回包，
  /// 跨设备消息的时间与入库序可能不一致，故取最大值而非首末条。
  void _recordSeq(String conversationId, Iterable<ChatMessage> messages) {
    int max = _lastSeq[conversationId] ?? 0;
    for (final ChatMessage message in messages) {
      if (message.seq > max) {
        max = message.seq;
      }
    }
    if (max > 0) {
      _lastSeq[conversationId] = max;
    }
  }

  /// 首次打开会话时拉取最近消息与群盘状态。
  Future<void> _ensureLoaded(ConversationItem item) async {
    final CoreSession? session = widget.session;
    final ChatStore store = _chatFor(item);
    if (session == null || !_loaded.add(item.id)) {
      return;
    }
    try {
      final HistoryPage page = await session.historyPage(item);
      for (final ChatMessage message in page.messages) {
        store.receive(message);
      }
      _recordSeq(item.id, page.messages);
      _hasOlder[item.id] = page.hasMore;
    } catch (error, stack) {
      _logDegradation('加载会话消息 ${item.id}', error, stack);
      _loaded.remove(item.id);
    }
    if (item.isGroup) {
      try {
        store.setGroupStorageStatus(await session.groupStorage(item));
      } catch (error, stack) {
        // 群资料失败时保持 unknown，不误报「未配置群盘」。
        _logDegradation('查询群盘状态 ${item.id}', error, stack);
      }
      // 七-1：拉取群成员作为 @ 候选（排除自己），失败时保持空列表。
      try {
        final GroupInfo info = await session.groups.members(groupIdOf(item.id));
        final String self = widget.session?.accountId ?? '';
        _mentionCandidates[item.id] = info.members
            .where((GroupMember m) => m.account != self)
            .map(
              (GroupMember m) =>
                  MentionCandidate(account: m.account, name: m.label),
            )
            .toList(growable: false);
      } catch (error, stack) {
        _logDegradation('加载 @ 候选成员 ${item.id}', error, stack);
      }
    }
  }

  /// 会话的 @ 候选成员（七-1）；单聊返回空列表。
  List<MentionCandidate> _mentionsFor(ConversationItem item) => item.isGroup
      ? (_mentionCandidates[item.id] ?? const <MentionCandidate>[])
      : const <MentionCandidate>[];

  /// 每个会话独立的 @ 插入通道，供右侧群成员面板写、聊天输入框读。
  MentionInsertController _mentionControllerFor(ConversationItem item) =>
      _mentionControllers.putIfAbsent(item.id, MentionInsertController.new);

  /// 群聊在宽屏默认展开资料面板；单聊默认收起；手动操作后保留用户选择。
  bool _profileVisibleFor(ConversationItem item, bool allowProfile) =>
      allowProfile && (_profileOpenOverride ?? item.isGroup);

  /// 向上翻页加载更早消息（P6-07）；返回是否还有更早的历史。
  Future<bool> _loadOlder(ConversationItem item) async {
    final CoreSession? session = widget.session;
    if (session == null || _hasOlder[item.id] == false) {
      return false;
    }
    final ChatStore store = _chatFor(item);
    final List<ChatMessage> messages = store.messages;
    if (messages.isEmpty) {
      return false;
    }
    final String beforeId = messages.first.id;
    try {
      final HistoryPage page = await session.historyPage(
        item,
        beforeId: beforeId,
      );
      for (final ChatMessage message in page.messages) {
        store.receive(message);
      }
      _hasOlder[item.id] = page.hasMore;
      return page.hasMore;
    } catch (error, stack) {
      // 分页失败保持原状态，用户可再次上翻重试。
      _logDegradation('加载更早消息 ${item.id}', error, stack);
      return _hasOlder[item.id] ?? true;
    }
  }

  /// 内核事件：状态机、新消息、发送状态与重同步（P1-20 / P1-22）。
  void _onEvent(CoreEvent event) {
    if (kDebugMode) {
      debugPrint('Nexmem event ${event.type} seq=${event.seq}');
    }
    if (event.type == 'state.changed') {
      _applyState(event.data['state']);
    } else if (event.type == 'message.new') {
      unawaited(_onMessageNew(event.data));
    } else if (event.type == 'message.updated') {
      _onMessageUpdated(event.data);
    } else if (event.type == 'message.recalled') {
      _onMessageRecalled(event.data);
    } else if (event.type == 'message.edited') {
      _onMessageEdited(event.data);
    } else if (event.type == 'message.expired') {
      _onMessageExpired(event.data);
    } else if (event.type == 'typing') {
      _onTyping(event.data);
    } else if (event.type == 'group.dissolved') {
      _onGroupDissolved(event.data);
    } else if (event.type == 'group.announcement') {
      // A-03：内核已更新本机群公告并发出事件，递增版本号让打开的群资料页刷新。
      // 无需解析 data——群资料页 reload 时会重新拉取 group.members 权威数据。
      _announcementRevision.value++;
    } else if (event.type == 'group.storageRemoved') {
      // C-05：管理员移除了群盘，内核已清本机配置；复用同一版本号让群资料页
      // 重新拉取 group.members 刷新 storage_configured 展示。
      _announcementRevision.value++;
    } else if (event.type == 'group.allowFriendAddChanged') {
      // 管理员广播了加好友开关变更，刷新已打开的群资料与成员面板。
      _allowFriendAddRevision.value++;
    } else if (event.type == 'group.levelsChanged' ||
        event.type == 'group.memberProfileChanged') {
      // 等级配置或成员称呼/等级控制帧到达，刷新群资料与成员资料。
      _groupProfileRevision.value++;
    } else if (event.type == 'conversation.changed') {
      unawaited(_reloadConversations());
    } else if (event.type == 'transfer.progress') {
      _onTransferProgress(event.data);
    } else if (event.type == 'rtc.signal') {
      _onRtcSignal(event.data);
    } else if (event.type == 'resync_required') {
      _loaded.clear();
      _hasOlder.clear();
      _highlights.clear();
      _lastSeq.clear();
      unawaited(_reloadConversations());
    } else if (event.type == 'friend.request.new' ||
        event.type == 'friend.request.resolved' ||
        event.type == 'group.joinRequested' ||
        event.type == 'group.joinResolved' ||
        event.type == 'moment.new' ||
        event.type == 'poll.updated') {
      // 社交事件：递增版本号，-social 页面与联系人列表监听后刷新自身数据。
      _socialRevision.value++;
    }
  }

  /// 社交事件版本号：社交中心页面监听后刷新自身数据。
  final ValueNotifier<int> _socialRevision = ValueNotifier<int>(0);
  ValueNotifier<int> get socialRevision => _socialRevision;

  /// 收到对端 RTC 信令（P6-28）：交给通话状态机，来电时解析对端显示名。
  void _onRtcSignal(Map<String, dynamic> data) {
    final Object? peer = data['peer'];
    final Object? payload = data['payload_b64'];
    if (peer is! String || payload is! String) {
      return;
    }
    final String name = _conversationTitleForPeer(peer);
    if (RemoteSignal.peekIsRemote(payload)) {
      _routeRemoteSignal(peer, payload, name);
      return;
    }
    final CallService? call = _call;
    if (call == null) {
      return;
    }
    if (name.isNotEmpty) {
      setState(() => _callPeerName = name);
    }
    unawaited(call.handleSignal(peer, payload));
  }

  /// 远控信令路由：新请求交给被控端，其余按 sid 找到对应控制端会话。
  void _routeRemoteSignal(String peer, String payload, String name) {
    final RemoteSignal signal;
    try {
      signal = RemoteSignal.fromPayloadB64(payload);
    } on FormatException {
      return;
    }
    if (signal.type == RemoteSignalType.request) {
      if (name.isNotEmpty) {
        _remoteHost?.updatePeerName(name);
      }
      unawaited(_remoteHost?.handleSignal(peer, payload));
      return;
    }
    final RemoteControlService? peerService = _remotePeers[peer];
    if (peerService?.current?.sid == signal.sid) {
      if (name.isNotEmpty) {
        peerService?.updatePeerName(name);
      }
      unawaited(peerService!.handleSignal(peer, payload));
      return;
    }
    final RemoteControlService? host = _remoteHost;
    if (host?.current?.sid == signal.sid) {
      if (name.isNotEmpty) {
        host?.updatePeerName(name);
      }
      unawaited(host!.handleSignal(peer, payload));
      return;
    }
    // 终态清理期间的迟到信令：交给该对端的控制端会话兜底忽略。
    unawaited((peerService ?? host)?.handleSignal(peer, payload));
  }

  void _applyState(Object? state) {
    final LinkStatus next;
    if (state == 'init' || state == 'starting') {
      // A-05：启动中状态此前静默丢弃，现展示「连接中」。
      next = LinkStatus.connecting;
    } else if (state == 'online') {
      next = LinkStatus.online;
    } else if (state == 'degraded') {
      next = LinkStatus.relay;
    } else if (state == 'offline' || state == 'stopped') {
      next = LinkStatus.offline;
    } else {
      return;
    }
    if (mounted) {
      _link.value = next;
    }
  }

  /// 入站消息的类型标签；内核事件通常只给指针，未知类型统一显示「新消息」。
  String _incomingMessageKind(Map<String, dynamic> data) {
    final Object? hint =
        data['kind'] ?? data['msg_type'] ?? data['message_type'];
    if (hint is String) {
      switch (hint.toLowerCase()) {
        case 'voice':
        case 'audio':
          return context.t('语音');
        case 'video':
          return context.t('视频');
        case 'image':
        case 'picture':
          return context.t('图片');
        case 'file':
          return context.t('文件');
      }
    }
    return context.t('新消息');
  }

  /// 新消息：刷新会话摘要；已打开的会话按 seq 增量补齐（P6-31）。
  Future<void> _onMessageNew(Map<String, dynamic> data) async {
    // 入站消息（文本/语音/图片/文件）统一响一声 QQ 风格提示音；
    // 自己发的消息（多端同步回来的 direction=out）不响。
    if (data['direction'] == 'in') {
      unawaited(_messageSound.notify());
    }
    final Object? id = data['conversation_id'];
    if (data['direction'] == 'in' && id is String && id.isNotEmpty) {
      // 事件只有指针没有正文：通知不泄漏消息内容，点击后再拉取密文。
      final ConversationItem? target = _conversations.byId(id);
      final String title = target == null
          ? context.t('新消息')
          : _peerDisplayFor(target)?.displayName ?? target.title;
      // 应用内提示走根浮层，聊天页里也能看到；当前正在看的会话不重复弹。
      // 事件只给指针不泄漏正文，点击「查看」再跳转并解密。
      if (target != null && id != _push.activeConversationId) {
        _toasts.show(
          '$title · ${_incomingMessageKind(data)}',
          speak: false,
          actionLabel: context.t('查看详情'),
          onAction: () => _openNotificationTarget(id),
        );
      }
      unawaited(
        _push.onIncomingMessage(
          conversationId: id,
          title: title,
          body: context.t('你有一条新消息，点击查看详情'),
        ),
      );
    }
    final CoreSession? session = widget.session;
    if (id is! String || id.isEmpty || session == null) {
      return;
    }
    final ChatStore? store = _chats[id];
    final ConversationItem? item = _conversations.byId(id);
    if (store != null && item != null) {
      final int base = _lastSeq[id] ?? 0;
      if (base > 0) {
        try {
          final SincePage page = await session.since(item, afterSeq: base);
          for (final ChatMessage message in page.messages) {
            store.merge(message);
          }
          if (page.lastSeq > base) {
            _lastSeq[id] = page.lastSeq;
          }
        } catch (error, stack) {
          // 增量失败回退全量，避免 seq 基准失效时漏消息。
          _logDegradation('增量同步 ${item.id}', error, stack);
          await _refreshRecent(item, store, session);
        }
      } else {
        // 尚未建立基准（首次事件先于历史加载、或历史加载失败）。
        await _refreshRecent(item, store, session);
      }
    }
    await _reloadConversations();
  }

  /// 无增量基准或使用增量失败时的全量回退路径。
  Future<void> _refreshRecent(
    ConversationItem item,
    ChatStore store,
    CoreSession session,
  ) async {
    try {
      final List<ChatMessage> messages = await session.history(item, limit: 20);
      for (final ChatMessage message in messages) {
        store.merge(message);
      }
      _recordSeq(item.id, messages);
    } catch (error, stack) {
      // 拉取失败时保留事件指针，等重同步再补。
      _logDegradation('重同步消息 ${item.id}', error, stack);
    }
  }

  void _onMessageUpdated(Map<String, dynamic> data) {
    final Object? id = data['msg_uuid'];
    if (id is! String || id.isEmpty) {
      return;
    }
    final Object? conversationId = data['conversation_id'];
    ChatStore? store = conversationId is String ? _chats[conversationId] : null;
    if (store == null) {
      for (final ChatStore chat in _chats.values) {
        if (chat.byId(id) != null) {
          store = chat;
          break;
        }
      }
    }
    // 对端关闭离线存储时内核在失败事件上带 reason（P3-09）：
    // 单聊常驻「仅支持在线发送」提示，不用等用户重试才暴露。
    if (data['reason'] == offlineStorageDisabledCode) {
      store?.setPeerOfflineStorageDisabled(true);
    }
    store?.updateStatus(id, messageStatusFromState(data['state']));
  }

  /// 撤回事件（P6-12）：按 msg_uuid 移除气泡并刷新会话摘要。
  void _onMessageRecalled(Map<String, dynamic> data) {
    final Object? id = data['msg_uuid'];
    if (id is! String || id.isEmpty) {
      return;
    }
    final Object? conversationId = data['conversation_id'];
    ChatStore? store = conversationId is String ? _chats[conversationId] : null;
    store ??= _chatWithMessage(id);
    store?.remove(id);
    unawaited(_reloadConversations());
  }

  /// 编辑事件（七-2）：按 msg_uuid 更新气泡正文并标记「已编辑」。
  void _onMessageEdited(Map<String, dynamic> data) {
    final Object? id = data['msg_uuid'];
    final Object? text = data['text'];
    if (id is! String || id.isEmpty || text is! String) {
      return;
    }
    final Object? conversationId = data['conversation_id'];
    ChatStore? store = conversationId is String ? _chats[conversationId] : null;
    store ??= _chatWithMessage(id);
    final Object? editedAt = data['edited_at'];
    store?.updateEdited(id, text, editedAt is num ? editedAt.toInt() : 0);
  }

  /// 定时消息到期事件（七-4）：内核已物理删除本机副本，客户端移除气泡。
  void _onMessageExpired(Map<String, dynamic> data) {
    final Object? id = data['msg_uuid'];
    if (id is! String || id.isEmpty) {
      return;
    }
    final Object? conversationId = data['conversation_id'];
    ChatStore? store = conversationId is String ? _chats[conversationId] : null;
    store ??= _chatWithMessage(id);
    store?.remove(id);
  }

  /// 输入状态事件（七-3）：peer 是 base64 账号，定位单聊会话并展示，
  /// 停止输入或 6 秒无后续事件时自动清除。
  void _onTyping(Map<String, dynamic> data) {
    final Object? peer = data['peer'];
    if (peer is! String || peer.isEmpty) {
      return;
    }
    final ConversationItem? item = _conversations.byPeer(peer);
    if (item == null) {
      return;
    }
    final bool typing = data['typing'] == true;
    final ChatStore store = _chatFor(item);
    _typingTimers[item.id]?.cancel();
    if (!typing) {
      store.setTyping(false);
      _typingTimers.remove(item.id);
      return;
    }
    store.setTyping(true);
    _typingTimers[item.id] = Timer(const Duration(seconds: 6), () {
      store.setTyping(false);
      _typingTimers.remove(item.id);
    });
  }

  /// 群解散事件（P4-12）：内核已清理群与密钥，这里只移除本机会话与缓存。
  void _onGroupDissolved(Map<String, dynamic> data) {
    final Object? id = data['conversation_id'];
    if (id is! String || id.isEmpty) {
      return;
    }
    _loaded.remove(id);
    _hasOlder.remove(id);
    _highlights.remove(id);
    _lastSeq.remove(id);
    _chats.remove(id)?.dispose();
    _conversations.remove(id);
    if (_selected?.id == id) {
      _push.markConversationClosed(id);
      setState(() => _selected = null);
    }
  }

  /// 文件传输进度（P2-04）：按 `msg_uuid` 找到消息并推进气泡进度条。
  void _onTransferProgress(Map<String, dynamic> data) {
    final Object? id = data['msg_uuid'];
    if (id is! String || id.isEmpty) {
      return;
    }
    final Object? done = data['done'];
    final Object? total = data['total'];
    final int doneBytes = done is num ? done.toInt() : 0;
    final int totalBytes = total is num ? total.toInt() : 0;
    _chatWithMessage(id)?.setTransferProgress(id, doneBytes, totalBytes);
    // 接收端文件落盘后内核只补写消息附件路径，事件不带 path：
    // 这里补一次拉取，否则图片没有缩略图、音视频点击时路径为空。
    if (totalBytes > 0 && doneBytes >= totalBytes) {
      unawaited(_refreshInboundAttachment(id));
    }
  }

  /// 传输完成后从内核重新读取消息，把落盘路径合入本地气泡。
  Future<void> _refreshInboundAttachment(String msgUuid) async {
    if (!_attachmentRefreshPending.add(msgUuid)) {
      return;
    }
    try {
      final CoreSession? session = widget.session;
      if (session == null) {
        _attachmentRefreshPending.remove(msgUuid);
        return;
      }
      // 首条进度可能早于 message.new，等气泡入列后再查。
      ChatStore? store = _chatWithMessage(msgUuid);
      for (int attempt = 0; store == null && attempt < 4; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!mounted) {
          return;
        }
        store = _chatWithMessage(msgUuid);
      }
      if (store == null) {
        // 气泡还没入列：放开标记，后续进度事件可再试一次。
        _attachmentRefreshPending.remove(msgUuid);
        return;
      }
      final ConversationItem? item = _conversations.byId(store.conversationId);
      if (item == null) {
        _attachmentRefreshPending.remove(msgUuid);
        return;
      }
      final ChatMessage? local = store.byId(msgUuid);
      final List<ChatMessage> refreshed = local != null && local.seq > 0
          ? (await session.since(item, afterSeq: local.seq - 1)).messages
          : await session.history(item, limit: 20);
      bool merged = false;
      for (final ChatMessage message in refreshed) {
        if (message.id == msgUuid &&
            message.attachment?.path.isNotEmpty == true) {
          store.merge(message);
          merged = true;
          break;
        }
      }
      if (!merged) {
        // 内核回包滞后：留待下一次进度事件重试。
        _attachmentRefreshPending.remove(msgUuid);
      }
    } catch (error, stack) {
      // 拉取失败保留重试机会：下一次传输进度仍会再次触发。
      _logDegradation('补齐附件路径 $msgUuid', error, stack);
      _attachmentRefreshPending.remove(msgUuid);
    }
  }

  ChatStore? _chatWithMessage(String msgUuid) {
    for (final ChatStore chat in _chats.values) {
      if (chat.byId(msgUuid) != null) {
        return chat;
      }
    }
    return null;
  }

  ChatStore _chatFor(ConversationItem item) {
    return _chats.putIfAbsent(
      item.id,
      () => ChatStore(
        conversationId: item.id,
        isGroup: item.isGroup,
        sender: widget.session?.senderFor(item),
      ),
    );
  }

  void _open(
    ConversationItem item,
    bool desktop, {
    bool inlineInContacts = false,
  }) {
    // 打开会话后同一会话的入站消息不再重复弹通知。
    unawaited(_push.markConversationOpen(item.id));
    _conversations.markRead(item.id);
    unawaited(_ensureLoaded(item).then((_) => _markReadOnCore(item)));
    if (desktop) {
      setState(() {
        _selected = item;
        _profileOpenOverride = null;
        if (inlineInContacts) {
          // 从联系人列表进入时记住来源，聊天页左上角的返回箭头据此回到列表。
          if (_contactsPane != '会话') {
            _contactsChatReturnPane = _contactsPane;
            _contactsChatReturnData = _contactsPaneData;
          }
          _contactsPane = '会话';
          _contactsPaneData = item;
        }
      });
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          body: SafeArea(
            child: ChatPage(
              conversation: item,
              store: _chatFor(item),
              presence: _presence,
              displayName: _peerDisplayFor(item)?.displayName,
              remark: _peerDisplayFor(item)?.remark ?? '',
              onSetRemark: item.isGroup || item.peer.isEmpty
                  ? null
                  : (String value) => unawaited(_setPeerRemark(item, value)),
              onBack: () {
                _push.markConversationClosed(item.id);
                Navigator.of(context).pop();
              },
              onSent: (String text) => _conversations.touch(item.id, text),
              onOpenGroupInfo: item.isGroup ? () => _openGroupInfo(item) : null,
              onStartCall: (bool video) => _startCall(item, video),
              onStartRemote: item.isGroup ? null : () => _startRemote(item),
              onPickFile: widget.session?.pickFile,
              onPickImage: widget.session?.pickImage,
              onPickMedia: widget.session?.pickMedia,
              voiceRecorder: widget.session?.voiceRecorder,
              // Web 端内核在网关进程内，媒体走鉴权 inline 链接在线播放。
              mediaSourceUri: kIsWeb ? widget.session?.mediaSourceUri : null,
              onDeleteMessage: widget.session == null
                  ? null
                  : (String msgUuid) =>
                        widget.session!.deleteMessage(item.id, msgUuid),
              onForwardMessage: _forwardMessage,
              onRecallMessage: (ChatMessage message) =>
                  _recallMessage(item, message),
              onEditMessage: widget.session == null
                  ? null
                  : (String uuid, String text) =>
                        widget.session!.editMessage(item.id, uuid, text),
              onTypingChanged:
                  item.isGroup || item.peer.isEmpty || widget.session == null
                  ? null
                  : (bool typing) =>
                        unawaited(widget.session!.setTyping(item.peer, typing)),
              mentionCandidates: _mentionsFor(item),
              mentionController: _mentionControllerFor(item),
              onClearHistory: () => _clearHistory(item),
              onLoadOlder: () => _loadOlder(item),
              highlightMsgUuid: _highlights[item.id],
              diagnostics: _diagnostics,
              reportSink: _reportSink,
            ),
          ),
        ),
      ),
    );
  }

  /// 转发文本消息：选择目标会话后经目标会话的发送通道发送（P6-12）。
  ///
  /// 返回 true 表示已发起转发，false 表示用户取消或没有可选会话。
  Future<bool> _forwardMessage(ChatMessage message) async {
    final List<ConversationItem> targets = _conversations.sorted
        .where((ConversationItem item) => item.id != message.conversationId)
        .toList();
    if (targets.isEmpty) {
      return false;
    }
    final ConversationItem? target =
        await showModalBottomSheet<ConversationItem>(
          context: context,
          builder: (BuildContext context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.all(NexmemMetrics.space12),
                  child: _TranslatedText('转发到'),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    itemBuilder: (BuildContext context, int index) {
                      final ConversationItem item = targets[index];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Icon(
                            item.isGroup
                                ? Icons.groups_outlined
                                : Icons.person_outline,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: item.lastMessage.isEmpty
                            ? null
                            : Text(
                                item.lastMessage,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => Navigator.of(context).pop(item),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
    if (target == null || !mounted) {
      return false;
    }
    final String selfName = context.t('我');
    final String failureTemplate = context.t('转发失败：{0}');
    try {
      await _chatFor(target).send(message.text, senderName: selfName);
    } on Object catch (error) {
      _showMessage(failureTemplate.replaceFirst('{0}', '$error'));
      return false;
    }
    _conversations.touch(target.id, message.text);
    return true;
  }

  /// 撤回自己 2 分钟内的单聊消息（P6-12）；离线模式下仅由聊天页移除本机气泡。
  Future<void> _recallMessage(
    ConversationItem conversation,
    ChatMessage message,
  ) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    await session.recallMessage(conversation.id, message.id);
  }

  /// 下载群文件（A-02）：气泡提供入口，壳层解析落盘目录后调用内核
  /// `file.downloadGroup`，返回绝对路径供气泡提示用户。
  Future<String?> _downloadGroupFile(
    ConversationItem conversation,
    ChatMessage message,
  ) async {
    final CoreSession? session = widget.session;
    final ChatAttachment? attachment = message.attachment;
    if (session == null ||
        attachment == null ||
        !attachment.canDownloadGroupFile) {
      return null;
    }
    // 异步前取本地化器，避免在 await 之后使用 BuildContext。
    final l10n = context.l10n;
    try {
      final String target = await session.groupFileDownloadPath(
        attachment.name,
      );
      final GroupFileDownload result = await session.downloadGroupFile(
        conversationId: conversation.id,
        attachment: attachment,
        destPath: target,
      );
      // Web 端文件落在网关服务端，浏览器需经鉴权 /download 取回本地。
      final Future<void> Function(String, String)? toBrowser =
          session.downloadToBrowser;
      if (toBrowser != null) {
        await toBrowser(result.path, attachment.name);
        return attachment.name;
      }
      // 群文件落盘后把本地路径合入气泡：图片/音视频随即获得缩略图与播放器。
      _chatFor(conversation).merge(
        message.copyWith(attachment: attachment.copyWith(path: result.path)),
      );
      return result.path;
    } on Object catch (error) {
      _showMessage(l10n.t('群文件下载失败：{0}', [error]));
      return null;
    }
  }

  /// 保存聊天附件到本机：群文件先经内核解密下载，其余直接用已落盘路径。
  Future<String?> _saveChatAttachment(
    ConversationItem conversation,
    ChatMessage message,
  ) async {
    final CoreSession? session = widget.session;
    final ChatAttachment? attachment = message.attachment;
    if (session == null || attachment == null) {
      return null;
    }
    if (conversation.isGroup && attachment.canDownloadGroupFile) {
      return _downloadGroupFile(conversation, message);
    }
    if (attachment.path.trim().isEmpty || session.saveChatFile == null) {
      return null;
    }
    return session.saveChatFile!(attachment.path, attachment.name);
  }

  /// 清空聊天记录（P6-13）：先让内核清空本机历史，成功后再同步列表摘要；
  /// 消息缓存由聊天页在成功后清空。内核失败时抛出，由聊天页提示且不清列表。
  Future<void> _clearHistory(ConversationItem item) async {
    final CoreSession? session = widget.session;
    if (session != null) {
      await session.conversations.clear(item.id);
    }
    _conversations.clearMessages(item.id);
  }

  /// 把已读位置推给内核；失败不影响本地 UI（搜索/已读为尽力而为）。
  void _markReadOnCore(ConversationItem item) {
    final List<ChatMessage> messages = _chatFor(item).messages;
    final String upToId = messages.isEmpty ? '' : messages.last.id;
    unawaited(
      _readMarker
          .markRead(conversationId: item.id, upToId: upToId)
          .catchError((Object _) {}),
    );
  }

  /// 会话删除（P6-07）：本地条目已由会话页移除，这里同步内核；
  /// 失败时恢复本地条目并提示，避免列表与内核长期不一致。
  Future<void> _deleteConversation(ConversationItem item) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    try {
      await session.conversations.delete(item.id);
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      _conversations.upsert(item);
      _showMessage(
        error.message.isEmpty
            ? context.t('删除会话失败（{0}）', [error.code])
            : error.message,
      );
      return;
    } catch (error, stack) {
      _logDegradation('删除会话', error, stack);
      if (mounted) {
        _conversations.upsert(item);
      }
      return;
    }
    _loaded.remove(item.id);
    _hasOlder.remove(item.id);
    _highlights.remove(item.id);
    _lastSeq.remove(item.id);
    _chats.remove(item.id)?.dispose();
    if (_selected?.id == item.id) {
      _push.markConversationClosed(item.id);
      setState(() => _selected = null);
    }
  }

  /// 会话置顶（P6-17）：本地已由会话页乐观更新，内核失败时回滚并提示。
  Future<void> _setConversationPinned(
    ConversationItem item,
    bool pinned,
  ) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    final String failText = context.t('置顶设置失败');
    try {
      await session.conversations.updateFlags(item.id, pinned: pinned);
    } on NexmemException catch (error) {
      _revertConversationFlags(item, failText, error);
    } catch (error, stack) {
      _logDegradation('置顶设置', error, stack);
      _revertConversationFlags(item, failText, null);
    }
  }

  /// 会话免打扰（P6-17）：未读数保留，只改变本机角标样式与提示。
  Future<void> _setConversationMuted(ConversationItem item, bool muted) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    final String failText = context.t('免打扰设置失败');
    try {
      await session.conversations.updateFlags(item.id, muted: muted);
    } on NexmemException catch (error) {
      _revertConversationFlags(item, failText, error);
    } catch (error, stack) {
      _logDegradation('免打扰设置', error, stack);
      _revertConversationFlags(item, failText, null);
    }
  }

  /// 回滚会话标记到操作前的状态，并提示失败原因。
  void _revertConversationFlags(
    ConversationItem item,
    String action,
    NexmemException? error,
  ) {
    _conversations.setPinned(item.id, item.pinned);
    _conversations.setMuted(item.id, item.muted);
    if (!mounted) {
      return;
    }
    final String detail = error == null || error.message.isEmpty
        ? ''
        : '：${error.message}';
    _showMessage('$action$detail');
  }

  /// 搜索命中：打开会话并向上翻页直到命中消息入列，再定位高亮（P6-07）。
  Future<void> _openSearchHit(SearchHit hit, bool desktop) async {
    final ConversationItem? item = _conversations.byId(hit.conversationId);
    if (item == null) {
      return;
    }
    await _ensureLoaded(item);
    await _ensureMessageLoaded(item, hit.msgUuid);
    if (!mounted) {
      return;
    }
    _highlights[item.id] = hit.msgUuid;
    _open(item, desktop);
  }

  /// 向上翻页直到目标消息入列或没有更早历史；最多回溯 10 页。
  Future<bool> _ensureMessageLoaded(
    ConversationItem item,
    String msgUuid,
  ) async {
    final ChatStore store = _chatFor(item);
    if (store.byId(msgUuid) != null) {
      return true;
    }
    for (int page = 0; page < 10; page++) {
      if (!await _loadOlder(item)) {
        break;
      }
      if (store.byId(msgUuid) != null) {
        return true;
      }
    }
    return store.byId(msgUuid) != null;
  }

  /// 在聊天头部设置单聊备注，成功后本机回填显示名与会话标题。
  Future<void> _setPeerRemark(ConversationItem item, String remark) async {
    final CoreSession? session = widget.session;
    if (session == null || item.isGroup || item.peer.isEmpty) {
      return;
    }
    final String peer = item.peer;
    final String displayName = remark.isNotEmpty
        ? remark
        : shortAccountLabel(peer);
    final String oldTitle = item.title;
    // 先更新界面，失败时回滚，保持与好友详情页一致的体验。
    _peerDisplay[peer] = (displayName: displayName, remark: remark);
    _conversations.upsert(item.copyWith(title: displayName));
    try {
      await session.contacts.setRemark(peer, remark);
      unawaited(_contactsKey.currentState?.reload());
      await _reloadPeerDisplay();
    } on NexmemException catch (error) {
      _peerDisplay[peer] = (
        displayName: oldTitle,
        remark: oldTitle == remark ? '' : oldTitle,
      );
      _conversations.upsert(item.copyWith(title: oldTitle));
      if (mounted) {
        _showMessage(error.message.isEmpty ? error.code : error.message);
      }
    }
  }

  /// 从好友资料「发消息」打开单聊：会话 ID 与内核 `dm.ConversationID` 同构。
  void _openContact(
    Contact contact,
    bool desktop, {
    bool inlineInContacts = false,
  }) {
    final String self = widget.session?.accountId ?? '';
    if (self.isEmpty || contact.peer.isEmpty) {
      _showMessage(context.t('账号未就绪，暂时无法发起聊天'));
      return;
    }
    final String id = dmConversationId(selfAccount: self, peer: contact.peer);
    final ConversationItem item =
        _conversations.byId(id) ??
        ConversationItem(
          id: id,
          title: contact.note.isEmpty ? contact.name : contact.note,
          peer: contact.peer,
        );
    _conversations.upsert(item);
    _open(item, desktop, inlineInContacts: inlineInContacts);
  }

  /// 建群成功后落一条本地会话并直接打开；后续消息由内核事件补齐摘要。
  void _createGroupConversation(
    String groupId,
    String title,
    bool desktop, {
    bool inlineInContacts = false,
  }) {
    final String id = groupConversationId(groupId);
    final ConversationItem item =
        _conversations.byId(id) ??
        ConversationItem(id: id, title: title, isGroup: true);
    _conversations.upsert(item);
    _open(item, desktop, inlineInContacts: inlineInContacts);
  }

  /// 群资料页（P4-09）：数据源为 `group.members`；
  /// 退群/解散成功后（P4-12）移除本机会话条目。
  Future<void> _openGroupInfo(ConversationItem item) async {
    final bool? removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => SafeArea(
          child: GroupInfoPage(
            groupId: groupIdOf(item.id),
            title: item.title,
            service: _groups,
            selfAccount: widget.session?.accountId ?? '',
            contacts: widget.session == null ? null : _contacts,
            onAliasChanged: (_) => unawaited(_applyGroupAlias(item.id)),
            announcementRevision: _announcementRevision,
            onAllowFriendAddChanged: (_) => _allowFriendAddRevision.value++,
            allowFriendAddRevision: _allowFriendAddRevision,
            profileRevision: _groupProfileRevision,
          ),
        ),
      ),
    );
    if (removed == true && mounted) {
      await _deleteConversation(item);
    }
  }

  /// 群备注变更后刷新会话标题（P6-27）：会话列表以群备注优先。
  Future<void> _applyGroupAlias(String conversationId) async {
    await _reloadConversations();
    if (!mounted) {
      return;
    }
    final ConversationItem? updated = _conversations.byId(conversationId);
    if (updated != null && _selected?.id == conversationId) {
      setState(() => _selected = updated);
    }
  }

  /// 群设置允许时，从聊天右侧成员面板直接向该成员发送好友申请。
  Future<void> _addGroupMemberAsFriend(String account) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      _showMessage(context.t('群聊服务尚未接入内核'));
      return;
    }
    try {
      await session.social.sendFriendRequest(account);
      if (!mounted) {
        return;
      }
      _showMessage(context.t('已发送好友申请'));
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(error.message.isEmpty ? error.code : error.message);
    }
  }

  List<Widget> _pages(bool desktop) => <Widget>[
    ChatsPage(
      key: _chatsKey,
      store: _conversations,
      loading: _loadingConversations,
      offline: _link.value == LinkStatus.offline,
      selectedId: _selected?.id,
      onOpen: (ConversationItem item) => _open(item, desktop),
      search: _search,
      onOpenHit: (SearchHit hit) => unawaited(_openSearchHit(hit, desktop)),
      contacts: widget.session == null ? null : _contacts,
      groups: widget.session == null ? null : _groups,
      onStartChat: (Contact contact) => _openContact(contact, desktop),
      onGroupCreated: (String groupId, String title) =>
          _createGroupConversation(groupId, title, desktop),
      onContactAdded: () => unawaited(_contactsKey.currentState?.reload()),
      onMarkRead: (ConversationItem item) => _markReadOnCore(item),
      onDelete: (ConversationItem item) => unawaited(_deleteConversation(item)),
      onSetPinned: _setConversationPinned,
      onSetMuted: _setConversationMuted,
    ),
    ContactsPage(
      key: _contactsKey,
      service: widget.session == null ? null : _contacts,
      groups: widget.session == null ? null : _groups,
      session: widget.session,
      presence: _presence,
      onSendMessage: (Contact contact) => _openContact(contact, desktop),
      onOpenContactChat: (Contact contact) =>
          _openContact(contact, desktop, inlineInContacts: true),
      onOpenGroup: (String groupId, String title) => _createGroupConversation(
        groupId,
        title,
        desktop,
        inlineInContacts: true,
      ),
      onOpenPane: _openContactsPane,
      onToggleFriends: () {
        // 点「好友」展开左栏分组：若右栏不是聊天/资料，则回到好友面板；
        // 已经在聊天时保持当前会话，避免误关聊天框。
        if (_contactsPane != '会话' && _contactsPane != '好友资料') {
          setState(() {
            _contactsPane = '好友';
            _contactsPaneData = null;
          });
        }
      },
      onContactsChanged: () {
        // 好友备注变更后同步回填单聊显示名与会话标题（聊天头部/列表跟随）。
        unawaited(_reloadPeerDisplay());
        if (mounted) {
          setState(() {});
        }
      },
    ),
    _buildFilePage(),
    // 「我的」只保留资料，「设置」从底部齿轮进入。
    _buildSettingsPage(desktop, profileOnly: true),
    _buildSettingsPage(desktop, profileOnly: false),
  ];

  /// 「我的」与「设置」共用同一套账号/设置服务，仅列表项范围不同。
  Widget _buildSettingsPage(bool desktop, {required bool profileOnly}) {
    return SettingsPage(
      account: widget.session?.account,
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
      webOnlineOnly: kIsWeb,
      diagnostics: _diagnostics,
      ping: _ping,
      backup: _backup,
      storage: _storage,
      reportSink: _reportSink,
      settings: widget.session?.settings ?? const UnavailableSettingsService(),
      session: widget.session,
      coreInfo: _coreInfo,
      accountManager: widget.accountManager,
      push: _push,
      profileOnly: profileOnly,
      onOpenProfileView: () => _openProfileView(desktop),
      onOpenPane: (String label) => _openSettingsPane(label, desktop),
    );
  }

  /// 「文件」分区：有内核会话时展示共享 / 传输 / 下载；
  /// Widget 测试等无会话场景给出明确占位，避免空屏。
  Widget _buildFilePage() {
    return _filePageCache ??= _createFilePage();
  }

  Widget _createFilePage() {
    final CoreSession? session = widget.session;
    if (session == null) {
      return Center(child: Text(context.t('内核尚未启动，文件功能暂不可用')));
    }
    return FileHubPage(
      key: const ValueKey<String>('file-hub'),
      session: session,
      mediaSourceUri: kIsWeb ? session.mediaSourceUri : null,
    );
  }

  /// 桌面 / Web 快捷键（ui-spec.md §9）。
  Map<ShortcutActivator, VoidCallback>
  get _shortcuts => <ShortcutActivator, VoidCallback>{
    const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focusSearch,
    const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _focusSearch,
    const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newChat,
    const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _newChat,
    const SingleActivator(LogicalKeyboardKey.escape): _escape,
  };

  /// `Ctrl/Cmd + F`：切到消息并打开搜索页。
  void _focusSearch() {
    if (_section != 0) {
      setState(() => _section = 0);
    }
    unawaited(_chatsKey.currentState?.openSearch());
  }

  /// `Ctrl/Cmd + N`：切到消息并打开发起聊天面板。
  void _newChat() {
    if (_section != 0) {
      setState(() => _section = 0);
    }
    unawaited(_chatsKey.currentState?.startChat());
  }

  /// `Esc`：优先关闭上层页面；桌面再退回会话列表空态，移动端回到消息 Tab。
  void _escape() {
    if (Navigator.of(context).canPop()) {
      unawaited(Navigator.of(context).maybePop());
      return;
    }
    if (_selected != null) {
      _push.markConversationClosed(_selected!.id);
      setState(() => _selected = null);
      return;
    }
    if (_section != _sectionChats ||
        _settingsPane != null ||
        _contactsPane != '好友') {
      setState(() {
        _section = _sectionChats;
        _settingsPane = null;
        _contactsPane = '好友';
        _contactsPaneData = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LinkStatus>(
      valueListenable: _link,
      builder: (BuildContext context, LinkStatus status, Widget? _) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool desktop =
                constraints.maxWidth >= NexmemMetrics.desktopBreakpoint;
            _desktopLayout = desktop;
            _wideLayout = constraints.maxWidth >= 1080;
            _registerOverlays(desktop: desktop);
            return CallbackShortcuts(
              bindings: _shortcuts,
              child: Focus(
                autofocus: true,
                child: Scaffold(
                  body: SafeArea(
                    child: Column(
                      children: <Widget>[
                        ConnectionStatusBar(status: status),
                        // 桌面仍是布局内通知条；移动端由根浮层绘制，
                        // 这样 push 出的聊天页也能看到来电。
                        if (desktop && _callInfo != null)
                          CallNoticeBar(
                            info: _callInfo!,
                            peerName: _callDisplayName(),
                            ringing: !_callPageOpen,
                            onOpen: _openCallPage,
                            onReject: _callInfo!.state == CallState.incoming
                                ? () => unawaited(_call?.reject())
                                : null,
                          ),
                        if (_remoteHostInfo != null &&
                            _remoteHostInfo!.isHost &&
                            !_remoteHostInfo!.isIncoming &&
                            !_remoteHostInfo!.isTerminal)
                          RemoteHostBanner(
                            info: _remoteHostInfo!,
                            onPause: () => unawaited(_remoteHost?.pause()),
                            onResume: () => unawaited(_remoteHost?.resume()),
                            onStop: () => unawaited(_remoteHost?.end()),
                          ),
                        Expanded(
                          child: desktop ? _buildDesktop() : _buildMobile(),
                        ),
                      ],
                    ),
                  ),
                  bottomNavigationBar: desktop ? null : _buildBottomTabs(),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 登记壳层浮层到根导航之上。
  ///
  /// 移动端聊天页是 `Navigator.push` 出来的独立路由，若浮层留在壳层 Stack
  /// 里会被整页盖住：来电条看不到、点语音/视频也没法展示通话页。
  void _registerOverlays({required bool desktop}) {
    final List<WidgetBuilder> layers = <WidgetBuilder>[
      if (!desktop && _callInfo != null)
        (BuildContext context) => Positioned(
          top: MediaQuery.paddingOf(context).top + 26,
          left: 0,
          right: 0,
          child: CallNoticeBar(
            info: _callInfo!,
            peerName: _callDisplayName(),
            ringing: !_callPageOpen,
            onOpen: _openCallPage,
            onReject: _callInfo!.state == CallState.incoming
                ? () => unawaited(_call?.reject())
                : null,
          ),
        ),
      if (_callInfo != null && _callPageOpen)
        (BuildContext context) => _buildCallOverlay(),
      if ((_remoteHostInfo?.isIncoming ?? false) ||
          (_activeRemotePeer != null &&
              _remotePeerInfos[_activeRemotePeer] != null))
        (BuildContext context) => _buildRemoteOverlay(),
      if (_webNoticeOpen)
        (BuildContext context) => Positioned(
          top: MediaQuery.paddingOf(context).top + 36,
          right: NexmemMetrics.space12,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: WebOnlineNoticeBanner(onDismiss: _dismissWebNotice),
            ),
          ),
        ),
      (BuildContext context) => AppToastOverlay(
        controller: _toasts,
        top:
            MediaQuery.paddingOf(context).top +
            (_webNoticeOpen ? 96 : (_callInfo != null ? 80 : 36)),
      ),
    ];
    // 通知监听器在浮层宿主里；build 中直接 notify 会触发
    // 「setState()/markNeedsBuild() called during build」，统一延到帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.overlay.setLayers(this, layers);
      }
    });
  }

  /// 点击状态栏下方的通话通知条：展开全屏通话页。
  void _openCallPage() {
    if (_callInfo == null) {
      return;
    }
    setState(() => _callPageOpen = true);
  }

  /// 全屏通话页（P6-28）。结束态由监听器延时收起，这里只负责渲染。
  Widget _buildCallOverlay() {
    final CallService call = _call!;
    final CallInfo info = _callInfo!;
    return CallPage(
      info: info,
      peerName: _callDisplayName(),
      onAccept: () => unawaited(call.answer()),
      onReject: () => unawaited(call.reject()),
      onHangup: () => unawaited(call.endCall()),
      onToggleMute: () => unawaited(call.setMuted(!info.muted)),
      videoViewBuilder: (String peer, {bool local = false}) => CallVideoView(
        renderer: local
            ? call.localRendererFor(peer)
            : call.remoteRendererFor(peer),
        mirror: local,
      ),
      cameraEnabled: _callCameraEnabled,
      onToggleCamera: info.video
          ? () {
              setState(() => _callCameraEnabled = !_callCameraEnabled);
              unawaited(call.setVideoEnabled(_callCameraEnabled));
            }
          : null,
      onSwitchCamera: info.video ? () => unawaited(call.switchCamera()) : null,
    );
  }

  /// 远控叠层：被控端只弹授权框（其余状态由顶部 banner 提示），
  /// 控制端展示全屏远控页；多台设备时顶栏可切换会话。
  Widget _buildRemoteOverlay() {
    final RemoteInfo? hostInfo = _remoteHostInfo;
    if (hostInfo != null && hostInfo.isIncoming) {
      final RemoteControlService? host = _remoteHost;
      if (host == null) {
        return const SizedBox.shrink();
      }
      return Material(
        color: Colors.black54,
        child: Center(
          child: RemoteIncomingDialog(
            info: hostInfo,
            onAccept: (RemotePermissions permissions) =>
                unawaited(host.accept(permissions: permissions)),
            onReject: () => unawaited(host.reject()),
          ),
        ),
      );
    }
    final String? peer = _activeRemotePeer;
    final RemoteInfo? info = peer == null ? null : _remotePeerInfos[peer];
    final RemoteControlService? remote = peer == null
        ? null
        : _remotePeers[peer];
    if (info == null || remote == null) {
      return const SizedBox.shrink();
    }
    final List<RemoteSessionTab> sessions = <RemoteSessionTab>[
      for (final MapEntry<String, RemoteInfo> entry in _remotePeerInfos.entries)
        RemoteSessionTab(
          peer: entry.key,
          name: entry.value.peerName.isEmpty ? entry.key : entry.value.peerName,
          active: entry.key == peer,
        ),
    ];
    final RemoteGroupController? group = _remoteGroup;
    group?.sync();
    return RemoteControlPage(
      key: ValueKey<String>('remote-page-$peer'),
      info: info,
      service: remote,
      onClose: _closeRemote,
      onSendFile: _sendRemoteFile,
      onShowMessage: _showMessage,
      sessions: sessions,
      onSelectSession: _selectRemotePeer,
      groupController: group,
      onGroupChanged: () => setState(() {}),
    );
  }

  /// 收起 Web 端「仅在线接收」提示并记录到 `localStorage`。
  void _dismissWebNotice() {
    _webNotice.markSeen();
    setState(() => _webNoticeOpen = false);
  }

  Widget _buildMobile() {
    // IndexedStack 保留各 Tab 的滚动位置与输入草稿（ui-spec.md §10）。
    return IndexedStack(index: _section, children: _pages(false));
  }

  NavigationBar _buildBottomTabs() {
    return NavigationBar(
      selectedIndex: _section,
      onDestinationSelected: (int index) => setState(() => _section = index),
      destinations: <NavigationDestination>[
        for (int i = 0; i < _titles.length; i++)
          NavigationDestination(icon: Icon(_icons[i]), label: _titles[i]),
      ],
    );
  }

  Widget _buildDesktop() {
    final bool wide = _wideLayout;
    final bool files = _section == _sectionFiles;
    final List<Widget> pages = _pages(true);
    // 所有分区常驻同一个 IndexedStack：文件分区占满工作区时只把右栏收起，
    // 这样切换分区不会销毁页面 State（Tab、筛选、滚动位置都保留）。
    return Row(
      children: <Widget>[
        _buildRail(),
        const VerticalDivider(width: 1),
        Flexible(
          flex: files ? 1 : 0,
          fit: files ? FlexFit.tight : FlexFit.loose,
          child: SizedBox(
            width: files
                ? double.infinity
                : (wide
                      ? NexmemMetrics.listPaneWidthWide
                      : NexmemMetrics.listPaneWidth),
            child: IndexedStack(
              key: const ValueKey<String>('desktop-pages'),
              index: _section,
              children: pages,
            ),
          ),
        ),
        VerticalDivider(width: files ? 0 : 1),
        Flexible(
          flex: files ? 0 : 1,
          fit: files ? FlexFit.loose : FlexFit.tight,
          child: files
              ? const SizedBox.shrink()
              : (_section == _sectionProfile
                    ? _buildProfilePane()
                    : _section == _sectionSettings
                    ? _buildSettingsPane()
                    : _section == _sectionContacts
                    ? _buildContactsPane()
                    : _buildChatPane(allowProfile: wide)),
        ),
      ],
    );
  }

  Widget _buildChatPane({bool allowProfile = false}) {
    final ConversationItem? selected = _selected;
    if (selected == null) {
      return const ChatPlaceholder();
    }
    return ListenableBuilder(
      listenable: _conversations,
      builder: (BuildContext context, Widget? _) {
        final ConversationItem current =
            _conversations.byId(selected.id) ?? selected;
        return _buildChatView(current, allowProfile: allowProfile);
      },
    );
  }

  /// 聊天区统一构建：消息分区右栏与联系人分区内联聊天共用同一套回调，
  /// 避免两处入口的 @、群资料、消息操作行为不一致。
  Widget _buildChatView(
    ConversationItem current, {
    required bool allowProfile,
    VoidCallback? onBack,
  }) {
    final bool showProfile = _profileVisibleFor(current, allowProfile);
    final MentionInsertController mention = _mentionControllerFor(current);
    final ({String displayName, String remark})? peerDisplay = _peerDisplayFor(
      current,
    );
    final Widget chat = ChatPage(
      conversation: current,
      store: _chatFor(current),
      presence: _presence,
      displayName: peerDisplay?.displayName,
      remark: peerDisplay?.remark ?? '',
      onSetRemark: current.isGroup || current.peer.isEmpty
          ? null
          : (String value) => unawaited(_setPeerRemark(current, value)),
      onBack: onBack,
      onSent: (String text) => _conversations.touch(current.id, text),
      onOpenGroupInfo: current.isGroup ? () => _openGroupInfo(current) : null,
      onStartCall: (bool video) => _startCall(current, video),
      onStartRemote: current.isGroup ? null : () => _startRemote(current),
      onToggleProfile: allowProfile
          ? () => setState(() => _profileOpenOverride = !showProfile)
          : null,
      profileOpen: showProfile,
      onPickFile: widget.session?.pickFile,
      onPickImage: widget.session?.pickImage,
      onPickMedia: widget.session?.pickMedia,
      voiceRecorder: widget.session?.voiceRecorder,
      // Web 端内核在网关进程内，媒体走鉴权 inline 链接在线播放。
      mediaSourceUri: kIsWeb ? widget.session?.mediaSourceUri : null,
      onDownloadGroupFile: widget.session == null
          ? null
          : (ConversationItem conversation, ChatMessage message) =>
                _downloadGroupFile(conversation, message),
      onSaveFile: widget.session == null
          ? null
          : (ChatMessage message) => _saveChatAttachment(current, message),
      onReadFileBytes: widget.session?.readChatFileBytes == null
          ? null
          : (ChatMessage message) =>
                widget.session!.readChatFileBytes!(message.attachment!.path),
      onDeleteMessage: widget.session == null
          ? null
          : (String msgUuid) =>
                widget.session!.deleteMessage(current.id, msgUuid),
      onForwardMessage: _forwardMessage,
      onRecallMessage: (ChatMessage message) =>
          _recallMessage(current, message),
      onEditMessage: widget.session == null
          ? null
          : (String uuid, String text) =>
                widget.session!.editMessage(current.id, uuid, text),
      onTypingChanged:
          current.isGroup || current.peer.isEmpty || widget.session == null
          ? null
          : (bool typing) =>
                unawaited(widget.session!.setTyping(current.peer, typing)),
      mentionCandidates: _mentionsFor(current),
      mentionController: mention,
      onClearHistory: () => _clearHistory(current),
      onLoadOlder: () => _loadOlder(current),
      highlightMsgUuid: _highlights[current.id],
      diagnostics: _diagnostics,
      reportSink: _reportSink,
    );
    if (!showProfile) {
      return chat;
    }
    return Row(
      children: <Widget>[
        Expanded(child: chat),
        const VerticalDivider(width: 1),
        SizedBox(
          width: NexmemMetrics.profilePaneWidth,
          child: ChatProfilePanel(
            conversation: current,
            groups: _groups,
            selfAccount: widget.session?.accountId ?? '',
            displayName: peerDisplay?.displayName,
            remark: peerDisplay?.remark ?? '',
            onSetRemark: current.isGroup || current.peer.isEmpty
                ? null
                : (String value) => unawaited(_setPeerRemark(current, value)),
            onClose: () => setState(() => _profileOpenOverride = false),
            onOpenGroupInfo: current.isGroup
                ? () => _openGroupInfo(current)
                : null,
            onMentionMember: current.isGroup
                ? (MentionCandidate candidate) => mention.insert(candidate)
                : null,
            onAddFriend: current.isGroup && widget.session != null
                ? _addGroupMemberAsFriend
                : null,
            allowFriendAddRevision: _allowFriendAddRevision,
          ),
        ),
      ],
    );
  }

  /// 左栏头像作为只读资料快捷入口：桌面切到「我的」后右栏展示只读资料卡，
  /// 窄屏理论上不渲染左栏，但仍以只读全屏页兜底，避免入口失效。
  void _openProfileFromAvatar() {
    _openProfileView(_desktopLayout);
  }

  /// 账号卡片 / 左栏头像：查看只读资料，不提供编辑。
  void _openProfileView(bool desktop) {
    if (desktop) {
      setState(() {
        _section = _sectionProfile;
        _settingsPane = null;
      });
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => Scaffold(
            appBar: AppBar(title: Text(context.t('个人资料'))),
            body: ProfileViewBody(
              account: widget.session?.account,
              settings:
                  widget.session?.settings ??
                  const UnavailableSettingsService(),
            ),
          ),
        ),
      ),
    );
  }

  /// 联系人页各入口：桌面在右栏展示对应内容，手机 push 全屏页。
  void _openContactsPane(String pane, {Object? data}) {
    final bool desktop = _desktopLayout;
    if (pane == '群聊') {
      unawaited(_contactsKey.currentState?.reloadGroups());
    }
    if (desktop) {
      setState(() {
        _section = 1;
        _contactsPane = pane;
        _contactsPaneData = data;
      });
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => Scaffold(
            appBar: AppBar(title: Text(context.t(pane))),
            body: _contactsPaneBody(pane, data),
          ),
        ),
      ),
    );
  }

  /// 「联系人」右栏内容。
  Widget _buildContactsPane() =>
      _contactsPaneBody(_contactsPane, _contactsPaneData);

  Widget _contactsPaneBody(String pane, Object? data) {
    switch (pane) {
      case '会话':
        if (data is! ConversationItem) {
          return const SizedBox.shrink();
        }
        return ListenableBuilder(
          listenable: _conversations,
          builder: (BuildContext context, Widget? _) {
            final ConversationItem current =
                _conversations.byId(data.id) ?? data;
            return _buildChatView(
              current,
              allowProfile: _desktopLayout && _wideLayout,
              onBack: () => _openContactsPane(
                _contactsChatReturnPane,
                data: _contactsChatReturnData,
              ),
            );
          },
        );
      case '群聊':
        final GroupService? groups = widget.session == null ? null : _groups;
        if (groups == null) {
          return const SizedBox.shrink();
        }
        return GroupListPage(
          service: groups,
          embedded: true,
          onOpenGroup: (String groupId, String title) =>
              _createGroupConversation(
                groupId,
                title,
                _desktopLayout,
                inlineInContacts: _desktopLayout,
              ),
          onGroupCreated: (String groupId, String title) {
            unawaited(_contactsKey.currentState?.reloadGroups());
            _createGroupConversation(
              groupId,
              title,
              _desktopLayout,
              inlineInContacts: _desktopLayout,
            );
          },
        );
      case '好友资料':
        if (data is! Contact) {
          return const SizedBox.shrink();
        }
        final Contact contact = data;
        return ContactDetailPage(
          contact: contact,
          service: widget.session == null ? null : _contacts,
          embedded: true,
          onChanged: (Contact next) => _contactsKey.currentState?.apply(next),
          onDeleted: (_) => unawaited(_contactsKey.currentState?.reload()),
          onSendMessage: () => _openContact(
            contact,
            _desktopLayout,
            inlineInContacts: _desktopLayout,
          ),
          onStartRemote: contact.peer.isEmpty
              ? null
              : () => _startRemotePeer(contact.peer, contact.name),
          onOpenDevices: (String peer, String title) => _openContactsPane(
            '设备列表',
            data: <String, String>{'peer': peer, 'title': title},
          ),
        );
      case '我的设备':
      case '设备列表':
        final ContactService? contacts = widget.session == null
            ? null
            : _contacts;
        if (contacts == null) {
          return const SizedBox.shrink();
        }
        final Map<String, String> args = data is Map<String, String>
            ? data
            : <String, String>{'peer': '', 'title': context.t('我的设备')};
        return DeviceListPage(
          service: contacts,
          peer: args['peer'] ?? '',
          title: args['title'] ?? context.t('我的设备'),
          embedded: true,
        );
      case '好友':
      default:
        return FriendsPane(
          friends: _contactsKey.currentState?.friends ?? const <Contact>[],
          onOpenContact: (Contact contact) => _openContact(
            contact,
            _desktopLayout,
            inlineInContacts: _desktopLayout,
          ),
          onOpenProfile: (Contact contact) =>
              _openContactsPane('好友资料', data: contact),
          onAdd: widget.session == null
              ? null
              : () => unawaited(_contactsKey.currentState?.addFriend()),
        );
    }
  }

  /// 退出应用：先停内核再请求关闭进程；Web 端展示可重新进入的退出页。
  Future<void> _confirmExit() async {
    final bool? confirmed = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('退出应用')),
        content: Text(context.t('确定要退出奈讯联吗？本地账号数据会保留')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('shell-exit-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('确定')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.accountManager?.exitApp();
    await exitProcess();
  }

  /// 设置列表项：桌面在右栏展示对应面板，手机 push 全屏页，均不再弹框。
  void _openSettingsPane(String label, bool desktop) {
    // 资料、远程设备、账号发现、社交中心与账号安全属于「我的」，其余项属于「设置」。
    if (label == '退出应用') {
      unawaited(_confirmExit());
      return;
    }
    final int section =
        label == '个人资料' ||
            label == '远程设备' ||
            label == '账号发现' ||
            label == '设备地图' ||
            label == '社交中心' ||
            label == '账号与安全' ||
            label == '账号管理' ||
            label == '临时锁'
        ? _sectionProfile
        : _sectionSettings;
    if (desktop) {
      setState(() {
        _section = section;
        _settingsPane = label;
      });
      return;
    }
    // 远程设备页与账号发现页自带 Scaffold + AppBar，不能再套
    // SettingsPanePage，否则窄屏下会出现两行重复的标题栏。
    if (label == '远程设备') {
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                _buildRemoteDevicesPage(embedded: false),
          ),
        ),
      );
      return;
    }
    if (label == '账号发现') {
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                _buildDeviceDiscoveryPage(embedded: false),
          ),
        ),
      );
      return;
    }
    if (label == '设备地图') {
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => DeviceMapPage(
              devices: _remoteDevices.devices,
              settings:
                  widget.session?.settings ??
                  const UnavailableSettingsService(),
              embedded: false,
            ),
          ),
        ),
      );
      return;
    }
    final WidgetBuilder builder = label == '个人资料'
        ? (BuildContext context) => ProfileDetailPanel(
            account: widget.session?.account,
            settings:
                widget.session?.settings ?? const UnavailableSettingsService(),
          )
        : _settingsPaneBuilder(label);
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              SettingsPanePage(title: context.t(label), builder: builder),
        ),
      ),
    );
  }

  /// 为当前设置项生成对话框内容构建器（复用既有弹窗交互）。
  WidgetBuilder _settingsPaneBuilder(String label) => settingsPaneBuilder(
    label: label,
    backup: _backup,
    settings: widget.session?.settings ?? const UnavailableSettingsService(),
    diagnostics: _diagnostics,
    ping: _ping,
    storage: _storage,
    themeMode: widget.themeMode,
    onThemeModeChanged: widget.onThemeModeChanged,
    reportSink: _reportSink,
    coreInfo: _coreInfo,
    session: widget.session,
    accountManager: widget.accountManager,
    push: _push,
  );

  /// 「我的 → 远程设备」：纯台账管理页，只负责被控电脑/手机等设备的增删改与群控。
  Widget _buildRemoteDevicesPage({required bool embedded}) {
    final Map<String, RemoteInfo> sessions = Map<String, RemoteInfo>.from(
      _remotePeerInfos,
    );
    return RemoteDevicesPage(
      key: const ValueKey<String>('remote-devices-page'),
      directory: _remoteDevices,
      embedded: embedded,
      actions: RemoteDevicesActions(
        sessions: sessions,
        onConnect: (String peer, String name) => _startRemotePeer(
          peer,
          name,
          credential: _remoteDevices.find(peer)?.credential ?? '',
          silent: true,
        ),
        onDisconnect: (String peer) {
          // 台账里的「断开」必须真正结束会话；dismiss 只清终态 UI，
          // 不会向对端发 end，对端会一直显示「正在控制本机」。
          final RemoteControlService? remote = _remotePeers[peer];
          if (remote != null) {
            unawaited(remote.end());
          }
        },
        groupController: _remoteGroup,
        onGroupChanged: () {
          if (mounted) {
            setState(() {});
          }
        },
      ),
    );
  }

  /// 「我的 → 账号发现」：扫描、地图、自动归属地与距离都集中在这里。
  Widget _buildDeviceDiscoveryPage({required bool embedded}) {
    final CoreSession? session = widget.session;
    final bool desktop = MediaQuery.sizeOf(context).width >= 900;
    return DeviceDiscoverySheet(
      key: const ValueKey<String>('device-discovery-page'),
      directory: _remoteDevices,
      embedded: embedded,
      discover: session == null
          ? ({required int limit, required int offset}) async =>
                DeviceDiscoverPage(
                  items: const <DiscoveredDevice>[],
                  total: 0,
                  offset: offset,
                  limit: limit,
                )
          : ({required int limit, required int offset}) =>
                session.discoverDevices(limit: limit, offset: offset),
      geo: _remoteGeo,
      localLocation: _localLocation,
      onOpenMap: () => _openSettingsPane('设备地图', desktop),
      onAddFriend: (DiscoveredDevice device) async {
        final CoreSession? current = widget.session;
        if (current == null || device.accountId.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.t(
                    current == null ? '内核尚未启动，社交功能暂不可用' : '该账号暂无可用的公钥标识',
                  ),
                ),
              ),
            );
          }
          return false;
        }
        final bool? sent = await showAddFriendDialogWithPreset(
          context,
          current.contacts,
          account: device.accountId,
          alias: device.displayName,
          session: current,
        );
        return sent == true;
      },
      onAdded: () {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  /// 「我的」右栏内容：默认只读资料，点「个人资料」进入编辑面板。
  Widget _buildProfilePane() {
    final SettingsService settings =
        widget.session?.settings ?? const UnavailableSettingsService();
    if (_settingsPane == '个人资料') {
      return ProfileDetailPanel(
        account: widget.session?.account,
        settings: settings,
      );
    }
    if (_settingsPane == '远程设备') {
      return _buildRemoteDevicesPage(embedded: true);
    }
    if (_settingsPane == '账号发现') {
      return _buildDeviceDiscoveryPage(embedded: true);
    }
    if (_settingsPane == '设备地图') {
      return DeviceMapPage(
        key: const ValueKey<String>('device-map-pane'),
        devices: _remoteDevices.devices,
        settings: settings,
      );
    }
    if (_settingsPane == '社交中心') {
      // 社交中心本身就是铺满面板的 Column，直接嵌入右栏即可。
      // 不能再走 EmbeddedSettingsPane 的 dialog route：那会引入模态 barrier，
      // 让好友申请卡片看起来像浮在灰色遮罩上的独立弹窗。
      final CoreSession? session = widget.session;
      if (session == null) {
        return Center(child: Text(context.t('内核尚未启动，社交功能暂不可用')));
      }
      return SocialHubPage(
        key: const ValueKey<String>('social-hub-pane'),
        session: session,
      );
    }
    if (_settingsPane == '账号与安全') {
      return _buildEmbeddedPane(_settingsPane!, withHeader: true);
    }
    if ((_settingsPane == '账号管理' || _settingsPane == '临时锁') &&
        widget.accountManager != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader(title: context.t(_settingsPane!)),
          Expanded(
            child: AccountManagerPage(
              manager: widget.accountManager!,
              focusLock: _settingsPane == '临时锁',
            ),
          ),
        ],
      );
    }
    return ProfileViewPanel(
      account: widget.session?.account,
      settings: settings,
    );
  }

  /// 「设置」右栏内容：未选中时给出引导，选中后展示对应面板。
  Widget _buildSettingsPane() {
    final String? label = _settingsPane;
    if (label == null) {
      return Center(
        child: Text(
          context.t('从左侧选择设置项'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.55),
          ),
        ),
      );
    }
    if (label == '个人资料') {
      return ProfileDetailPanel(
        account: widget.session?.account,
        settings:
            widget.session?.settings ?? const UnavailableSettingsService(),
      );
    }
    if (label == '社交中心') {
      // 与「我的」入口保持一致：社交中心直接铺满右栏，不走嵌入式 dialog route。
      final CoreSession? session = widget.session;
      if (session == null) {
        return Center(child: Text(context.t('内核尚未启动，社交功能暂不可用')));
      }
      return SocialHubPage(
        key: const ValueKey<String>('social-hub-pane'),
        session: session,
      );
    }
    return _buildEmbeddedPane(label, withHeader: false);
  }

  /// 把以 `Dialog` 形态实现的历史面板复用为右栏内嵌内容。
  ///
  /// [withHeader] 为 true 时补一条标题栏；内容本身已经带 PaneHeader 时传 false。
  Widget _buildEmbeddedPane(String label, {required bool withHeader}) {
    final Widget pane = EmbeddedSettingsPane(
      key: ValueKey<String>('settings-pane-$label-$_settingsPaneRevision'),
      builder: _settingsPaneBuilder(label),
      onDismiss: () {
        if (mounted) {
          setState(() => _settingsPaneRevision++);
        }
      },
    );
    if (!withHeader) {
      return pane;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(title: context.t(label)),
        Expanded(child: pane),
      ],
    );
  }

  Widget _buildRail() {
    return Container(
      width: NexmemMetrics.railWidth,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[NexmemColors.railTop, NexmemColors.railBottom],
        ),
      ),
      child: Column(
        children: <Widget>[
          const SizedBox(height: NexmemMetrics.space16),
          Tooltip(
            message: context.t('个人资料'),
            child: InkWell(
              key: const ValueKey<String>('rail-avatar'),
              onTap: _openProfileFromAvatar,
              borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const SelfAvatar(radius: 19, iconSize: 20),
              ),
            ),
          ),
          const SizedBox(height: NexmemMetrics.space16),
          for (int i = 0; i < _sectionSettings; i++)
            _RailButton(
              icon: _icons[i],
              tooltip: _titles[i],
              selected: _section == i,
              onTap: () => setState(() {
                _section = i;
                if (i == _sectionProfile || i == _sectionContacts) {
                  // 重新点一级入口时回到该分区首页，避免残留旧面板。
                  if (i == _sectionProfile) _settingsPane = null;
                  if (i == _sectionContacts) {
                    _contactsPane = '好友';
                    _contactsPaneData = null;
                  }
                }
              }),
            ),
          // 设置固定贴在左栏底部，与上方一级入口分开。
          const Spacer(),
          _RailButton(
            icon: Icons.settings_outlined,
            tooltip: context.t('设置'),
            selected: _section == _sectionSettings,
            onTap: () => setState(() {
              _section = _sectionSettings;
              _settingsPane = null;
            }),
          ),
          const SizedBox(height: NexmemMetrics.space16),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
        child: Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: NexmemMetrics.space4),
          decoration: BoxDecoration(
            color: selected ? Colors.white.withValues(alpha: 0.22) : null,
            borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 23,
                color: Colors.white.withValues(alpha: selected ? 1 : 0.82),
              ),
              if (selected)
                const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SizedBox(
                    width: 3,
                    height: 20,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.all(Radius.circular(2)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 在 const 子组件树中渲染一条本地化文案（避免 const 表达式调用方法）。
class _TranslatedText extends StatelessWidget {
  const _TranslatedText(this.keyText);

  final String keyText;

  @override
  Widget build(BuildContext context) => Text(context.t(keyText));
}
