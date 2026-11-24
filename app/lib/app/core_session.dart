import '../features/chat/chat_message.dart';
import '../features/chat/chat_store.dart';
import '../features/chats/conversation.dart';
import '../features/chats/conversation_service.dart';
import '../features/chats/read_marker.dart';
import '../features/contacts/contact_service.dart';
import '../features/group/group_service.dart';
import '../features/group/group_storage.dart';
import '../features/search/message_search.dart';
import '../features/settings/backup.dart';
import '../features/settings/diagnostics.dart';
import '../features/settings/push.dart';
import '../features/settings/report.dart';
import '../features/settings/settings_service.dart';
import '../features/settings/storage_config.dart';
import '../features/social/social_service.dart';
import '../transport/transport.dart';

/// 本机账号信息，对应 `account.me` 回包。
class CoreAccount {
  const CoreAccount({
    required this.accountId,
    required this.deviceId,
    this.displayName = '',
  });

  factory CoreAccount.fromJson(Map<String, dynamic> json) {
    final Object? account = json['account_id'];
    final Object? device = json['device_id'];
    if (account is! String || account.isEmpty) {
      throw const FormatException('account.me 缺少 account_id');
    }
    final Object? name = json['display_name'];
    return CoreAccount(
      accountId: account,
      deviceId: device is String ? device : '',
      displayName: name is String ? name : '',
    );
  }

  final String accountId;
  final String deviceId;
  final String displayName;
}

/// 内核版本与能力信息，对应 `core.info` 回包（P6-29 启动版本协商）。
///
/// `features` 是内核已实现方法名列表，可用于 UI 能力探测；解析时忽略
/// 非法条目，缺失字段按空值处理，避免旧内核回包导致启动失败。
class CoreInfo {
  const CoreInfo({
    this.apiVersion = '',
    this.coreVersion = '',
    this.features = const <String>[],
  });

  factory CoreInfo.fromJson(Map<String, dynamic> json) {
    final Object? api = json['api_version'];
    final Object? core = json['core_version'];
    final Object? rawFeatures = json['features'];
    final List<String> features = rawFeatures is List
        ? rawFeatures.whereType<String>().toList(growable: false)
        : const <String>[];
    return CoreInfo(
      apiVersion: api is String ? api : '',
      coreVersion: core is String ? core : '',
      features: features,
    );
  }

  /// 客户端契约版本（pubspec/UI 侧），与内核 [apiVersion] 比较做协商。
  static const String clientApiVersion = '1.0.0';

  /// API 主版本是否与客户端一致（按 `.` 前的数字段比较）。
  bool get apiMajorCompatible =>
      _major(apiVersion) == _major(clientApiVersion);

  static String _major(String version) {
    final List<String> parts = version.split('.');
    return parts.isEmpty ? '' : parts.first;
  }

  /// 内核是否实现了指定契约方法。
  bool supports(String method) => features.contains(method);

  final String apiVersion;
  final String coreVersion;
  final List<String> features;
}

/// 二维码加好友名片（P6-39）：内核 `account.qrPayload` 的回包。
class QrPayload {
  const QrPayload({
    required this.payload,
    required this.accountId,
    required this.deviceId,
  });

  factory QrPayload.fromJson(Map<String, dynamic> json) {
    final Object? payload = json['payload'];
    if (payload is! String || payload.isEmpty) {
      throw const FormatException('account.qrPayload 缺少 payload');
    }
    final Object? account = json['account_id'];
    final Object? device = json['device_id'];
    return QrPayload(
      payload: payload,
      accountId: account is String ? account : '',
      deviceId: device is String ? device : '',
    );
  }

  /// 二维码文本，形如 `nexmem://add/<base64url>`。
  final String payload;
  final String accountId;
  final String deviceId;
}

/// 二维码名片解析结果（P6-39）：内核 `account.qrParse` 验签后的回包。
class QrCard {
  const QrCard({
    required this.accountId,
    required this.deviceId,
    required this.displayName,
  });

