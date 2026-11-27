import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

/// `net.discoverDevices` 返回的一台当前可见设备。
///
/// 只保存身份、地址与连接性质；内核不会做 IP 归属查询，位置由用户自行标注。
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.peerId,
    required this.addrs,
    this.accountId = '',
    this.label = '',
    this.ip = '',
    this.connected = false,
    this.direct = false,
    this.relayed = false,
    this.source = '',
    this.lastSeen = 0,
  });

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) {
    final Object? peer = json['peer_id'];
    final Object? rawAddrs = json['addrs'];
    final List<String> addrs = rawAddrs is List
        ? rawAddrs.whereType<String>().toList(growable: false)
        : <String>[];
    return DiscoveredDevice(
      peerId: peer is String ? peer : '',
      addrs: addrs,
      accountId: json['account_id'] is String ? json['account_id'] as String : '',
      label: json['label'] is String ? json['label'] as String : '',
      ip: json['ip'] is String ? json['ip'] as String : '',
      connected: json['connected'] == true,
      direct: json['direct'] == true,
      relayed: json['relayed'] == true,
      source: json['source'] is String ? json['source'] as String : '',
      lastSeen: json['last_seen'] is num
          ? (json['last_seen'] as num).toInt()
          : 0,
    );
  }

  final String peerId;
  final String accountId;
  final String label;
  final List<String> addrs;
  final String ip;
  final bool connected;
  final bool direct;
  final bool relayed;
  final String source;
  final int lastSeen;

  /// 展示名优先级：地址簿备注 > IP > PeerID 前缀。
  String get displayName {
    if (label.isNotEmpty) {
      return label;
    }
    if (ip.isNotEmpty) {
      return ip;
    }
    return peerId.isEmpty ? '?' : peerId.substring(0, peerId.length.clamp(0, 12));
  }

  /// 用地址簿中的账号 ID 作为台账首选键；没有时回退到 PeerID。
  String get directoryKey => accountId.isNotEmpty ? accountId : peerId;
}

/// 账号发现链路诊断：各发现源原始数量、过滤计数与本机监听地址。
/// 空态时据此给出准确原因，避免笼统提示"没有发现"。
class DiscoveryDiagnostics {
  const DiscoveryDiagnostics({
    this.mdnsEnabled = false,
    this.mdnsRaw = 0,
    this.peerbookRaw = 0,
    this.connectedRaw = 0,
    this.peerstoreRaw = 0,
    this.filteredInfra = 0,
    this.filteredNoProtocol = 0,
    this.hasLanAddr = false,
    this.selfAddrs = const <String>[],
    this.selfId = '',
    this.netIfaces = const <String>[],
    this.listenAddrs = const <String>[],
    this.injectedLan = const <String>[],
    this.mdnsError = '',
    this.lanRaw = 0,
    this.lanBeaconActive = false,
    this.lanBroadcastError = '',
    this.lanBroadcastAddr = '',
    this.lanBroadcastSent = 0,
  });

