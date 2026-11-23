import '../../transport/transport.dart';
import '../contacts/contact_service.dart';

/// 群列表条目（`group.list` 的 `items[]`，P4-13）。
class GroupSummary {
  const GroupSummary({
    required this.groupId,
    required this.title,
    required this.memberCount,
    required this.role,
    this.keyVersion = 0,
    this.storageConfigured = false,
    this.announcement = '',
    this.alias = '',
  });

  factory GroupSummary.fromJson(Map<String, dynamic> json) {
    final Object? groupId = json['group_id'];
    if (groupId is! String || groupId.isEmpty) {
      throw const FormatException('group.list 条目缺少 group_id');
    }
    final Object? title = json['title'];
    final Object? count = json['member_count'];
    final Object? role = json['role'];
    final Object? version = json['key_version'];
    return GroupSummary(
      groupId: groupId,
      title: title is String ? title : '',
      memberCount: count is num ? count.toInt() : 0,
      role: role is String && role.isNotEmpty ? role : 'member',
      keyVersion: version is num ? version.toInt() : 0,
      storageConfigured: json['storage_configured'] == true,
      announcement: json['announcement'] is String ? json['announcement'] as String : '',
      alias: json['alias'] is String ? json['alias'] as String : '',
    );
  }

  /// base64url 群 ID。
  final String groupId;
  final String title;
  final int memberCount;

  /// `admin` 或 `member`（本机在该群的角色）。
  final String role;
  final int keyVersion;

  /// 群盘是否已配置；未配置时群聊页会常驻离线不可补提示。
  final bool storageConfigured;

  /// 本机保存的群公告；空串表示未设置（P6-26）。
  final String announcement;

  /// 本机群备注；空串表示未设置，仅本机可见（P6-27）。
  final String alias;

  bool get isAdmin => role == 'admin';

  /// 展示标题：群备注优先于群名，均为空时回退占位（P6-27）。
  String get displayTitle {
    if (alias.isNotEmpty) {
      return alias;
    }
    return title.isEmpty ? '未命名群聊' : title;
  }
}

/// 群成员（`group.members` 的 `members[]` 条目）。
class GroupMember {
  const GroupMember({
    required this.account,
    required this.role,
    this.joinedAt = 0,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    final Object? account = json['account'];
    if (account is! String || account.isEmpty) {
      throw const FormatException('群成员缺少 account');
    }
    final Object? role = json['role'];
    final Object? joined = json['joined_at'];
    return GroupMember(
      account: account,
      role: role is String && role.isNotEmpty ? role : 'member',
      joinedAt: joined is num ? joined.toInt() : 0,
    );
  }

  /// 成员账号公钥（base64url，与联系人 `peer` 同编码）。
  final String account;

  /// `admin` 或 `member`。
  final String role;

  /// 入群时间（毫秒时间戳），未知时为 0。
  final int joinedAt;

  bool get isAdmin => role == 'admin';

  /// 账号短串展示，避免在成员列表里铺满完整公钥。
  String get label => shortAccountLabel(account);
}

/// 群资料（`group.members` 回包，P4-07 数据源）。
class GroupInfo {
  const GroupInfo({
    required this.groupId,
    required this.title,
    required this.keyVersion,
    required this.storageConfigured,
    required this.members,
    this.announcement = '',
    this.alias = '',
  });

  factory GroupInfo.fromJson(Map<String, dynamic> json) {
    final Object? groupId = json['group_id'];
    if (groupId is! String || groupId.isEmpty) {
      throw const FormatException('group.members 缺少 group_id');
    }
    final Object? title = json['title'];
    final Object? version = json['key_version'];
    final Object? items = json['members'];
    final List<GroupMember> members = <GroupMember>[];
    if (items is List) {
      for (final Object? item in items) {
        if (item is Map<String, dynamic>) {
          members.add(GroupMember.fromJson(item));
        }
      }
    }
    return GroupInfo(
      groupId: groupId,
      title: title is String ? title : '',
      keyVersion: version is num ? version.toInt() : 0,
      storageConfigured: json['storage_configured'] == true,
      announcement: json['announcement'] is String ? json['announcement'] as String : '',
      alias: json['alias'] is String ? json['alias'] as String : '',
      members: members,
    );
  }

  final String groupId;
  final String title;
  final int keyVersion;

  /// 群盘是否已配置；未配置时离线消息不可补（ui-spec.md §7）。
  final bool storageConfigured;