  factory QrCard.fromJson(Map<String, dynamic> json) {
    final Object? account = json['account_id'];
    if (account is! String || account.isEmpty) {
      throw const FormatException('account.qrParse 缺少 account_id');
    }
    final Object? device = json['device_id'];
    final Object? name = json['display_name'];
    return QrCard(
      accountId: account,
      deviceId: device is String ? device : '',
      displayName: name is String ? name : '',
    );
  }

  final String accountId;
  final String deviceId;
  final String displayName;
}

/// 本地地址簿条目（三种发现源之一：手动/二维码导入的对端地址）。
class PeerEntry {
  const PeerEntry({
    required this.accountId,
    required this.peerId,
    required this.addrs,
    this.label = '',
    this.updatedAt = 0,
  });

  factory PeerEntry.fromJson(Map<String, dynamic> json) {
    final Object? account = json['account_id'];
    final Object? peer = json['peer_id'];
    final Object? rawAddrs = json['addrs'];
    final List<String> addrs = rawAddrs is List
        ? rawAddrs.whereType<String>().toList(growable: false)
        : <String>[];
    return PeerEntry(
      accountId: account is String ? account : '',
      peerId: peer is String ? peer : '',
      addrs: addrs,
      label: json['label'] is String ? json['label'] as String : '',
      updatedAt: json['updated_at'] is int ? json['updated_at'] as int : 0,
    );
  }

  final String accountId;
  final String peerId;
  final List<String> addrs;
  final String label;
  final int updatedAt;
}

/// 一页会话历史：本页消息（按内核倒序回包顺序）与是否还有更早的消息。
class HistoryPage {
  const HistoryPage({required this.messages, required this.hasMore});

  final List<ChatMessage> messages;
  final bool hasMore;
}

/// `msg.listSince` 的增量结果：新消息与拉取后的最大 seq（P6-31）。
class SincePage {
  const SincePage({required this.messages, required this.lastSeq});

  final List<ChatMessage> messages;

  /// 下一轮的 `after_seq` 游标；无新消息时等于传入的基准值。
  final int lastSeq;
}

/// 内核 `msg.listSince` 单次返回上限（与 core/internal/msg/gateway.go 的
/// listSinceLimit 对齐）；客户端据此判断是否还有下一页。
const int sincePageSize = 200;

/// 内核会话：把统一的 [CoreTransport] 包装成 UI 需要的各类服务（P1-20）。
///
/// 只做契约调用与字段映射，不持有 UI 状态；导航壳监听 [CoreTransport.events]
/// 驱动会话列表与聊天页。Web 端由 `nexmem-webd` 启动内核，客户端仅 [bootstrap]
/// 读取账号即可；嵌入式场景可在收到 `NOT_STARTED` 时用 [startConfig] 启动。
class CoreSession {
  CoreSession(
    this.transport, {
    this.requestTimeout = const Duration(seconds: 20),
    this.startConfig,
    this.pickFile,
    this.pickDirectory,
  });

  final CoreTransport transport;
  final Duration requestTimeout;

  /// 嵌入式内核（桌面/移动）的 `core.start` 启动配置；Web 端为 null。
  final Map<String, dynamic>? startConfig;

  /// 平台文件选择器（P2-08）；为空时聊天页退回本机路径输入框。
  ///
  /// 移动端由原生通道把选中的 `content://` 复制到应用目录后回传绝对路径。
  final Future<ChatAttachment?> Function()? pickFile;

  /// 平台目录选择器（P2P 文件夹共享）；为空时分享页退回本机路径输入框。
  final Future<String?> Function()? pickDirectory;

  CoreAccount? _account;

  /// 当前账号；[bootstrap] 成功前为 null。
  CoreAccount? get account => _account;

  /// 本机账号 ID（十六进制公钥，与 `contact.list` 的 `account_pub` 同编码）；
  /// 未就绪时为空串。
  String get accountId => _account?.accountId ?? '';

