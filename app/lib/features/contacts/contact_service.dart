import 'dart:convert';

import '../../transport/transport.dart';
import 'contact.dart';

/// 通讯录数据源（P2-06）：好友列表、添加好友、本地备注与拉黑。
///
/// 全部方法走内核 `contact.*` 契约；备注只落在本机数据库，不会随任何报文上行。
/// P6-21 起同一数据源还提供 `account.devices`，用于「我的设备」与好友资料页。
abstract class ContactService {
  /// 按最近更新倒序返回联系人；失败抛 [NexmemException]。
  Future<List<Contact>> list({int limit = 200});

  /// 添加好友；[account] 接受十六进制或 base64url 账号公钥。
  Future<Contact> add(String account, {String alias = ''});

  /// 设置本地备注；空字符串表示清除。
  Future<void> setRemark(String account, String remark);

  /// 设置好友分组（P6-30）；空字符串表示清除，仅本机可见。
  Future<void> setGroup(String account, String group);

  /// 设置或取消拉黑。
  Future<void> setBlocked(String account, bool blocked);

  /// 查询账号已发布到公开档案的设备列表；[peer] 为空表示本机账号。
  Future<DeviceListResult> devices({String? peer});
}

/// 单台设备（P6-21）：来自索引服务公开档案里的设备证书。
class DeviceInfo {
  const DeviceInfo({
    required this.name,
    required this.deviceId,
    required this.issuedAt,
    required this.notAfter,
    required this.current,
  });

  /// 设备名称，由该设备发布档案时填写。
  final String name;

  /// 设备 PeerID；证书编码异常时为空串。
  final String deviceId;

  /// 证书签发时间，可近似视为该设备最近一次活跃时间。
  final DateTime? issuedAt;

  /// 证书有效期截止时间。
  final DateTime? notAfter;

  /// 是否为本机设备。
  final bool current;
}

/// 设备列表查询结果：区分「档案未发布」与「有档案但没有有效设备证书」。
class DeviceListResult {
  const DeviceListResult({
    required this.items,
    required this.found,
    required this.self,
  });

  const DeviceListResult.empty()
      : items = const <DeviceInfo>[],
        found = false,
        self = true;

  final List<DeviceInfo> items;
  final bool found;
  final bool self;
}

/// 把 `account.devices` 的单个条目映射为 [DeviceInfo]。
DeviceInfo deviceFromJson(Map<String, dynamic> json) {
  final Object? name = json['device_name'];
  final Object? deviceId = json['device_id'];
  final Object? issuedAt = json['issued_at'];
  final Object? notAfter = json['not_after'];
  return DeviceInfo(
    name: name is String && name.trim().isNotEmpty ? name.trim() : '未命名设备',
    deviceId: deviceId is String ? deviceId : '',
    issuedAt: _timeOf(issuedAt),
    notAfter: _timeOf(notAfter),
    current: json['current'] == true,
  );
}