  /// 本机保存的群公告；空串表示未设置（P6-26）。
  final String announcement;

  /// 本机群备注；空串表示未设置，仅本机可见（P6-27）。
  final String alias;
  final List<GroupMember> members;

  /// 展示标题：群备注优先于群名，均为空时回退占位（P6-27）。
  String get displayTitle {
    if (alias.isNotEmpty) {
      return alias;
    }
    return title.isEmpty ? '未命名群聊' : title;
  }
}

/// 群盘配置（`group.setStorage` 入参，P4-11）；仅管理员可提交。
///
/// 凭证随群密钥密封后分发给成员，内核不回显，重新配置即整体覆盖。
class GroupStorageConfig {
  const GroupStorageConfig({
    required this.endpoint,
    required this.bucket,
    required this.prefix,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    required this.pathStyle,
  });

  final String endpoint;
  final String bucket;
  final String prefix;
  final String region;
  final String accessKey;
  final String secretKey;
  final bool pathStyle;

  /// 返回第一条校验失败的原因；全部通过返回 null。
  String? validate() {
    if (endpoint.isEmpty) {
      return '请填写 Endpoint';
    }
    if (!endpoint.startsWith('http://') && !endpoint.startsWith('https://')) {
      return 'Endpoint 必须以 http:// 或 https:// 开头';
    }
    if (bucket.isEmpty) {
      return '请填写桶名';
    }
    if (prefix.isEmpty) {
      return '请填写对象前缀';
    }
    if (region.isEmpty) {
      return '请填写 Region';
    }
    if (accessKey.isEmpty || secretKey.isEmpty) {
      return '请填写 AK 与 SK';
    }
    return null;
  }

  Map<String, dynamic> toParams() {
    return <String, dynamic>{
      'endpoint': endpoint,
      'bucket': bucket,
      'prefix': prefix,
      'region': region,
      'ak': accessKey,
      'sk': secretKey,
      'path_style': pathStyle,
    };
  }
}

/// 群聊数据源：`group.create` / `group.list` / `group.members` / `group.invite`
/// / `group.remove` / `group.leave` / `group.dissolve`。
abstract class GroupService {
  /// 建群并分发 v1 群密钥，返回 base64url 群 ID。
  Future<String> create({required String title, required List<String> members});

  /// 列出本机已加入的群（成员数与本人角色）；失败抛 [NexmemException]。
  Future<List<GroupSummary>> list();

  /// 读取群资料与成员表；失败抛 [NexmemException]。
  Future<GroupInfo> members(String groupId);

  /// 邀请账号入群（仅管理员），返回新的密钥版本。
  Future<int> invite(String groupId, String account);

  /// 把成员移出群并轮换密钥（仅管理员），返回新的密钥版本。
  Future<int> remove(String groupId, String account);

  /// 退出群聊：清理本地群记录与密钥，之后不再接收该群消息（P4-12）。
  Future<void> leave(String groupId);

  /// 解散群聊（仅管理员）：广播解散通知并清理本地群（P4-12）。
  Future<void> dissolve(String groupId);

  /// 配置群盘并下发给全体成员（仅管理员）；凭证只在请求内使用。
  Future<void> configureStorage(String groupId, GroupStorageConfig config);

  /// 移除群盘（仅管理员）：尽力删除云端密文并清本机配置，返回删除的对象数（C-05）。
  Future<int> removeStorage(String groupId);

  /// 设置群公告（仅管理员）：空串表示清除，最多 512 字；返回内核保存的文本（P6-26）。
  Future<String> setAnnouncement(String groupId, String announcement);

  /// 设置本机群备注：空串表示清除，最多 32 字；仅本机可见、不上行（P6-27）。
  Future<String> setAlias(String groupId, String alias);
}

/// 群会话 ID：与内核 `coreapp` 的 `group:<base64url>` 同构。
String groupConversationId(String groupId) => 'group:$groupId';

/// 经统一 [CoreTransport] 调用内核群聊方法。
class TransportGroupService implements GroupService {
  const TransportGroupService(this.transport);

  final CoreTransport transport;

  @override
  Future<String> create({
    required String title,
    required List<String> members,
  }) async {
    final Map<String, dynamic> data = await transport.call(
      'group.create',
      params: <String, dynamic>{'title': title, 'members': members},
    );
    final Object? groupId = data['group_id'];
    if (groupId is! String || groupId.isEmpty) {
      throw const NexmemException('BAD_RESPONSE', 'group.create 缺少 group_id');
    }
    return groupId;
  }