  factory DiscoveryDiagnostics.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DiscoveryDiagnostics();
    final Object? rawAddrs = json['self_addrs'];
    final Object? rawIfaces = json['net_ifaces'];
    final Object? rawListen = json['listen_addrs'];
    final Object? rawInjected = json['injected_lan'];
    return DiscoveryDiagnostics(
      mdnsEnabled: json['mdns_enabled'] == true,
      mdnsRaw: _intOf(json['mdns_raw']),
      peerbookRaw: _intOf(json['peerbook_raw']),
      connectedRaw: _intOf(json['connected_raw']),
      peerstoreRaw: _intOf(json['peerstore_raw']),
      filteredInfra: _intOf(json['filtered_infra']),
      filteredNoProtocol: _intOf(json['filtered_no_protocol']),
      hasLanAddr: json['has_lan_addr'] == true,
      selfAddrs: rawAddrs is List
          ? rawAddrs.whereType<String>().toList(growable: false)
          : const <String>[],
      selfId: json['self_id'] is String ? json['self_id'] as String : '',
      netIfaces: rawIfaces is List
          ? rawIfaces.whereType<String>().toList(growable: false)
          : const <String>[],
      listenAddrs: rawListen is List
          ? rawListen.whereType<String>().toList(growable: false)
          : const <String>[],
      injectedLan: rawInjected is List
          ? rawInjected.whereType<String>().toList(growable: false)
          : const <String>[],
      mdnsError: json['mdns_error'] is String ? json['mdns_error'] as String : '',
      lanRaw: _intOf(json['lan_raw']),
      lanBeaconActive: json['lan_beacon_active'] == true,
      lanBroadcastError: json['lan_broadcast_error'] is String
          ? json['lan_broadcast_error'] as String
          : '',
      lanBroadcastAddr: json['lan_broadcast_addr'] is String
          ? json['lan_broadcast_addr'] as String
          : '',
      lanBroadcastSent: _intOf(json['lan_broadcast_sent']),
    );
  }

  static int _intOf(Object? value) =>
      value is num ? value.toInt() : 0;

  final bool mdnsEnabled;
  final int mdnsRaw;
  final int peerbookRaw;
  final int connectedRaw;
  final int peerstoreRaw;
  final int filteredInfra;
  final int filteredNoProtocol;
  final bool hasLanAddr;
  final List<String> selfAddrs;
  final String selfId;
  final List<String> netIfaces;
  final List<String> listenAddrs;
  final List<String> injectedLan;
  final String mdnsError;
  final int lanRaw;
  final bool lanBeaconActive;
  final String lanBroadcastError;
  final String lanBroadcastAddr;
  final int lanBroadcastSent;
}

/// 分页发现结果。大量设备时客户端按 offset 增量加载，避免一次性构建全部卡片。
class DeviceDiscoverPage {
  const DeviceDiscoverPage({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
    this.diagnostics = const DiscoveryDiagnostics(),
  });

  factory DeviceDiscoverPage.fromJson(Map<String, dynamic> json) {
    final Object? rawItems = json['items'];
    final List<DiscoveredDevice> items = rawItems is List
        ? rawItems
            .whereType<Map<String, dynamic>>()
            .map(DiscoveredDevice.fromJson)
            .toList(growable: false)
        : <DiscoveredDevice>[];
    final Object? rawDiag = json['diagnostics'];
    return DeviceDiscoverPage(
      items: items,
      total: json['total'] is num ? (json['total'] as num).toInt() : items.length,
      offset: json['offset'] is num ? (json['offset'] as num).toInt() : 0,
      limit: json['limit'] is num ? (json['limit'] as num).toInt() : 200,
      diagnostics: DiscoveryDiagnostics.fromJson(
        rawDiag is Map<String, dynamic> ? rawDiag : null,
      ),
    );
  }

  final List<DiscoveredDevice> items;
  final int total;
  final int offset;
  final int limit;
  final DiscoveryDiagnostics diagnostics;

