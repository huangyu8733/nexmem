import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../features/chat/chat_message.dart';
import '../features/chat/chat_page.dart';
import '../features/chat/chat_profile_panel.dart';
import '../features/chat/chat_store.dart';
import '../features/chats/chats_page.dart';
import '../features/chats/conversation.dart';
import '../features/chats/conversation_store.dart';
import '../features/chats/read_marker.dart';
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
import '../features/search/message_search.dart';
import '../features/settings/backup.dart';
import '../features/settings/diagnostics.dart';
import '../features/settings/profile_avatar.dart';
import '../features/settings/profile_panel.dart';
import '../features/settings/profile_view.dart';
import '../features/settings/report.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/settings_pane.dart';
import '../features/settings/settings_service.dart';
import '../features/settings/storage_config.dart';
import '../l10n/l10n.dart';
import '../transport/transport.dart';
import 'pane_header.dart';
import 'connection_status.dart';
import 'core_session.dart';
import 'theme.dart';
import 'web_notice.dart';
import 'web_notice_store.dart';

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
    this.session,
    this.search,
    this.readMarker,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  });

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

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 分区索引：文件入口独立成栏，位置在「我的 / 设置」之前。
  static const int _sectionChats = 0;
  static const int _sectionContacts = 1;
  static const int _sectionFiles = 2;
  static const int _sectionSettings = 3;

  List<String> get _titles => <String>[
    context.t('消息'),
    context.t('联系人'),
    context.t('文件'),
    context.t('我的'),
  ];
  static const List<IconData> _icons = <IconData>[
    Icons.chat_bubble_outline,
    Icons.people_outline,
    Icons.folder_outlined,
    Icons.person_outline,
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

  /// 会话数据由壳层持有，P1-16 传输层接通后在此写入内核推送。
  final ConversationStore _conversations = ConversationStore();

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

  /// 当前通话快照，非空时叠加全屏通话页。
  CallInfo? _callInfo;

  /// 对端显示名（来电/去电时从会话列表解析）。
  String _callPeerName = '';

  /// 本地摄像头开关状态（多人通话全局生效）。
  bool _callCameraEnabled = true;

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
      setState(() => _callInfo = info);
    });
  }

  /// 发起通话：单聊直呼对端；群聊拉取成员后对每人各建一路 Mesh 会话。
  bool _callStarting = false;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _startCall(ConversationItem item, bool video) {
    if (_callStarting) return;
    final CallService? call = _call;
    if (call == null) {
      _showMessage(context.t('通话功能暂不可用'));
      return;
    }
    setState(() {
      _callPeerName = item.title;
      _callCameraEnabled = true;
      _callStarting = true;
    });
    if (item.isGroup) {
      unawaited(_startGroupCall(call, item.id, video).whenComplete(() {
        if (mounted) setState(() => _callStarting = false);
      }));
      return;
    }
    if (item.peer.isEmpty) {
      if (mounted) setState(() => _callStarting = false);
      _showMessage(context.t('会话缺少对端账号，无法发送'));
      return;
    }
    unawaited(call.startOutgoing(item.peer, video: video).whenComplete(() {
      if (mounted) setState(() => _callStarting = false);
    }));
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
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    _loadingConversations = true;
    _initCall(session);
    _events = session.transport.events.listen(_onEvent);
    // 传输进度是全局状态：不打开文件分区也要订阅，避免下载期间切页丢进度。
    TransferStore.instance.attach(session.transport);
    // 头像：内核就绪后加载本机已保存头像，供左栏/资料卡等位置展示。
    ProfileAvatarStore.instance.attach(session.settings);
    unawaited(_boot(session));
  }

  @override
  void dispose() {
    TransferStore.instance.detach();
    unawaited(_events?.cancel());
    unawaited(_callChanges?.cancel());
    unawaited(_call?.dispose());
    for (final Timer timer in _typingTimers.values) {
      timer.cancel();
    }
    for (final ChatStore chat in _chats.values) {
      chat.dispose();
    }
    for (final MentionInsertController controller in _mentionControllers.values) {
      controller.dispose();
    }
    _conversations.dispose();
    _link.dispose();
    _announcementRevision.dispose();
    _allowFriendAddRevision.dispose();
    super.dispose();
  }

  /// 读取账号并拉取会话首页；连接未就绪时短暂重试，最终失败则状态条显示离线。
  Future<void> _boot(CoreSession session) async {
    try {
      for (int attempt = 0; attempt < 3 && mounted; attempt++) {
        try {
          await session.bootstrap();
          // 头像缓存初始化早于 core.start，彼时 settings.get 会失败；
          // 内核就绪后必须重新读取一次，否则左栏/「我的」页一直显示占位图标。
          unawaited(ProfileAvatarStore.instance.reload());
          await _reloadConversations();
          if (mounted) {
            _link.value = LinkStatus.online;
          }
          // 版本协商（P6-29）：失败不影响上线，关于页按未知处理。
          unawaited(_loadCoreInfo(session));
          return;
        } on NexmemException catch (error) {
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
            .map((GroupMember m) => MentionCandidate(
                  account: m.account,
                  name: m.label,
                ))
            .toList(growable: false);
      } catch (error, stack) {
        _logDegradation('加载 @ 候选成员 ${item.id}', error, stack);
      }
    }
  }

  /// 会话的 @ 候选成员（七-1）；单聊返回空列表。
  List<MentionCandidate> _mentionsFor(ConversationItem item) =>
      item.isGroup ? (_mentionCandidates[item.id] ?? const <MentionCandidate>[]) : const <MentionCandidate>[];

  /// 每个会话独立的 @ 插入通道，供右侧群成员面板写、聊天输入框读。
  MentionInsertController _mentionControllerFor(ConversationItem item) =>
      _mentionControllers.putIfAbsent(
        item.id,
        MentionInsertController.new,
      );

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
    final CallService? call = _call;
    final Object? peer = data['peer'];
    final Object? payload = data['payload_b64'];
    if (call == null || peer is! String || payload is! String) {
      return;
    }
    final String name = _conversations.byId(peer)?.title ?? '';
    if (name.isNotEmpty) {
      setState(() => _callPeerName = name);
    }
    unawaited(call.handleSignal(peer, payload));
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

  /// 新消息：刷新会话摘要；已打开的会话按 seq 增量补齐（P6-31）。
  Future<void> _onMessageNew(Map<String, dynamic> data) async {
    final Object? id = data['conversation_id'];
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
    final ChatStore? store = _chatWithMessage(id);
    store?.setTransferProgress(
      id,
      done is num ? done.toInt() : 0,
      total is num ? total.toInt() : 0,
    );
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
              onBack: () => Navigator.of(context).pop(),
              onSent: (String text) => _conversations.touch(item.id, text),
              onOpenGroupInfo: item.isGroup ? () => _openGroupInfo(item) : null,
              onStartCall: (bool video) => _startCall(item, video),
              onPickFile: widget.session?.pickFile,
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
              onTypingChanged: item.isGroup || item.peer.isEmpty ||
                      widget.session == null
                  ? null
                  : (bool typing) => unawaited(
                        widget.session!.setTyping(item.peer, typing),
                      ),
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
    await _chatFor(target).send(message.text, senderName: context.t('我'));
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message.isEmpty ? context.t('删除会话失败（{0}）', [error.code]) : error.message,
          ),
        ),
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$action$detail')));
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

  /// 从好友资料「发消息」打开单聊：会话 ID 与内核 `dm.ConversationID` 同构。
  void _openContact(
    Contact contact,
    bool desktop, {
    bool inlineInContacts = false,
  }) {
    final String self = widget.session?.accountId ?? '';
    if (self.isEmpty || contact.peer.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.t('账号未就绪，暂时无法发起聊天'))));
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
            onAllowFriendAddChanged: (_) =>
                _allowFriendAddRevision.value++,
            allowFriendAddRevision: _allowFriendAddRevision,
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
      onSendMessage: (Contact contact) => _openContact(contact, desktop),
      onOpenContactChat: (Contact contact) =>
          _openContact(contact, desktop, inlineInContacts: true),
      onOpenGroup: (String groupId, String title) =>
          _createGroupConversation(groupId, title, desktop),
      onOpenPane: _openContactsPane,
      onContactsChanged: () {
        if (mounted) {
          setState(() {});
        }
      },
    ),
    _buildFilePage(),
    SettingsPage(
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
      onOpenProfileView: () => _openProfileView(desktop),
      onOpenPane: (String label) => _openSettingsPane(label, desktop),
    ),
  ];

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
            return CallbackShortcuts(
              bindings: _shortcuts,
              child: Focus(
                autofocus: true,
                child: Stack(
                  children: <Widget>[
                    Scaffold(
                      body: SafeArea(
                        child: Column(
                          children: <Widget>[
                            ConnectionStatusBar(status: status),
                            if (_webNoticeOpen)
                              WebOnlineNoticeBanner(
                                onDismiss: _dismissWebNotice,
                              ),
                            Expanded(
                              child: desktop ? _buildDesktop() : _buildMobile(),
                            ),
                          ],
                        ),
                      ),
                      bottomNavigationBar:
                          desktop ? null : _buildBottomTabs(),
                    ),
                    if (_callInfo != null) _buildCallOverlay(),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 全屏通话页（P6-28）。处于 ended 状态时立即收起，不显示按钮。
  Widget _buildCallOverlay() {
    final CallService call = _call!;
    final CallInfo info = _callInfo!;
    if (info.state == CallState.ended) {
      // 结束后下一帧收起叠层，避免用户在动画中误触。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _callInfo = null);
        }
      });
    }
    return CallPage(
      info: info,
      peerName: _callPeerName,
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
              : (_section == _sectionSettings
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
    final Widget chat = ChatPage(
      conversation: current,
      store: _chatFor(current),
      onBack: onBack,
      onSent: (String text) => _conversations.touch(current.id, text),
      onOpenGroupInfo: current.isGroup
          ? () => _openGroupInfo(current)
          : null,
      onStartCall: (bool video) => _startCall(current, video),
      onToggleProfile: allowProfile
          ? () => setState(() => _profileOpenOverride = !showProfile)
          : null,
      profileOpen: showProfile,
      onPickFile: widget.session?.pickFile,
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
      onTypingChanged: current.isGroup || current.peer.isEmpty ||
              widget.session == null
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
    _openProfileView(
      _desktopLayout,
    );
  }

  /// 账号卡片 / 左栏头像：查看只读资料，不提供编辑。
  void _openProfileView(bool desktop) {
    if (desktop) {
      setState(() {
        _section = _sectionSettings;
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
                  widget.session?.settings ?? const UnavailableSettingsService(),
            ),
          ),
        ),
      ),
    );
  }

  /// 联系人页各入口：桌面在右栏展示对应内容，手机 push 全屏页。
  void _openContactsPane(String pane, {Object? data}) {
    final bool desktop =
        _desktopLayout;
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
          onGroupCreated: (String groupId, String title) =>
              _createGroupConversation(
            groupId,
            title,
            _desktopLayout,
            inlineInContacts: _desktopLayout,
          ),
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
          onChanged: (Contact next) =>
              _contactsKey.currentState?.apply(next),
          onDeleted: (_) => unawaited(_contactsKey.currentState?.reload()),
          onSendMessage: () => _openContact(
            contact,
            _desktopLayout,
            inlineInContacts: _desktopLayout,
          ),
          onOpenDevices: (String peer, String title) => _openContactsPane(
            '设备列表',
            data: <String, String>{'peer': peer, 'title': title},
          ),
        );
      case '我的设备':
      case '设备列表':
        final ContactService? contacts =
            widget.session == null ? null : _contacts;
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

  /// 设置列表项：桌面在右栏展示对应面板，手机 push 全屏页，均不再弹框。
  void _openSettingsPane(String label, bool desktop) {
    if (desktop) {
      setState(() {
        _section = _sectionSettings;
        _settingsPane = label;
      });
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => SettingsPanePage(
            title: context.t(label),
            builder: _settingsPaneBuilder(label),
          ),
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
      );

  /// 「我的」右栏内容：null 只读资料、个人资料编辑、其它设置面板。
  Widget _buildSettingsPane() {
    final String? label = _settingsPane;
    if (label == null) {
      return ProfileViewPanel(
        account: widget.session?.account,
        settings:
            widget.session?.settings ?? const UnavailableSettingsService(),
      );
    }
    if (label == '个人资料') {
      return ProfileDetailPanel(
        account: widget.session?.account,
        settings:
            widget.session?.settings ?? const UnavailableSettingsService(),
      );
    }
    final Widget pane = EmbeddedSettingsPane(
      key: ValueKey<String>('settings-pane-$label-$_settingsPaneRevision'),
      builder: _settingsPaneBuilder(label),
      onDismiss: () {
        if (mounted) {
          setState(() => _settingsPaneRevision++);
        }
      },
    );
    if (label == '社交中心') {
      // 内嵌版社交中心不带自己的 PaneHeader，统一由右栏/全屏页外层提供标题。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader(title: context.t(label)),
          Expanded(child: pane),
        ],
      );
    }
    return pane;
  }
  Widget _buildRail() {
    return Container(
      width: NexmemMetrics.railWidth,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            NexmemColors.railTop,
            NexmemColors.railBottom,
          ],
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
              borderRadius: BorderRadius.circular(
                NexmemMetrics.radiusListItem,
              ),
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
          for (int i = 0; i < _titles.length; i++)
            _RailButton(
              icon: _icons[i],
              tooltip: _titles[i],
              selected: _section == i,
              onTap: () => setState(() {
                    _section = i;
                    if (i == _sectionSettings || i == _sectionContacts) {
                      // 重新点一级入口时回到该分区首页，避免残留旧面板。
                      if (i == _sectionSettings) _settingsPane = null;
                      if (i == _sectionContacts) {
                        _contactsPane = '好友';
                        _contactsPaneData = null;
                      }
                    }
                  }),
            ),
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
                Positioned(
                  left: 0,
                  child: Container(
                    width: 3,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2),
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