  @override
  Future<List<GroupSummary>> list() async {
    final Map<String, dynamic> data = await transport.call(
      'group.list',
      params: <String, dynamic>{},
    );
    final Object? items = data['items'];
    if (items is! List) {
      throw const NexmemException('BAD_RESPONSE', 'group.list 缺少 items');
    }
    try {
      return <GroupSummary>[
        for (final Object? item in items)
          if (item is Map<String, dynamic>) GroupSummary.fromJson(item),
      ];
    } on FormatException catch (error) {
      throw NexmemException('BAD_RESPONSE', error.message);
    }
  }

  @override
  Future<GroupInfo> members(String groupId) async {
    final Map<String, dynamic> data = await transport.call(
      'group.members',
      params: <String, dynamic>{'group_id': groupId},
    );
    try {
      return GroupInfo.fromJson(data);
    } on FormatException catch (error) {
      throw NexmemException('BAD_RESPONSE', error.message);
    }
  }

  @override
  Future<int> invite(String groupId, String account) =>
      _memberMutation('group.invite', groupId, account);

  @override
  Future<int> remove(String groupId, String account) =>
      _memberMutation('group.remove', groupId, account);

  @override
  Future<void> leave(String groupId) =>
      _groupMutation('group.leave', groupId);

  @override
  Future<void> dissolve(String groupId) =>
      _groupMutation('group.dissolve', groupId);

  @override
  Future<void> configureStorage(
    String groupId,
    GroupStorageConfig config,
  ) async {
    await transport.call(
      'group.setStorage',
      params: <String, dynamic>{'group_id': groupId, ...config.toParams()},
    );
  }

  @override
  Future<int> removeStorage(String groupId) async {
    final Map<String, dynamic> data = await transport.call(
      'group.removeStorage',
      params: <String, dynamic>{'group_id': groupId},
    );
    final Object? deleted = data['cloud_objects_deleted'];
    if (deleted is! num) {
      throw const NexmemException(
        'BAD_RESPONSE',
        'group.removeStorage 缺少 cloud_objects_deleted',
      );
    }
    return deleted.toInt();
  }

  @override
  Future<String> setAnnouncement(String groupId, String announcement) async {
    final Map<String, dynamic> data = await transport.call(
      'group.setAnnouncement',
      params: <String, dynamic>{
        'group_id': groupId,
        'announcement': announcement,
      },
    );
    final Object? text = data['announcement'];
    if (text is! String) {
      throw const NexmemException(
        'BAD_RESPONSE',
        'group.setAnnouncement 缺少 announcement',
      );
    }
    return text;
  }

  @override
  Future<String> setAlias(String groupId, String alias) async {
    final Map<String, dynamic> data = await transport.call(
      'group.setAlias',
      params: <String, dynamic>{'group_id': groupId, 'alias': alias},
    );
    final Object? saved = data['alias'];
    if (saved is! String) {
      throw const NexmemException(
        'BAD_RESPONSE',
        'group.setAlias 缺少 alias',
      );
    }
    return saved;
  }

  Future<int> _memberMutation(
    String method,
    String groupId,
    String account,
  ) async {
    final Map<String, dynamic> data = await transport.call(
      method,
      params: <String, dynamic>{'group_id': groupId, 'account': account},
    );
    final Object? version = data['key_version'];
    if (version is! num) {
      throw NexmemException('BAD_RESPONSE', '$method 缺少 key_version');
    }
    return version.toInt();
  }

  Future<void> _groupMutation(String method, String groupId) async {
    await transport.call(
      method,
      params: <String, dynamic>{'group_id': groupId},
    );
  }
}

/// 内核未接通时的占位实现：明确抛 `NOT_STARTED`，避免展示假数据。
class UnavailableGroupService implements GroupService {
  const UnavailableGroupService();

  @override
  Future<String> create({
    required String title,
    required List<String> members,
  }) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<List<GroupSummary>> list() async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<GroupInfo> members(String groupId) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<int> invite(String groupId, String account) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<int> remove(String groupId, String account) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<void> leave(String groupId) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<void> dissolve(String groupId) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<void> configureStorage(
    String groupId,
    GroupStorageConfig config,
  ) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<int> removeStorage(String groupId) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<String> setAnnouncement(String groupId, String announcement) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }

  @override
  Future<String> setAlias(String groupId, String alias) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }
}
