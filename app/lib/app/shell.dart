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
import '../features/contacts/contact_service.dart';
import '../features/contacts/contacts_page.dart';
import '../features/group/group_info_page.dart';
import '../features/group/group_service.dart';
import '../features/rtc/call_page.dart';
import '../features/rtc/call_service.dart';
import '../features/rtc/rtc_media.dart';
import '../features/search/message_search.dart';
import '../features/settings/backup.dart';
import '../features/settings/diagnostics.dart';
import '../features/settings/report.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/settings_service.dart';
import '../features/settings/storage_config.dart';
import '../transport/transport.dart';
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
  static const List<String> _titles = <String>['消息', '联系人', '我的'];
  static const List<IconData> _icons = <IconData>[
    Icons.chat_bubble_outline,
    Icons.people_outline,
    Icons.settings_outlined,
  ];

  int _section = 0;

  /// 连接状态由 P1-12 状态机的 `state.changed` 推送，导航壳先以在线占位。
  final ValueNotifier<LinkStatus> _link = ValueNotifier<LinkStatus>(
    LinkStatus.online,
  );

  /// 群公告版本号（A-03）：内核 `group.announcement` 事件到达时递增，
  /// 已打开的群资料页监听后重新拉取 `group.members` 刷新公告展示。
  /// 用全局单调计数而非按群计数——页面收到任意公告更新即 reload，成本低且避免漏刷。
  final ValueNotifier<int> _announcementRevision = ValueNotifier<int>(0);

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

  /// 桌面宽屏右侧资料面板是否展开（P6-22）。
  bool _profileOpen = false;

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

  void _initCall(CoreSession session) {
    _call = CallService(
      transport: session.transport,
      mediaFactory: () => FlutterRtcMediaEngine(),
    );
    _callChanges = _call!.changes.listen((CallInfo info) {
      if (!mounted) {
        return;
      }
      setState(() => _callInfo = info);
    });
  }

  /// 发起通话（P6-28）：从单聊会话取对端账号公钥。
  void _startCall(ConversationItem item, bool video) {
    final CallService? call = _call;
    if (call == null || item.peer.isEmpty) {
      return;
    }
    setState(() => _callPeerName = item.title);
    unawaited(call.startOutgoing(item.peer, video: video));
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
    unawaited(_boot(session));
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_callChanges?.cancel());
    unawaited(_call?.dispose());
    for (final Timer timer in _typingTimers.values) {
      timer.cancel();
    }
    for (final ChatStore chat in _chats.values) {
      chat.dispose();
    }
    _conversations.dispose();
    _link.dispose();
    _announcementRevision.dispose();
    super.dispose();
  }

  /// 读取账号并拉取会话首页；连接未就绪时短暂重试，最终失败则状态条显示离线。
  Future<void> _boot(CoreSession session) async {
    try {
      for (int attempt = 0; attempt < 3 && mounted; attempt++) {
        try {
          await session.bootstrap();
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
    }
  }

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

  void _open(ConversationItem item, bool desktop) {
    _conversations.markRead(item.id);
    unawaited(_ensureLoaded(item).then((_) => _markReadOnCore(item)));
    if (desktop) {
      setState(() => _selected = item);
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
              onStartCall:
                  item.isGroup ? null : (bool video) => _startCall(item, video),
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
                  child: Text('转发到'),
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
    await _chatFor(target).send(message.text, senderName: '我');
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
            error.message.isEmpty ? '删除会话失败（${error.code}）' : error.message,
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
    try {
      await session.conversations.updateFlags(item.id, pinned: pinned);
    } on NexmemException catch (error) {
      _revertConversationFlags(item, '置顶设置失败', error);
    } catch (error, stack) {
      _logDegradation('置顶设置', error, stack);
      _revertConversationFlags(item, '置顶设置失败', null);
    }
  }

  /// 会话免打扰（P6-17）：未读数保留，只改变本机角标样式与提示。
  Future<void> _setConversationMuted(ConversationItem item, bool muted) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    try {
      await session.conversations.updateFlags(item.id, muted: muted);
    } on NexmemException catch (error) {
      _revertConversationFlags(item, '免打扰设置失败', error);
    } catch (error, stack) {
      _logDegradation('免打扰设置', error, stack);
      _revertConversationFlags(item, '免打扰设置失败', null);
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
  void _openContact(Contact contact, bool desktop) {
    final String self = widget.session?.accountId ?? '';
    if (self.isEmpty || contact.peer.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('账号未就绪，暂时无法发起聊天')));
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
    _open(item, desktop);
  }

  /// 建群成功后落一条本地会话并直接打开；后续消息由内核事件补齐摘要。
  void _createGroupConversation(String groupId, String title, bool desktop) {
    final String id = groupConversationId(groupId);
    final ConversationItem item =
        _conversations.byId(id) ??
        ConversationItem(id: id, title: title, isGroup: true);
    _conversations.upsert(item);
    _open(item, desktop);
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

  List<Widget> _pages(bool desktop) => <Widget>[
    ChatsPage(
      key: _chatsKey,
      store: _conversations,
      loading: _loadingConversations,
      offline: _link.value == LinkStatus.offline,
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
      onOpenGroup: (String groupId, String title) =>
          _createGroupConversation(groupId, title, desktop),
    ),
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
      coreInfo: _coreInfo,
    ),
  ];

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
    if (_section != 0) {
      setState(() => _section = 0);
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
    final bool wide = MediaQuery.sizeOf(context).width >= 1080;
    return Row(
      children: <Widget>[
        _buildRail(),
        const VerticalDivider(width: 1),
        SizedBox(
          width: wide
              ? NexmemMetrics.listPaneWidthWide
              : NexmemMetrics.listPaneWidth,
          child: IndexedStack(index: _section, children: _pages(true)),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _buildChatPane(allowProfile: wide)),
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
        final Widget chat = ChatPage(
          conversation: current,
          store: _chatFor(current),
          onSent: (String text) => _conversations.touch(current.id, text),
          onOpenGroupInfo: current.isGroup
              ? () => _openGroupInfo(current)
              : null,
          onStartCall: current.isGroup
              ? null
              : (bool video) => _startCall(current, video),
          onToggleProfile: allowProfile
              ? () => setState(() => _profileOpen = !_profileOpen)
              : null,
          profileOpen: allowProfile && _profileOpen,
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
          onClearHistory: () => _clearHistory(current),
          onLoadOlder: () => _loadOlder(current),
          highlightMsgUuid: _highlights[current.id],
          diagnostics: _diagnostics,
          reportSink: _reportSink,
        );
        if (!allowProfile || !_profileOpen) {
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
                onClose: () => setState(() => _profileOpen = false),
                onOpenGroupInfo: current.isGroup
                    ? () => _openGroupInfo(current)
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRail() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: NexmemMetrics.railWidth,
      color: scheme.surface,
      child: Column(
        children: <Widget>[
          const SizedBox(height: NexmemMetrics.space16),
          CircleAvatar(
            radius: NexmemMetrics.avatarSize / 2,
            backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
            child: Icon(
              Icons.person_outline,
              size: 22,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(height: NexmemMetrics.space16),
          for (int i = 0; i < _titles.length; i++)
            _RailButton(
              icon: _icons[i],
              tooltip: _titles[i],
              selected: _section == i,
              onTap: () => setState(() => _section = i),
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = selected
        ? NexmemColors.primary
        : scheme.onSurface.withValues(alpha: 0.5);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
        child: Container(
          width: 40,
          height: 40,
          margin: const EdgeInsets.symmetric(vertical: NexmemMetrics.space4),
          decoration: BoxDecoration(
            color: selected
                ? NexmemColors.primary.withValues(alpha: 0.12)
                : null,
            borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
          ),
          child: Icon(icon, size: 22, color: color),
        ),
      ),
    );
  }
}