  bool get hasMore => offset + items.length < total;
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
    this.fileSendTimeout = const Duration(minutes: 5),
    this.startConfig,
    this.rebaseStaleDataDir = false,
    this.pickFile,
    this.pickDirectory,
    this.downloadToBrowser,
    this.mediaSourceUri,
    this.readChatFileBytes,
    this.saveChatFile,
  }) : _activeStartConfig = startConfig;

  final CoreTransport transport;
  final Duration requestTimeout;

  /// 文件发送专用超时。与文本不同，`dm.sendFile` / `dm.sendGroupFile` 要等
  ///  ACK、P2P 分片传输和对端确认，大文件可能远超普通请求的 20s；用通用
  ///  超时会让客户端先把气泡标成失败，而内核随后成功用新的 msg_uuid 发
  ///  `message.updated`，本地乐观消息再也关联不上，用户就看到「发送失败」
  ///  但内核已发出的错位。进度由 `transfer.progress` 事件持续展示。
  final Duration fileSendTimeout;

  /// 嵌入式内核（桌面/移动）的 `core.start` 启动配置；Web 端为 null。
  final Map<String, dynamic>? startConfig;

  /// 移动端重装/备份恢复后沙盒容器 UUID 变化，需把失效的账号数据目录
  /// 重定位到 [startConfig] 中的平台当前目录。桌面用户可能指定合法外部
  /// 目录，Web 目录在网关进程内，均不启用。
  final bool rebaseStaleDataDir;

  /// 当前生效的启动配置：多账号切换后由 [restartWithConfig] 更新，
  /// 使后续 [bootstrap] 重连仍落回同一账号数据目录。
  Map<String, dynamic>? _activeStartConfig;

  /// 当前启动配置的副本，供账号管理器复制网络设置后改写 `data_dir`。
  Map<String, dynamic>? get activeStartConfig =>
      _activeStartConfig == null
          ? null
          : Map<String, dynamic>.from(_activeStartConfig!);

  /// 平台文件选择器（P2-08）；为空时聊天页退回本机路径输入框。
  ///
  /// 移动端由原生通道把选中的 `content://` 复制到应用目录后回传绝对路径。
  final Future<ChatAttachment?> Function()? pickFile;

  /// 平台目录选择器（P2P 文件夹共享）；为空时分享页退回本机路径输入框。
  final Future<String?> Function()? pickDirectory;

  /// Web 端服务端文件取回：内核把群文件写到网关服务端路径，浏览器需经此
  /// 回调构造鉴权 `/download` 链接并触发浏览器保存。桌面/移动端为空，
  /// 因为内核已直接落盘到本机下载目录。
  final Future<void> Function(String serverPath, String fileName)?
      downloadToBrowser;

  /// Web 聊天媒体在线播放源：把内核落盘的服务端路径换成鉴权 `/download`
  /// 链接（`disposition=inline`），供图片缩略图与语音/视频播放器直接使用。
  /// 桌面/移动端为空，因为内核已把文件落到本机，直接用本地文件播放。
  final Uri? Function(String serverPath)? mediaSourceUri;

  /// 聊天附件通用读取 / 保存通道。Web 由网关鉴权端点支撑；桌面与移动
  /// 直接读本机文件并经系统保存对话框落地。
  final Future<Uint8List> Function(String path)? readChatFileBytes;
  final Future<String?> Function(String path, String fileName)? saveChatFile;

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

  /// 汇总当前可见设备：地址簿 + mDNS + 已连接节点 + peerstore。
  /// 支持分页，设备很多时由 UI 分批加载；不做 IP 归属查询。
  Future<DeviceDiscoverPage> discoverDevices({
    int limit = 200,
    int offset = 0,
  }) async {
    final Map<String, dynamic> data = await transport.call(
      'net.discoverDevices',
      params: <String, dynamic>{'limit': limit, 'offset': offset},
      timeout: requestTimeout,
    );
    return DeviceDiscoverPage.fromJson(data);
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
      final Map<String, dynamic>? config = startConfig ?? _activeStartConfig;
      if (config == null || error.code != 'NOT_STARTED') {
        rethrow;
      }
      await transport.call(
        'core.start',
        params: <String, dynamic>{'config': config},
        timeout: requestTimeout,
      );
      _activeStartConfig = config;
      _account = await _loadAccount();
    }
    return _account!;
  }

  /// 读取内核当前数据目录（Web 端由 webd 启动时指定，客户端无法从配置推断）。
  /// 旧内核未接入 `core.dataDir` 时返回 null，调用方按未知处理。
  Future<String?> currentDataDir() async {
    try {
      final Map<String, dynamic> data = await transport.call(
        'core.dataDir',
        timeout: requestTimeout,
      );
      final Object? dir = data['data_dir'];
      return dir is String && dir.trim().isNotEmpty ? dir.trim() : null;
    } on Object {
      return null;
    }
  }

  /// 停止内核并清空当前账号缓存；用于退出登录与临时锁。
  Future<void> stop() async {
    await transport.call('core.stop', timeout: requestTimeout);
    _account = null;
  }

  /// 切换到另一个本地账号：先停内核，再以目标数据目录重启并读取账号。
  ///
  /// 所有账号共用同一个内核进程与传输通道，切换必须停机；[config] 至少包含
  /// `data_dir`，其余启动项沿用调用方从当前配置复制出的网络设置。
  Future<CoreAccount> restartWithConfig(Map<String, dynamic> config) async {
    await transport.call('core.stop', timeout: requestTimeout);
    await transport.call(
      'core.start',
      params: <String, dynamic>{'config': config},
      timeout: requestTimeout,
    );
    _activeStartConfig = config;
    _account = await _loadAccount();
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

  /// 群文件默认落盘路径：系统下载目录 / 文档目录，Web 端回落到内核数据目录。
  /// 内核 `file.downloadGroup` 要求绝对路径，故不返回相对路径。
  ///
  /// Web 端内核在网关进程内，落盘路径是服务端路径，浏览器无法直接取回；
  /// 因此专门落到数据目录下的 `web-downloads` 子目录——它正是网关 `/download`
  /// 放行的白名单目录，下载后由 [downloadToBrowser] 触发浏览器保存。只放行
  /// 这个子目录而不是整个数据目录，避免私钥/数据库被任意下载。
  Future<String> groupFileDownloadPath(String name) async {
    final String safeName = p.basename(name.replaceAll(r'\', '/'));
    final String fileName = safeName.isEmpty ? 'group-file' : safeName;
    if (kIsWeb) {
      final String? dataDir = await currentDataDir();
      if (dataDir == null || dataDir.isEmpty) {
        throw const NexmemException(
          'NOT_ONLINE',
          '无法确定内核数据目录，无法下载群文件',
        );
      }
      return p.join(dataDir, 'web-downloads', fileName);
    }
    String base = '';
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null && downloads.path.isNotEmpty) {
        base = downloads.path;
      }
    } on Object {
      // Web / 部分平台不支持，继续回落。
    }
    if (base.isEmpty) {
      try {
        base = (await getApplicationDocumentsDirectory()).path;
      } on Object {
        // 继续回落到内核数据目录。
      }
    }
    if (base.isEmpty) {
      base = await currentDataDir() ?? '';
    }
    if (base.isEmpty) {
      throw const NexmemException(
        'NOT_ONLINE',
        '无法确定群文件下载目录，请在设置中配置内核数据目录',
      );
    }
    return p.join(base, fileName);
  }

  /// 从群盘下载并解密群文件，写入 [destPath]（必须绝对路径）。
  ///
  /// 群文件消息附带的 `blob_ref` / `key_b64` 由 `msg.list` 回传；本方法把
  /// 它们交给内核的 `file.downloadGroup`，返回落盘结果与校验摘要。
  /// 大文件下载使用 5 分钟上限，避免普通 RPC 超时误判为失败。
  Future<GroupFileDownload> downloadGroupFile({
    required String conversationId,
    required ChatAttachment attachment,
    required String destPath,
  }) async {
    final Map<String, dynamic> data = await transport.call(
      'file.downloadGroup',
      params: <String, dynamic>{
        'group_id': groupIdOf(conversationId),
        'blob_ref': attachment.blobRef,
        'key_b64': attachment.keyB64,
        'path': destPath,
      },
      timeout: const Duration(minutes: 5),
    );
    return GroupFileDownload(
      path: data['path'] is String ? data['path'] as String : destPath,
      size: data['size'] is num ? (data['size'] as num).toInt() : attachment.size,
      sha256: data['sha256'] is String ? data['sha256'] as String : '',
    );
  }

  Future<void> close() => transport.close();
}

/// `file.downloadGroup` 的落盘结果。
class GroupFileDownload {
  const GroupFileDownload({
    required this.path,
    required this.size,
    this.sha256 = '',
  });

  final String path;
  final int size;
  final String sha256;
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
  final Object? blobRef = first['blob_ref'];
  final Object? keyB64 = first['key_b64'];
  return ChatAttachment(
    name: name is String ? name : '文件',
    size: size is num ? size.toInt() : 0,
    mime: mime is String ? mime : '',
    path: path is String ? path : '',
    blobRef: blobRef is String ? blobRef : '',
    keyB64: keyB64 is String ? keyB64 : '',
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
      timeout: session.fileSendTimeout,
    );
    final Object? id = data['msg_uuid'];
    return id is String ? id : msgUuid;
  }
}