  ConversationService get conversations =>
      TransportConversationService(transport);

  /// 本地删除一条消息（P6-11）：仅删本机记录，不影响对端。
  Future<void> deleteMessage(String conversationId, String msgUuid) async {
    await transport.call(
      'msg.delete',
      params: <String, dynamic>{
        'conversation_id': conversationId,
        'msg_uuid': msgUuid,
      },
      timeout: requestTimeout,
    );
  }

  /// 撤回自己 2 分钟内发出的单聊消息（P6-12）。
  ///
  /// 返回对端是否收到撤回通知；false 表示对端离线，仅本机已删除。
  Future<bool> recallMessage(String conversationId, String msgUuid) async {
    final Map<String, dynamic> data = await transport.call(
      'msg.recall',
      params: <String, dynamic>{
        'conversation_id': conversationId,
        'msg_uuid': msgUuid,
      },
      timeout: requestTimeout,
    );
    return data['delivered'] == true;
  }

  /// 编辑消息正文（七-2）：经内核 msg.edit 更新本机并尽力通知对端。
  Future<void> editMessage(
    String conversationId,
    String msgUuid,
    String text,
  ) async {
    await transport.call(
      'msg.edit',
      params: <String, dynamic>{
        'conversation_id': conversationId,
        'msg_uuid': msgUuid,
        'text': text,
      },
      timeout: requestTimeout,
    );
  }

  /// 发送单聊输入状态（七-3，瞬时、尽力而为）。peer 为对端账号 ID。
  ///
  /// typing 是尽力而为能力：对端不可达或内核未装配时静默忽略，不向上抛错，
  /// 以免打断用户输入。
  Future<void> setTyping(String peer, bool typing) async {
    try {
      await transport.call(
        'dm.setTyping',
        params: <String, dynamic>{
          'peer': peer,
          'typing': typing,
        },
        timeout: requestTimeout,
      );
    } on Object {
      // 输入状态失败无需提示用户。
    }
  }

  /// 生成当前账号的二维码加好友名片（P6-39）：返回 `payload` 可直接渲染二维码。
  Future<QrPayload> qrPayload() async {
    final Map<String, dynamic> data = await transport.call(
      'account.qrPayload',
      timeout: requestTimeout,
    );
    return QrPayload.fromJson(data);
  }

  /// 解析并验签扫描/粘贴得到的二维码名片（P6-39）。
  /// 非法或验签失败时抛 [NexmemException]（INVALID_ARG）。
  Future<QrCard> qrParse(String payload) async {
    final Map<String, dynamic> data = await transport.call(
      'account.qrParse',
      params: <String, dynamic>{'payload': payload},
      timeout: requestTimeout,
    );
    return QrCard.fromJson(data);
  }