DateTime? _timeOf(Object? seconds) {
  if (seconds is! int || seconds <= 0) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

/// 把 `contact.list` 的单个条目映射为 [Contact]。
///
/// 内核只保存账号公钥与本地备注，没有昵称字段：备注非空时作为展示名，
/// 否则退化为账号短串，保证列表始终可读。
Contact contactFromJson(Map<String, dynamic> json) {
  final Object? pub = json['account_pub'];
  if (pub is! String || pub.isEmpty) {
    throw const FormatException('联系人条目缺少 account_pub');
  }
  final Object? alias = json['alias'];
  final String remark = alias is String ? alias.trim() : '';
  final Object? group = json['group_name'];
  return Contact(
    id: pub,
    name: remark.isEmpty ? shortAccountLabel(pub, asHex: true) : remark,
    note: remark,
    groupName: group is String ? group.trim() : '',
    blocked: json['blocked'] == true,
    peer: peerFromAccount(pub) ?? '',
  );
}

/// 经统一的 [CoreTransport] 调用内核 `contact.*`。
class TransportContactService implements ContactService {
  const TransportContactService(this.transport);

  final CoreTransport transport;

  @override
  Future<List<Contact>> list({int limit = 200}) async {
    final Map<String, dynamic> data = await transport.call(
      'contact.list',
      params: <String, dynamic>{'limit': limit},
    );
    final Object? items = data['items'];
    if (items is! List) {
      return const <Contact>[];
    }
    final List<Contact> out = <Contact>[];
    for (final Object? item in items) {
      if (item is Map<String, dynamic>) {
        out.add(contactFromJson(item));
      }
    }
    return out;
  }

  @override
  Future<Contact> add(String account, {String alias = ''}) async {
    await transport.call(
      'contact.add',
      params: <String, dynamic>{'peer': account, 'alias': alias},
    );
    return (await list()).firstWhere(
      (Contact c) => c.id.toLowerCase() == normalizeAccountHex(account),
      orElse: () => Contact(
        id: normalizeAccountHex(account),
        name: alias.isEmpty ? shortAccountLabel(account) : alias,
        note: alias,
        peer: peerFromAccount(account) ?? '',
      ),
    );
  }

  @override
  Future<void> setRemark(String account, String remark) async {
    await transport.call(
      'contact.remark',
      params: <String, dynamic>{'peer': account, 'remark': remark},
    );
  }

  @override
  Future<void> setGroup(String account, String group) async {
    await transport.call(
      'contact.setGroup',
      params: <String, dynamic>{'peer': account, 'group': group},
    );
  }

  @override
  Future<void> setBlocked(String account, bool blocked) async {
    await transport.call(
      'contact.block',
      params: <String, dynamic>{'peer': account, 'blocked': blocked},
    );
  }

  @override
  Future<DeviceListResult> devices({String? peer}) async {
    final Map<String, dynamic> data = await transport.call(
      'account.devices',
      params: <String, dynamic>{
        if (peer != null && peer.trim().isNotEmpty) 'peer': peer.trim(),
      },
    );
    final Object? items = data['items'];
    final List<DeviceInfo> out = <DeviceInfo>[];
    if (items is List) {
      for (final Object? item in items) {
        if (item is Map<String, dynamic>) {
          out.add(deviceFromJson(item));
        }
      }
    }
    return DeviceListResult(
      items: out,
      found: data['found'] == true,
      self: data['self'] != false,
    );
  }
}

/// 内核未接通时的占位实现：明确抛 `NOT_STARTED`，避免展示假数据。
class UnavailableContactService implements ContactService {
  const UnavailableContactService();

  @override
  Future<List<Contact>> list({int limit = 200}) async {
    throw const NexmemException('NOT_STARTED', '通讯录服务尚未接入内核');
  }

  @override
  Future<Contact> add(String account, {String alias = ''}) async {
    throw const NexmemException('NOT_STARTED', '通讯录服务尚未接入内核');
  }

  @override
  Future<void> setRemark(String account, String remark) async {
    throw const NexmemException('NOT_STARTED', '通讯录服务尚未接入内核');
  }

  @override
  Future<void> setGroup(String account, String group) async {
    throw const NexmemException('NOT_STARTED', '通讯录服务尚未接入内核');
  }

  @override
  Future<void> setBlocked(String account, bool blocked) async {
    throw const NexmemException('NOT_STARTED', '通讯录服务尚未接入内核');
  }

  @override
  Future<DeviceListResult> devices({String? peer}) async {
    throw const NexmemException('NOT_STARTED', '通讯录服务尚未接入内核');
  }
}

/// 账号公钥编码规范化：十六进制（64 字符）或 base64url（32 字节）转小写十六进制。
///
/// 无法识别时原样返回，交由内核返回 `INVALID_ARG`。
String normalizeAccountHex(String account) {
  final String trimmed = account.trim();
  if (trimmed.length == 64 &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(trimmed)) {
    return trimmed.toLowerCase();
  }
  final List<int>? raw = _decodeBase64Url(trimmed);
  if (raw != null && raw.length == 32) {
    return _hexOf(raw);
  }
  return trimmed.toLowerCase();
}

/// 账号公钥转 base64url（无填充），供 `dm.sendText` 的 `peer` 使用。
///
/// 无法识别时返回 null。
String? peerFromAccount(String account) {
  final String hex = normalizeAccountHex(account);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    return null;
  }
  final List<int> bytes = _bytesOfHex(hex);
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 单聊会话 ID：与内核 `dm.ConversationID` 一致，对两端账号公钥排序后拼接。
///
/// [selfAccount] 与 [peer] 都接受十六进制或 base64url；无法识别时抛
/// [FormatException]，避免生成永远匹配不上的会话 ID。
String dmConversationId({required String selfAccount, required String peer}) {
  final String a = _requireHex(selfAccount);
  final String b = _requireHex(peer);
  return a.compareTo(b) <= 0 ? 'dm:$a|$b' : 'dm:$b|$a';
}

/// 账号展示短串：十六进制取前 6 位，其它编码截断到 10 字符。
String shortAccountLabel(String account, {bool asHex = false}) {
  final String hex = asHex ? account.toLowerCase() : normalizeAccountHex(account);
  if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    return '${hex.substring(0, 6)}…';
  }
  return account.length <= 10 ? account : '${account.substring(0, 10)}…';
}

String _requireHex(String account) {
  final String hex = normalizeAccountHex(account);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    throw FormatException('账号公钥非法: $account');
  }
  return hex;
}

String _hexOf(List<int> bytes) {
  final StringBuffer out = StringBuffer();
  for (final int b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

List<int> _bytesOfHex(String hex) {
  final List<int> out = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}

List<int>? _decodeBase64Url(String text) {
  final String normalized =
      text.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  try {
    return base64.decode(base64.normalize(normalized));
  } on FormatException {
    return null;
  }
}