  /// 列出本地地址簿（手动发现源）的全部记录。
  Future<List<PeerEntry>> listPeers() async {
    final Map<String, dynamic> data = await transport.call(
      'net.listPeers',
      timeout: requestTimeout,
    );
    final Object? items = data['items'];
    if (items is! List) {
      return <PeerEntry>[];
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(PeerEntry.fromJson)
        .toList(growable: false);
  }

  /// 写入本地地址簿：把账号 ID 与对端 multiaddr 关联。
  Future<void> addPeer({
    required String accountId,
    required String peerId,
    required List<String> addrs,
    String label = '',
  }) async {
    await transport.call(
      'net.addPeer',
      params: <String, dynamic>{
        'account_id': accountId,
        'peer_id': peerId,
        'addrs': addrs,
        'label': label,
      },
      timeout: requestTimeout,
    );
  }

  /// 从本地地址簿删除一条记录。
  Future<void> removePeer(String accountId) async {
    await transport.call(
      'net.removePeer',
      params: <String, dynamic>{'account_id': accountId},
      timeout: requestTimeout,
    );
  }

  /// 立即连接一个手动输入的 multiaddr，返回对端 PeerID。
  Future<String> connectAddr(String addr) async {
    final Map<String, dynamic> data = await transport.call(
      'net.connectAddr',
      params: <String, dynamic>{'addr': addr},
      timeout: requestTimeout,
    );
    return data['peer_id'] is String ? data['peer_id'] as String : '';
  }

  /// 通讯录（P2-06）：`contact.list/add/block/remark`。
  ContactService get contacts => TransportContactService(transport);

  /// QQ 式社交服务：好友申请、入群审批、通知、在线状态、动态与投票。
  SocialService get social => SocialService(transport);

  /// 群聊（P4-09）：`group.create` / `group.members`。
  GroupService get groups => TransportGroupService(transport);

  ReadMarker get readMarker => TransportReadMarker(transport);

  MessageSearchService get search => TransportMessageSearchService(transport);

  /// 加密备份（P6-05）：`backup.export` / `backup.import`。
  BackupService get backup => TransportBackupService(transport);

  /// 对象存储自检（P6-04）：`storage.test`。
  StorageTestService get storageTest => TransportStorageTestService(transport);

  /// 举报上报（P6-06）：`report.submit`。
  ReportSink get reportSink => TransportReportSink(transport);

  /// 运行诊断（P6-06）：`diag.snapshot` / `diag.export`。
  DiagnosticsService get diagnostics =>
      TransportDiagnosticsService(transport, exportPath: _diagnosticsPath);

  /// 内核连接自检（P6-34）：`core.ping`，只读探活。
  PingService get ping => TransportPingService(transport);

  /// 设备推送令牌上报（C-07）：`push.register` / `push.unregister`。
  PushService get push => TransportPushService(transport);

  /// 本机设置（P6-15）：`settings.get` / `settings.set`。
  SettingsService get settings => TransportSettingsService(transport);

  /// 诊断包落盘路径：优先写内核数据目录，未配置时交由内核进程工作目录。
  String _diagnosticsPath() {
    final String name =
        'nexmem-diagnostics-${DateTime.now().millisecondsSinceEpoch}.jsonl';
    final Object? dataDir = startConfig?['data_dir'];
    if (dataDir is String && dataDir.isNotEmpty) {
      final String sep = dataDir.contains(r'\') ? r'\' : '/';
      final String base = dataDir.endsWith('/') || dataDir.endsWith(r'\')
          ? dataDir.substring(0, dataDir.length - 1)
          : dataDir;
      return '$base$sep$name';
    }
    return name;
  }

  /// 读取账号；尚未启动且提供了启动配置时先启动内核（幂等）。
  Future<CoreAccount> bootstrap({Map<String, dynamic>? startConfig}) async {
    try {
      _account = await _loadAccount();
    } on NexmemException catch (error) {
      final Map<String, dynamic>? config = startConfig ?? this.startConfig;
      if (config == null || error.code != 'NOT_STARTED') {
        rethrow;
      }
      await transport.call(
        'core.start',
        params: <String, dynamic>{'config': config},
        timeout: requestTimeout,
      );
      _account = await _loadAccount();
    }
    return _account!;
  }

  Future<CoreAccount> _loadAccount() async {
    final Map<String, dynamic> data = await transport.call(
      'account.me',
      timeout: requestTimeout,
    );
    return CoreAccount.fromJson(data);
  }

  /// 读取内核版本与能力（P6-29）：失败返回 null，UI 只显示客户端版本。
  Future<CoreInfo?> loadInfo() async {
    try {
      final Map<String, dynamic> data = await transport.call(
        'core.info',
        timeout: requestTimeout,
      );
      return CoreInfo.fromJson(data);
    } on NexmemException {
      return null;
    }
  }

  /// 发送通道绑定到具体会话：单聊用 `dm.sendText`，群聊用 `dm.sendGroupText`。
  ChatSender senderFor(ConversationItem conversation) {
    return _SessionChatSender(this, conversation);
  }

  /// 拉取会话最近消息（倒序回包，按时间升序返回）。
  ///
  /// `beforeId` 为上一页最早一条的 `msg_uuid`，用于向上翻页加载更早历史。
  Future<List<ChatMessage>> history(
    ConversationItem conversation, {
    int limit = 50,
    String? beforeId,
  }) async {
    final HistoryPage page = await historyPage(
      conversation,
      limit: limit,
      beforeId: beforeId,
    );
    return page.messages;
  }

  /// 分页拉取会话历史（P6-07）：同时返回本页是否还有更早的消息。
  Future<HistoryPage> historyPage(
    ConversationItem conversation, {
    int limit = 50,
    String? beforeId,
  }) async {
    final String cursor = beforeId?.trim() ?? '';
    final Map<String, dynamic> data = await transport.call(
      'msg.list',
      params: <String, dynamic>{
        'conversation_id': conversation.id,
        'limit': limit,
        if (cursor.isNotEmpty) 'before_id': cursor,
      },
      timeout: requestTimeout,
    );
    return HistoryPage(
      messages: messagesFromItems(
        data['items'],
        conversationId: conversation.id,
        isGroup: conversation.isGroup,
        selfAccount: accountId,
      ),
      hasMore: data['has_more'] == true,
    );
  }

  /// 增量拉取会话新消息（P6-31，需求 §5.4「断线同步」）。
  ///
  /// 用本机 seq 游标读取，避免每条 `message.new` 都全量重拉 [history]。
  /// 内核单次最多回 [sincePageSize] 条并按 seq 升序；这里续读到空页，
  /// 但最多 [maxPages] 页防止异常回包导致无限循环。
  Future<SincePage> since(
    ConversationItem conversation, {
    required int afterSeq,
    int maxPages = 4,
  }) async {
    int cursor = afterSeq < 0 ? 0 : afterSeq;
    final List<ChatMessage> collected = <ChatMessage>[];
    final int pages = maxPages < 1 ? 1 : maxPages;
    for (int page = 0; page < pages; page++) {
      final Map<String, dynamic> data = await transport.call(
        'msg.listSince',
        params: <String, dynamic>{
          'conversation_id': conversation.id,
          'after_seq': cursor,
        },
        timeout: requestTimeout,
      );
      final Object? raw = data['items'];
      final List<ChatMessage> batch = messagesFromItems(
        raw,
        conversationId: conversation.id,
        isGroup: conversation.isGroup,
        selfAccount: accountId,
      );
      if (batch.isEmpty) {
        break;
      }
      collected.addAll(batch);
      final int last = batch.last.seq;
      if (last <= cursor) {
        // 回包 seq 未推进：避免同一页被反复消费。
        break;
      }
      cursor = last;
      if (raw is! List || raw.length < sincePageSize) {
        break;
      }
    }
    return SincePage(messages: collected, lastSeq: cursor);
  }

  /// 群盘配置状态；单聊或回包缺失时返回 [GroupStorageStatus.unknown]。
  Future<GroupStorageStatus> groupStorage(ConversationItem conversation) async {
    if (!conversation.isGroup) {
      return GroupStorageStatus.unknown;
    }
    final Map<String, dynamic> data = await transport.call(
      'group.members',
      params: <String, dynamic>{'group_id': groupIdOf(conversation.id)},
      timeout: requestTimeout,
    );
    final Object? configured = data['storage_configured'];
    if (configured is! bool) {
      return GroupStorageStatus.unknown;
    }
    return configured
        ? GroupStorageStatus.configured
        : GroupStorageStatus.unconfigured;
  }

  // ── P2P 文件共享（fs.*）──────────────────────────────────────────────

  /// 发布本机目录或文件为 P2P 共享，返回分享码。
  Future<FileShare> publishShare(String path, {String name = ''}) async {
    final Map<String, dynamic> data = await transport.call(
      'fs.publish',
      params: <String, dynamic>{'path': path, if (name.isNotEmpty) 'name': name},
      timeout: requestTimeout,
    );
    return FileShare.fromJson(data);
  }

  /// 列出本机全部共享（已发布、已下载做种、已导入）。
  Future<List<FileShare>> listShares() async {
    final Map<String, dynamic> data = await transport.call(
      'fs.list',
      timeout: requestTimeout,
    );
    final Object? items = data['items'];
    if (items is! List) {
      return <FileShare>[];
    }
    return items
        .whereType<Map>()
        .map((Map e) => FileShare.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 查看共享详情（含文件清单与分享码）。
  Future<FileShareDetail> getShare(String shareId) async {
    final Map<String, dynamic> data = await transport.call(
      'fs.get',
      params: <String, dynamic>{'share_id': shareId},
      timeout: requestTimeout,
    );
    return FileShareDetail.fromJson(data);
  }

  /// 导入他人发来的分享码，登记远端共享但不立即下载。
  Future<FileShare> importShare(String code) async {
    final Map<String, dynamic> data = await transport.call(
      'fs.import',
      params: <String, dynamic>{'code': code.trim()},
      timeout: requestTimeout,
    );
    return FileShare.fromJson(data);
  }

  /// 把共享的分享码作为聊天消息发给指定账号，对方导入后即可下载。
  Future<String> sendShare(String shareId, String peer) async {
    final Map<String, dynamic> data = await transport.call(
      'fs.send',
      params: <String, dynamic>{'share_id': shareId, 'peer': peer},
      timeout: requestTimeout,
    );
    return '${data['msg_uuid'] ?? ''}';
  }

  /// 删除本机共享记录（不删除实际文件）。
  Future<void> removeShare(String shareId) async {
    await transport.call(
      'fs.remove',
      params: <String, dynamic>{'share_id': shareId},
      timeout: requestTimeout,
    );
  }

  /// 从种子并行下载共享到本地目录；完成后本机自动做种。
  ///
  /// 大文件下载可能远超普通 RPC 超时，这里使用 10 分钟上限。
  Future<FileShare> downloadShare(
    String shareId,
    String dest, {
    int parallel = 4,
  }) async {
    final Map<String, dynamic> data = await transport.call(
      'fs.download',
      params: <String, dynamic>{
        'share_id': shareId,
        'dest': dest,
        'parallel': parallel,
      },
      timeout: const Duration(minutes: 10),
    );
    return FileShare(
      shareId: '${data['share_id'] ?? shareId}',
      name: '',
      code: '',
      kind: '${data['kind'] ?? 'downloaded'}',
      fileCount: 0,
      totalSize: 0,
      local: true,
      localRoot: data['dest'] is String ? data['dest'] as String : dest,
    );
  }

  Future<void> close() => transport.close();
}

/// 从会话 ID（`group:<base64url>`）取出契约要求的 `group_id`。
String groupIdOf(String conversationId) {
  const String prefix = 'group:';
  if (conversationId.startsWith(prefix)) {
    return conversationId.substring(prefix.length);
  }
  return conversationId;
}

/// 把 `msg.list` 的列表项映射为 [ChatMessage]，忽略非对象条目。
List<ChatMessage> messagesFromItems(
  Object? items, {
  required String conversationId,
  required bool isGroup,
  required String selfAccount,
}) {
  if (items is! List) {
    return const <ChatMessage>[];
  }
  final List<ChatMessage> out = <ChatMessage>[];
  for (final Object? item in items) {
    if (item is! Map<String, dynamic>) {
      continue;
    }
    final Object? id = item['msg_uuid'];
    if (id is! String || id.isEmpty) {
      continue;
    }
    final Object? sender = item['sender_account'];
    final String senderAccount = sender is String ? sender : '';
    final Object? at = item['sent_at'];
    final ChatAttachment? attachment = attachmentFromItem(item['attachments']);
    final Object? text = item['text'];
    final Object? seq = item['seq'];
    final Object? replyTo = item['reply_to'];
    final List<String> mentions = item['mentions'] is List
        ? (item['mentions'] as List)
            .whereType<String>()
            .toList(growable: false)
        : const <String>[];
    final Object? editedAt = item['edited_at'];
    final Object? expiresAt = item['expires_at'];
    out.add(
      ChatMessage(
        id: id,
        conversationId: conversationId,
        text: text is String && text.isNotEmpty
            ? text
            : (attachment?.name ?? ''),
        sentAt: at is num
            ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
            : DateTime.fromMillisecondsSinceEpoch(0),
        senderId: senderAccount,
        isMine:
            item['direction'] == 'out' ||
            (selfAccount.isNotEmpty && senderAccount == selfAccount),
        isGroup: isGroup,
        status: messageStatusFromState(item['state']),
        attachment: attachment,
        seq: seq is num ? seq.toInt() : 0,
        replyTo: replyTo is String ? replyTo : '',
        mentions: mentions,
        edited: item['edited'] == true,
        editedAt: editedAt is num ? editedAt.toInt() : 0,
        expiresAt: expiresAt is num ? expiresAt.toInt() : 0,
      ),
    );
  }
  return out;
}

/// 一条 P2P 文件共享的客户端模型（对应内核 `fs.list`/`fs.publish` 返回）。
class FileShare {
  const FileShare({
    required this.shareId,
    required this.name,
    required this.code,
    required this.kind,
    required this.fileCount,
    required this.totalSize,
    this.local = false,
    this.localRoot = '',
    this.createdAt = 0,
  });

  factory FileShare.fromJson(Map<String, dynamic> json) {
    return FileShare(
      shareId: '${json['share_id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      code: '${json['code'] ?? ''}',
      kind: '${json['kind'] ?? ''}',
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
      totalSize: (json['total_size'] as num?)?.toInt() ?? 0,
      local: json['local'] == true,
      localRoot: '${json['local_root'] ?? ''}',
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String shareId;
  final String name;
  final String code;
  final String kind;
  final int fileCount;
  final int totalSize;
  final bool local;
  final String localRoot;
  final int createdAt;

  bool get isPublished => kind == 'published';
  bool get isDownloaded => kind == 'downloaded';
}

/// 共享详情中的单个文件。
class FileShareEntry {
  const FileShareEntry({
    required this.path,
    required this.size,
    required this.sha256,
    required this.mime,
  });

  factory FileShareEntry.fromJson(Map<String, dynamic> json) {
    return FileShareEntry(
      path: '${json['path'] ?? ''}',
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: '${json['sha256'] ?? ''}',
      mime: '${json['mime'] ?? ''}',
    );
  }

  final String path;
  final int size;
  final String sha256;
  final String mime;
}

/// 共享详情（含文件清单）。
class FileShareDetail {
  const FileShareDetail({
    required this.share,
    required this.files,
    required this.owner,
  });

  factory FileShareDetail.fromJson(Map<String, dynamic> json) {
    final Object? rawFiles = json['files'];
    final List<FileShareEntry> files = rawFiles is List
        ? rawFiles
            .whereType<Map>()
            .map((Map e) => FileShareEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <FileShareEntry>[];
    return FileShareDetail(
      share: FileShare.fromJson(json),
      files: files,
      owner: '${json['owner'] ?? ''}',
    );
  }

  final FileShare share;
  final List<FileShareEntry> files;
  final String owner;
}

/// 解析 `msg.list` 条目的 `attachments`（取首个附件）；无附件时返回 null。
ChatAttachment? attachmentFromItem(Object? attachments) {
  if (attachments is! List || attachments.isEmpty) {
    return null;
  }
  final Object? first = attachments.first;
  if (first is! Map) {
    return null;
  }
  final Object? name = first['name'];
  final Object? size = first['size'];
  final Object? mime = first['mime'];
  final Object? path = first['path'];
  return ChatAttachment(
    name: name is String ? name : '文件',
    size: size is num ? size.toInt() : 0,
    mime: mime is String ? mime : '',
    path: path is String ? path : '',
  );
}

/// 内核 `state` 到 UI 五态的映射。
MessageStatus messageStatusFromState(Object? state) {
  switch (state) {
    case 'pending':
      return MessageStatus.sending;
    case 'acked':
      return MessageStatus.delivered;
    case 'failed':
      return MessageStatus.failed;
    case 'received':
      return MessageStatus.sent;
    case 'read':
      return MessageStatus.read;
    default:
      return MessageStatus.sent;
  }
}

class _SessionChatSender implements ChatSender {
  _SessionChatSender(this.session, this.conversation);

  final CoreSession session;
  final ConversationItem conversation;

  @override
  Future<String> sendText({
    required String conversationId,
    required String msgUuid,
    required String text,
    String? replyTo,
    List<String>? mentions,
    int ttlHours = 0,
  }) async {
    final Map<String, dynamic> data;
    final List<String> atList = mentions
            ?.where((String e) => e.trim().isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    // 定时消息：ttl_hours 随加密正文到达双方，各自本机到期销毁（七-4）。
    final int ttl = ttlHours > 0 ? ttlHours : 0;
    if (conversation.isGroup) {
      // 群聊：mentions 随 dm.sendGroupText 的 InnerMessage 加密广播与落库（七-1）。
      data = await session.transport.call(
        'dm.sendGroupText',
        params: <String, dynamic>{
          'group_id': groupIdOf(conversationId),
          'text': text,
          if (atList.isNotEmpty) 'mentions': atList,
          if (ttl > 0) 'ttl_hours': ttl,
        },
        timeout: session.requestTimeout,
      );
    } else {
      if (conversation.peer.isEmpty) {
        throw const NexmemException('INVALID_ARG', '会话缺少对端账号，无法发送');
      }
      final String quoted = replyTo?.trim() ?? '';
      data = await session.transport.call(
        'dm.sendText',
        params: <String, dynamic>{
          'peer': conversation.peer,
          'text': text,
          if (quoted.isNotEmpty) 'reply_to': quoted,
          if (atList.isNotEmpty) 'mentions': atList,
          if (ttl > 0) 'ttl_hours': ttl,
        },
        timeout: session.requestTimeout,
      );
    }
    final Object? id = data['msg_uuid'];
    return id is String ? id : msgUuid;
  }

  @override
  Future<String> editMessage({
    required String conversationId,
    required String msgUuid,
    required String text,
  }) async {
    await session.editMessage(conversationId, msgUuid, text);
    return msgUuid;
  }

  @override
  Future<void> setTyping({
    required String conversationId,
    required bool typing,
  }) async {
    if (conversation.isGroup || conversation.peer.isEmpty) {
      // 输入状态仅单聊通道支持（七-3）。
      return;
    }
    await session.setTyping(conversation.peer, typing);
  }

  @override
  Future<String> sendFile({
    required String conversationId,
    required String msgUuid,
    required String path,
    String mime = '',
  }) async {
    final Map<String, dynamic> params;
    final String method;
    if (conversation.isGroup) {
      // A-02：群文件走 dm.sendGroupFile，文件密文写群盘、元数据随群消息广播。
      method = 'dm.sendGroupFile';
      params = <String, dynamic>{
        'group_id': groupIdOf(conversationId),
        'path': path,
        if (mime.isNotEmpty) 'mime': mime,
      };
    } else {
      if (conversation.peer.isEmpty) {
        throw const NexmemException('INVALID_ARG', '会话缺少对端账号，无法发送');
      }
      method = 'dm.sendFile';
      params = <String, dynamic>{
        'peer': conversation.peer,
        'path': path,
        if (mime.isNotEmpty) 'mime': mime,
      };
    }
    final Map<String, dynamic> data = await session.transport.call(
      method,
      params: params,
      timeout: session.requestTimeout,
    );
    final Object? id = data['msg_uuid'];
    return id is String ? id : msgUuid;
  }
}
