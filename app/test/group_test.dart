// P4-09 验收：`+` 建群入口、群资料页与 `group.*` 契约映射。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chats/chats_page.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/contacts/contacts_page.dart';
import 'package:nexmem_app/features/group/group_info_page.dart';
import 'package:nexmem_app/features/group/group_list_page.dart';
import 'package:nexmem_app/features/group/group_share_link.dart';
import 'package:nexmem_app/features/group/group_service.dart';
import 'package:nexmem_app/features/group/group_storage.dart';
import 'package:nexmem_app/transport/transport.dart';

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handler);

  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic>? params,
  )
  handler;

  final List<(String, Map<String, dynamic>?)> calls =
      <(String, Map<String, dynamic>?)>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) {
    calls.add((method, params));
    return handler(method, params);
  }

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

class _FakeContacts implements ContactService {
  _FakeContacts(this.contacts);

  final List<Contact> contacts;

  @override
  Future<List<Contact>> list({int limit = 200}) async => contacts;

  @override
  Future<Contact> add(String account, {String alias = ''}) async =>
      throw UnimplementedError();

  @override
  Future<void> setRemark(String account, String remark) async =>
      throw UnimplementedError();

  @override
  Future<void> setGroup(String account, String group) async =>
      throw UnimplementedError();

  @override
  Future<void> setBlocked(String account, bool blocked) async =>
      throw UnimplementedError();

  @override
  Future<void> remove(String account) async => throw UnimplementedError();

  @override
  Future<DeviceListResult> devices({String? peer}) async =>
      const DeviceListResult(items: <DeviceInfo>[], found: true, self: true);
}

class _FakeGroups implements GroupService {
  _FakeGroups({this.info, this.groups = const <GroupSummary>[]});

  GroupInfo? info;
  List<GroupSummary> groups;
  String? listError;
  final List<(String, List<String>)> created = <(String, List<String>)>[];
  final List<(String, String)> invited = <(String, String)>[];
  final List<(String, String)> removed = <(String, String)>[];
  final List<String> left = <String>[];
  final List<String> dissolved = <String>[];
  final List<(String, GroupStorageConfig)> storageConfigs =
      <(String, GroupStorageConfig)>[];
  final List<String> storageRemoved = <String>[];
  final List<(String, String)> announcements = <(String, String)>[];
  final List<(String, String)> avatarUpdates = <(String, String)>[];
  final List<(String, String)> descriptionUpdates = <(String, String)>[];
  final List<(String, bool)> allowFriendAddUpdates = <(String, bool)>[];
  final List<(String, String)> aliases = <(String, String)>[];
  final List<(String, bool, List<GroupLevel>)> levelConfigs =
      <(String, bool, List<GroupLevel>)>[];
  final List<(String, String, String?, String?)> memberProfiles =
      <(String, String, String?, String?)>[];

  @override
  Future<String> create({
    required String title,
    required List<String> members,
  }) async {
    created.add((title, members));
    return 'Z3JvdXA';
  }

  @override
  Future<List<GroupSummary>> list() async {
    final String? error = listError;
    if (error != null) {
      throw NexmemException('DB_ERROR', error);
    }
    return groups;
  }

  /// A-03：记录 members 拉取次数，用于验证公告事件触发的刷新。
  int membersCalls = 0;

  @override
  Future<GroupInfo> members(String groupId) async {
    membersCalls++;
    final GroupInfo? info = this.info;
    if (info == null) {
      throw const NexmemException('NOT_FOUND', '群不存在');
    }
    return info;
  }

  @override
  Future<int> invite(String groupId, String account) async {
    invited.add((groupId, account));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: current.storageConfigured,
        announcement: current.announcement,
        alias: current.alias,
        allowFriendAdd: current.allowFriendAdd,
        members: <GroupMember>[
          ...current.members,
          GroupMember(account: account, role: 'member'),
        ],
      );
    }
    return current?.keyVersion ?? 1;
  }

  @override
  Future<GroupInviteResult> inviteDetailed(String groupId, String account) async {
    return GroupInviteResult(keyVersion: await invite(groupId, account));
  }

  @override
  Future<int> remove(String groupId, String account) async {
    removed.add((groupId, account));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion + 1,
        storageConfigured: current.storageConfigured,
        announcement: current.announcement,
        alias: current.alias,
        allowFriendAdd: current.allowFriendAdd,
        members: current.members
            .where((GroupMember m) => m.account != account)
            .toList(),
      );
    }
    return (current?.keyVersion ?? 1) + 1;
  }

  @override
  Future<void> leave(String groupId) async {
    left.add(groupId);
  }

  @override
  Future<void> dissolve(String groupId) async {
    dissolved.add(groupId);
  }

  @override
  Future<void> configureStorage(
    String groupId,
    GroupStorageConfig config,
  ) async {
    storageConfigs.add((groupId, config));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: true,
        announcement: current.announcement,
        alias: current.alias,
        allowFriendAdd: current.allowFriendAdd,
        members: current.members,
      );
    }
  }

  @override
  Future<int> removeStorage(String groupId) async {
    storageRemoved.add(groupId);
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: false,
        announcement: current.announcement,
        alias: current.alias,
        allowFriendAdd: current.allowFriendAdd,
        members: current.members,
      );
    }
    return 0;
  }

  @override
  Future<String> setAnnouncement(String groupId, String announcement) async {
    announcements.add((groupId, announcement));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: current.storageConfigured,
        announcement: announcement,
        alias: current.alias,
        allowFriendAdd: current.allowFriendAdd,
        members: current.members,
      );
    }
    return announcement;
  }

  @override
  Future<String> setAvatar(String groupId, String avatarB64) async {
    avatarUpdates.add((groupId, avatarB64));
    final GroupInfo? current = info;
    if (current != null) {
      info = current.copyWith(avatarB64: avatarB64);
    }
    return avatarB64;
  }

  @override
  Future<String> setDescription(String groupId, String description) async {
    descriptionUpdates.add((groupId, description));
    final GroupInfo? current = info;
    if (current != null) {
      info = current.copyWith(description: description);
    }
    return description;
  }

  @override
  Future<bool> setAllowFriendAdd(String groupId, bool enabled) async {
    allowFriendAddUpdates.add((groupId, enabled));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: current.storageConfigured,
        announcement: current.announcement,
        alias: current.alias,
        allowFriendAdd: enabled,
        members: current.members,
      );
    }
    return enabled;
  }

  @override
  Future<String> setAlias(String groupId, String alias) async {
    aliases.add((groupId, alias));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: current.storageConfigured,
        announcement: current.announcement,
        alias: alias,
        members: current.members,
      );
    }
    return alias;
  }

  @override
  Future<GroupLevels> setLevelConfig(
    String groupId, {
    required bool enabled,
    required List<GroupLevel> levels,
  }) async {
    levelConfigs.add((groupId, enabled, levels));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: current.storageConfigured,
        announcement: current.announcement,
        alias: current.alias,
        allowFriendAdd: current.allowFriendAdd,
        levelEnabled: enabled,
        levels: levels,
        members: current.members,
      );
    }
    return GroupLevels(enabled: enabled, items: levels);
  }

  @override
  Future<GroupMemberProfile> setMemberProfile(
    String groupId,
    String account, {
    String? nickname,
    String? levelId,
  }) async {
    memberProfiles.add((groupId, account, nickname, levelId));
    final GroupInfo? current = info;
    if (current != null) {
      info = GroupInfo(
        groupId: current.groupId,
        title: current.title,
        keyVersion: current.keyVersion,
        storageConfigured: current.storageConfigured,
        announcement: current.announcement,
        alias: current.alias,
        allowFriendAdd: current.allowFriendAdd,
        levelEnabled: current.levelEnabled,
        levels: current.levels,
        members: <GroupMember>[
          for (final GroupMember member in current.members)
            if (member.account == account)
              member.copyWith(
                nickname: nickname ?? member.nickname,
                levelId: levelId ?? member.levelId,
              )
            else
              member,
        ],
      );
    }
    return GroupMemberProfile(
      account: account,
      nickname: nickname ?? '',
      levelId: levelId ?? '',
    );
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

/// 群资料页新增等级设置入口后底部按钮可能落在视口外，测试里先滚动到列表底部。
Future<void> _scrollGroupInfoToBottom(WidgetTester tester) async {
  final Finder list = find.byType(ListView).first;
  if (list.evaluate().isEmpty) {
    return;
  }
  for (int i = 0; i < 6; i++) {
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
}

void main() {
  test('TransportGroupService 建群参数与回包映射', () async {
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      expect(method, 'group.create');
      expect(params?['title'], '周末爬山');
      expect(params?['members'], <String>['peer-a', 'peer-b']);
      return <String, dynamic>{'group_id': 'Z3JvdXA'};
    });

    final String groupId = await TransportGroupService(transport)
        .create(title: '周末爬山', members: <String>['peer-a', 'peer-b']);

    expect(groupId, 'Z3JvdXA');
    expect(groupConversationId(groupId), 'group:Z3JvdXA');
  });

  test('TransportGroupService 解析 group.members', () async {
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      expect(method, 'group.members');
      expect(params?['group_id'], 'Z3JvdXA');
      return <String, dynamic>{
        'group_id': 'Z3JvdXA',
        'title': '周末爬山',
        'key_version': 2,
        'storage_configured': true,
        'members': <dynamic>[
          <String, dynamic>{'account': 'admin-account', 'role': 'admin'},
          <String, dynamic>{'account': 'member-account'},
        ],
      };
    });

    final GroupInfo info = await TransportGroupService(transport)
        .members('Z3JvdXA');

    expect(info.title, '周末爬山');
    expect(info.keyVersion, 2);
    expect(info.storageConfigured, isTrue);
    expect(info.members.length, 2);
    expect(info.members.first.isAdmin, isTrue);
    expect(info.members.last.isAdmin, isFalse);
  });

  test('TransportGroupService 解析 group.list', () async {
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      expect(method, 'group.list');
      expect(params, isEmpty);
      return <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'group_id': 'Alpha',
            'title': '周末爬山',
            'member_count': 3,
            'role': 'admin',
            'key_version': 2,
            'storage_configured': true,
          },
          <String, dynamic>{
            'group_id': 'Beta',
            'title': '',
            'role': 'member',
          },
        ],
      };
    });

    final List<GroupSummary> groups = await TransportGroupService(transport)
        .list();

    expect(groups.length, 2);
    expect(groups.first.groupId, 'Alpha');
    expect(groups.first.displayTitle, '周末爬山');
    expect(groups.first.memberCount, 3);
    expect(groups.first.isAdmin, isTrue);
    expect(groups.first.keyVersion, 2);
    expect(groups.first.storageConfigured, isTrue);
    expect(groups.last.displayTitle, '未命名群聊');
    expect(groups.last.memberCount, 0);
    expect(groups.last.isAdmin, isFalse);
  });

  test('TransportGroupService 邀请/移除映射 key_version', () async {
    final List<(String, Map<String, dynamic>?)> calls =
        <(String, Map<String, dynamic>?)>[];
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      calls.add((method, params));
      expect(params?['group_id'], 'Z3JvdXA');
      expect(params?['account'], 'carol-id');
      return <String, dynamic>{
        'group_id': 'Z3JvdXA',
        'key_version': 3,
        'failed': 0,
      };
    });

    final TransportGroupService service = TransportGroupService(transport);
    expect(await service.invite('Z3JvdXA', 'carol-id'), 3);
    expect(await service.remove('Z3JvdXA', 'carol-id'), 3);
    expect(
      calls.map(((String, Map<String, dynamic>?) c) => c.$1).toList(),
      <String>['group.invite', 'group.remove'],
    );
  });

  test('TransportGroupService 配置群盘映射 group.setStorage', () async {
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      expect(method, 'group.setStorage');
      expect(params?['group_id'], 'Z3JvdXA');
      expect(params?['endpoint'], 'http://127.0.0.1:9000');
      expect(params?['bucket'], 'nexmem');
      expect(params?['prefix'], 'nexmem-group');
      expect(params?['region'], 'us-east-1');
      expect(params?['ak'], 'minioadmin');
      expect(params?['sk'], 'minioadmin');
      expect(params?['path_style'], isTrue);
      return <String, dynamic>{};
    });

    await TransportGroupService(transport).configureStorage(
      'Z3JvdXA',
      const GroupStorageConfig(
        endpoint: 'http://127.0.0.1:9000',
        bucket: 'nexmem',
        prefix: 'nexmem-group',
        region: 'us-east-1',
        accessKey: 'minioadmin',
        secretKey: 'minioadmin',
        pathStyle: true,
      ),
    );

    expect(transport.calls.single.$1, 'group.setStorage');
  });

  test('TransportGroupService 映射 group.setAnnouncement', () async {
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      expect(method, 'group.setAnnouncement');
      expect(params?['group_id'], 'Z3JvdXA');
      expect(params?['announcement'], '本周六上午十点全员会议');
      return <String, dynamic>{'announcement': '本周六上午十点全员会议'};
    });

    final String text = await TransportGroupService(
      transport,
    ).setAnnouncement('Z3JvdXA', '本周六上午十点全员会议');

    expect(text, '本周六上午十点全员会议');
  });

  test('TransportGroupService 映射 group.setAlias 与清除', () async {
    final List<(String, Map<String, dynamic>?)> calls =
        <(String, Map<String, dynamic>?)>[];
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      calls.add((method, params));
      return <String, dynamic>{'alias': params?['alias'] ?? ''};
    });

    final TransportGroupService service = TransportGroupService(transport);
    expect(await service.setAlias('Z3JvdXA', '爬山小队'), '爬山小队');
    expect(await service.setAlias('Z3JvdXA', ''), '');
    expect(calls.length, 2);
    expect(calls.first.$1, 'group.setAlias');
    expect(calls.first.$2, <String, dynamic>{
      'group_id': 'Z3JvdXA',
      'alias': '爬山小队',
    });
    expect(calls.last.$2?['alias'], '');
  });

  test('TransportGroupService 退群/解散只传 group_id', () async {
    final List<(String, Map<String, dynamic>?)> calls =
        <(String, Map<String, dynamic>?)>[];
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      calls.add((method, params));
      expect(params, <String, dynamic>{'group_id': 'Z3JvdXA'});
      return <String, dynamic>{};
    });

    final TransportGroupService service = TransportGroupService(transport);
    await service.leave('Z3JvdXA');
    await service.dissolve('Z3JvdXA');
    expect(
      calls.map(((String, Map<String, dynamic>?) c) => c.$1).toList(),
      <String>['group.leave', 'group.dissolve'],
    );
  });

  testWidgets('群资料页展示成员、密钥版本与群盘提示', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: false,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(groupId: 'Z3JvdXA', title: '周末爬山', service: groups),
      ),
    );
    await tester.pumpAndSettle();

    // 群资料头部新增群头像卡片，标题同时出现在应用栏与头像卡片。
    expect(find.text('周末爬山'), findsNWidgets(2));
    expect(find.text('未配置群盘，离线消息不可补'), findsOneWidget);
    await _scrollGroupInfoToBottom(tester);
    expect(find.text('群成员（2）'), findsOneWidget);
    expect(find.text('密钥版本 v2'), findsOneWidget);
    expect(find.text('群主'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('group-member-member-account')),
      findsOneWidget,
    );
  });

  testWidgets('群资料页分享群信息：复制可直接解析的入群链接', (
    WidgetTester tester,
  ) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );
    String? clipboard;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('group-share-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('group-share-button')));
    await tester.pumpAndSettle();

    expect(clipboard, isNotNull);
    expect(clipboard, contains('Z3JvdXA'));
    expect(clipboard, contains('周末爬山'));
    expect(clipboard, contains('admin-account'));

    final GroupShareInfo? shared = parseGroupShareText(clipboard!);
    expect(shared, isNotNull);
    expect(shared!.groupId, 'Z3JvdXA');
    expect(shared.owner, 'admin-account');
    expect(shared.title, '周末爬山');
  });

  testWidgets('A-03 群公告事件推送后群资料页重新拉取并刷新公告', (
    WidgetTester tester,
  ) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 1,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
        ],
      ),
    );
    final ValueNotifier<int> revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'admin-account',
          announcementRevision: revision,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始加载一次；空公告态。
    expect(groups.membersCalls, 1);
    expect(find.text('暂无群公告'), findsOneWidget);

    // 内核收到其他成员公告更新 → 壳层递增版本号 + fake 的权威数据更新。
    groups.info = const GroupInfo(
      groupId: 'Z3JvdXA',
      title: '周末爬山',
      keyVersion: 1,
      storageConfigured: true,
      announcement: '本周六上午十点集合',
      members: <GroupMember>[
        GroupMember(account: 'admin-account', role: 'admin'),
      ],
    );
    revision.value++;
    await tester.pumpAndSettle();

    // 版本变化触发 reload（第二次拉取），界面显示新公告。
    expect(groups.membersCalls, 2);
    expect(find.text('本周六上午十点集合'), findsOneWidget);
    expect(find.text('暂无群公告'), findsNothing);
  });

  testWidgets('群公告为空时管理员看到空态与设置入口', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'admin-account',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('群公告'), findsOneWidget);
    expect(find.text('暂无群公告'), findsOneWidget);
    // 群备注空态同样显示「设置」，需按公告按钮自身定位（P6-27）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('group-announcement-edit')),
        matching: find.text('设置'),
      ),
      findsOneWidget,
    );
    expect(find.text('群备注'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('group-alias-edit')),
      findsOneWidget,
    );
  });

  testWidgets('管理员编辑群公告：超限禁用保存，保存成功后本地刷新', (
    WidgetTester tester,
  ) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'admin-account',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('group-announcement-edit')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('group-announcement-dialog')),
      findsOneWidget,
    );

    // 超过 512 字时计数变红且保存按钮禁用。
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-announcement-input')),
      '长' * 513,
    );
    await tester.pump();
    expect(find.text('513/512'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('group-announcement-save')),
          )
          .onPressed,
      isNull,
    );

    const String text = '本周六上午十点全员会议，请准时参加。';
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-announcement-input')),
      text,
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('group-announcement-save')),
    );
    await tester.pumpAndSettle();

    expect(groups.announcements.single, ('Z3JvdXA', text));
    expect(find.text(text), findsOneWidget);
    expect(find.text('暂无群公告'), findsNothing);
    expect(find.text('编辑'), findsOneWidget);
  });

  testWidgets('任意成员可设置/清除群备注：超限禁用、回调刷新会话标题', (
    WidgetTester tester,
  ) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );
    final List<String> changed = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'member-account',
          onAliasChanged: changed.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 非管理员也能看到备注入口，且空态提示回落群名。
    expect(find.text('群备注'), findsOneWidget);
    expect(find.text('仅本机可见，清空后显示群名'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('group-alias-edit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('group-alias-dialog')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('group-alias-input')),
      '备' * 33,
    );
    await tester.pump();
    expect(find.text('33/32'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('group-alias-save')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('group-alias-input')),
      '爬山小队',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('group-alias-save')));
    await tester.pumpAndSettle();

    expect(groups.aliases.single, ('Z3JvdXA', '爬山小队'));
    expect(changed, <String>['爬山小队']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('group-alias-tile')),
        matching: find.text('爬山小队'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('group-alias-edit')),
        matching: find.text('编辑'),
      ),
      findsOneWidget,
    );

    // 清空备注后回落群名，并再次通知壳层刷新会话标题。
    await tester.tap(find.byKey(const ValueKey<String>('group-alias-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-alias-input')),
      '',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('group-alias-save')));
    await tester.pumpAndSettle();

    expect(groups.aliases.last, ('Z3JvdXA', ''));
    expect(changed, <String>['爬山小队', '']);
    expect(find.text('仅本机可见，清空后显示群名'), findsOneWidget);
  });

  testWidgets('非管理员只能查看群公告', (WidgetTester tester) async {
    const String text = '本周六上午十点全员会议，请准时参加。';
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        announcement: text,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'member-account',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(text), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('group-announcement-text')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('group-announcement-edit')),
      findsNothing,
    );
    expect(find.text('暂无群公告'), findsNothing);
  });

  testWidgets('+ 创建群聊：标题 + 成员，回调 group.create 结果', (WidgetTester tester) async {
    final List<Contact> contacts = <Contact>[
      const Contact(id: 'alice-id', name: 'Alice', peer: 'peer-a'),
      const Contact(id: 'bob-id', name: 'Bob', peer: 'peer-b'),
    ];
    final _FakeContacts contactService = _FakeContacts(contacts);
    final _FakeGroups groups = _FakeGroups();
    String? createdId;
    String? createdTitle;

    await tester.pumpWidget(
      _wrap(
        ChatsPage(
          contacts: contactService,
          groups: groups,
          onGroupCreated: (String id, String title) {
            createdId = id;
            createdTitle = title;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('chats-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('start-chat-group')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('create-group-title')),
      '周末爬山',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('create-group-member-alice-id')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('create-group-confirm')),
    );
    await tester.pumpAndSettle();

    expect(groups.created.single.$1, '周末爬山');
    expect(groups.created.single.$2, <String>['peer-a']);
    expect(createdId, 'Z3JvdXA');
    expect(createdTitle, '周末爬山');
  });

  testWidgets('建群对话框校验：空群名被拦截，允许创建空群', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups();

    await tester.pumpWidget(
      _wrap(
        ChatsPage(
          contacts: _FakeContacts(<Contact>[
            const Contact(id: 'alice-id', name: 'Alice', peer: 'peer-a'),
          ]),
          groups: groups,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('chats-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('start-chat-group')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('create-group-confirm')),
    );
    await tester.pump();
    expect(find.text('请输入群名称'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('create-group-title')),
      '周末爬山',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('create-group-confirm')),
    );
    await tester.pumpAndSettle();
    // 与 QQ 一致：允许先建空群，之后再邀请成员；群主自动入群。
    expect(groups.created, hasLength(1));
    expect(groups.created.single.$1, '周末爬山');
    expect(groups.created.single.$2, isEmpty);
  });

  testWidgets('管理员可邀请联系人并把成员移出群', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );
    final _FakeContacts contacts = _FakeContacts(<Contact>[
      const Contact(id: 'member-account', name: 'Member'),
      const Contact(id: 'carol-id', name: 'Carol'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'admin-account',
          contacts: contacts,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 邀请：已在群内的联系人不出现在候选列表。
    await tester.tap(find.byKey(const ValueKey<String>('group-invite-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('group-invite-contact-member-account')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('group-invite-contact-carol-id')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('group-invite-confirm')),
    );
    await tester.pumpAndSettle();
    expect(groups.invited.single, ('Z3JvdXA', 'carol-id'));
    // 好友备注名作为本群称呼写入。
    expect(groups.memberProfiles.single.$2, 'carol-id');
    expect(groups.memberProfiles.single.$3, 'Carol');
    await _scrollGroupInfoToBottom(tester);
    expect(find.text('群成员（3）'), findsOneWidget);

    // 移除：确认后成员数回到 2，管理员自己没有移除入口。
    expect(
      find.byKey(const ValueKey<String>('group-remove-admin-account')),
      findsNothing,
    );
    await _scrollGroupInfoToBottom(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('group-remove-member-account')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('group-remove-confirm')),
    );
    await tester.pumpAndSettle();
    expect(groups.removed.single, ('Z3JvdXA', 'member-account'));
    expect(find.text('群成员（2）'), findsOneWidget);
  });

  testWidgets('管理员配置群盘：校验、提交 group.setStorage 并刷新状态', (
    WidgetTester tester,
  ) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: false,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'admin-account',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(GroupStorageNotice.message), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('group-storage-config')));
    await tester.pumpAndSettle();

    // 群盘配置页展示计费归属（群主账单）与最小权限提示。
    expect(
      find.byKey(const ValueKey<String>('group-storage-billing-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('计入群盘所属方（群主）的云存储账单'), findsOneWidget);
    // C-05：强制受限子密钥勾选门槛存在。
    expect(
      find.byKey(const ValueKey<String>('group-storage-scoped-key-confirm')),
      findsOneWidget,
    );

    // 空表单先做行内校验，不产生提交。
    await tester.tap(find.byKey(const ValueKey<String>('group-storage-save')));
    await tester.pump();
    expect(find.text('请填写 Endpoint'), findsOneWidget);
    expect(groups.storageConfigs, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey<String>('group-storage-endpoint')),
      'http://127.0.0.1:9000',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-storage-bucket')),
      'nexmem',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-storage-ak')),
      'groupScopedKey01',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('group-storage-sk')),
      'scoped-secret',
    );
    // 未勾选门槛时提交被拦截。
    await tester.tap(find.byKey(const ValueKey<String>('group-storage-save')));
    await tester.pump();
    expect(find.textContaining('请先确认使用仅授权本群前缀'), findsOneWidget);
    expect(groups.storageConfigs, isEmpty);

    final Finder scopedCheckbox = find.byKey(
      const ValueKey<String>('group-storage-scoped-key-confirm'),
    );
    await tester.ensureVisible(scopedCheckbox);
    await tester.tap(scopedCheckbox);
    await tester.tap(find.byKey(const ValueKey<String>('group-storage-save')));
    await tester.pumpAndSettle();

    final (String, GroupStorageConfig) call = groups.storageConfigs.single;
    expect(call.$1, 'Z3JvdXA');
    expect(call.$2.endpoint, 'http://127.0.0.1:9000');
    expect(call.$2.bucket, 'nexmem');
    expect(call.$2.prefix, 'nexmem-group');
    expect(call.$2.region, 'us-east-1');
    expect(call.$2.accessKey, 'groupScopedKey01');
    expect(call.$2.secretKey, 'scoped-secret');
    expect(call.$2.pathStyle, isTrue);

    expect(find.text(GroupStorageNotice.message), findsNothing);
    expect(find.text('已配置，成员离线时可从群盘补齐'), findsOneWidget);
    expect(find.text('重新配置'), findsOneWidget);
  });

  testWidgets('非管理员看不到邀请与移除入口', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'member-account',
          contacts: _FakeContacts(<Contact>[
            const Contact(id: 'carol-id', name: 'Carol'),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('group-invite-button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('group-remove-admin-account')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('group-storage-config')),
      findsNothing,
    );
    await _scrollGroupInfoToBottom(tester);
    expect(
      find.byKey(const ValueKey<String>('group-leave-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('group-dissolve-button')),
      findsNothing,
    );
  });

  testWidgets('成员退群：确认后调用 group.leave 并返回 true', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey<String>('open-group-info'),
                onPressed: () async {
                  result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (BuildContext context) => GroupInfoPage(
                        groupId: 'Z3JvdXA',
                        title: '周末爬山',
                        service: groups,
                        selfAccount: 'member-account',
                      ),
                    ),
                  );
                },
                child: const Text('打开群资料'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('open-group-info')));
    await tester.pumpAndSettle();
    await _scrollGroupInfoToBottom(tester);
    await tester.tap(find.byKey(const ValueKey<String>('group-leave-button')));
    await tester.pumpAndSettle();
    expect(find.text('退出后将不再接收该群消息，本机历史消息保留。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('group-leave-confirm')));
    await tester.pumpAndSettle();

    expect(groups.left.single, 'Z3JvdXA');
    expect(groups.dissolved, isEmpty);
    expect(result, isTrue);
    expect(find.byType(GroupInfoPage), findsNothing);
  });

  testWidgets('管理员解散：确认后调用 group.dissolve 并返回 true', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
          GroupMember(account: 'member-account', role: 'member'),
        ],
      ),
    );
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey<String>('open-group-info'),
                onPressed: () async {
                  result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (BuildContext context) => GroupInfoPage(
                        groupId: 'Z3JvdXA',
                        title: '周末爬山',
                        service: groups,
                        selfAccount: 'admin-account',
                      ),
                    ),
                  );
                },
                child: const Text('打开群资料'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('open-group-info')));
    await tester.pumpAndSettle();
    await _scrollGroupInfoToBottom(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('group-dissolve-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('解散后所有成员将无法继续收发消息，且不可恢复。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('group-leave-confirm')));
    await tester.pumpAndSettle();

    expect(groups.dissolved.single, 'Z3JvdXA');
    expect(groups.left, isEmpty);
    expect(result, isTrue);
    expect(find.byType(GroupInfoPage), findsNothing);
  });

  testWidgets('通讯录「群聊」进入群列表并打开群会话', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      groups: <GroupSummary>[
        const GroupSummary(
          groupId: 'Alpha',
          title: '周末爬山',
          memberCount: 3,
          role: 'admin',
          keyVersion: 2,
        ),
        const GroupSummary(
          groupId: 'Beta',
          title: '设计评审',
          memberCount: 8,
          role: 'member',
          storageConfigured: true,
        ),
      ],
    );
    String? openedId;
    String? openedTitle;

    await tester.pumpWidget(
      _wrap(
        ContactsPage(
          groups: groups,
          onOpenGroup: (String groupId, String title) {
            openedId = groupId;
            openedTitle = title;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('群聊'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupListPage), findsOneWidget);
    expect(find.text('周末爬山'), findsOneWidget);
    expect(find.text('3 人 · 管理员'), findsOneWidget);
    expect(find.text('8 人 · 成员'), findsOneWidget);
    // 未配置群盘的群给出离线不可补提示，已配置的群不显示。
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('group-list-Alpha')));
    await tester.pumpAndSettle();

    expect(openedId, 'Alpha');
    expect(openedTitle, '周末爬山');
    expect(find.byType(GroupListPage), findsNothing);
  });

  testWidgets('群列表右上角直接建空群：只需群名，成功后回调打开新群',
      (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups();
    String? createdId;
    String? createdTitle;

    await tester.pumpWidget(
      _wrap(
        GroupListPage(
          service: groups,
          onGroupCreated: (String groupId, String title) {
            createdId = groupId;
            createdTitle = title;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 右上角创建入口存在，空态提示指向右上角。
    expect(find.byKey(const ValueKey<String>('group-list-create')), findsOneWidget);
    expect(find.text('还没有群聊，点右上角创建'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('group-list-create')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('create-group-by-name-dialog')),
      findsOneWidget,
    );
    // 轻量对话框只有群名输入框，不出现联系人勾选列表。
    expect(
      find.byKey(const ValueKey<String>('create-group-by-name-title')),
      findsOneWidget,
    );
    expect(find.byType(CheckboxListTile), findsNothing);

    // 空名被拦截。
    await tester.tap(
      find.byKey(const ValueKey<String>('create-group-by-name-confirm')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('create-group-by-name-error')),
      findsOneWidget,
    );
    expect(groups.created, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey<String>('create-group-by-name-title')),
      '新群',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('create-group-by-name-confirm')),
    );
    await tester.pumpAndSettle();

    // 以空成员建群，成功后回调打开新会话。
    expect(groups.created.length, 1);
    expect(groups.created.single.$1, '新群');
    expect(groups.created.single.$2, isEmpty);
    expect(createdId, 'Z3JvdXA');
    expect(createdTitle, '新群');
  });

  testWidgets('群列表加载失败可重试', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups()
      ..listError = '读取群列表失败'
      ..groups = <GroupSummary>[
        const GroupSummary(
          groupId: 'Alpha',
          title: '周末爬山',
          memberCount: 3,
          role: 'admin',
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupListPage(service: groups),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('读取群列表失败'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);

    groups.listError = null;
    await tester.tap(find.byKey(const ValueKey<String>('group-list-retry')));
    await tester.pumpAndSettle();

    expect(find.text('读取群列表失败'), findsNothing);
    expect(find.text('周末爬山'), findsOneWidget);
  });

  // C-05：`group.removeStorage` 经统一传输层调用并返回删除对象数。
  test('TransportGroupService.removeStorage 调用契约并解析删除数', () async {
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      expect(method, 'group.removeStorage');
      expect(params, <String, dynamic>{'group_id': 'Z3JvdXA'});
      return <String, dynamic>{'cloud_objects_deleted': 3};
    });
    final int deleted = await TransportGroupService(
      transport,
    ).removeStorage('Z3JvdXA');
    expect(deleted, 3);
    expect(transport.calls, hasLength(1));
  });

  // C-05：管理员移除群盘经二次确认后调用 removeStorage 并刷新状态。
  testWidgets('管理员移除群盘：二次确认后调用 removeStorage', (
    WidgetTester tester,
  ) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: true,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'admin-account',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('group-storage-remove')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('group-storage-remove')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('group-storage-remove-dialog')),
      findsOneWidget,
    );

    // 取消不产生调用。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(groups.storageRemoved, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('group-storage-remove')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('group-storage-remove-confirm')),
    );
    await tester.pumpAndSettle();

    expect(groups.storageRemoved, <String>['Z3JvdXA']);
  });

  // C-05：疑似主密钥被拒绝，不产生提交。
  testWidgets('群盘配置拒绝主密钥', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(
      info: const GroupInfo(
        groupId: 'Z3JvdXA',
        title: '周末爬山',
        keyVersion: 2,
        storageConfigured: false,
        members: <GroupMember>[
          GroupMember(account: 'admin-account', role: 'admin'),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '周末爬山',
          service: groups,
          selfAccount: 'admin-account',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('group-storage-config')));
    await tester.pumpAndSettle();

    for (final (String key, String value) in <(String, String)>[
      ('group-storage-endpoint', 'https://s3.example.com'),
      ('group-storage-bucket', 'nexmem'),
      ('group-storage-ak', 'AKIA1234567890'),
      ('group-storage-sk', 'secret'),
    ]) {
      await tester.enterText(find.byKey(ValueKey<String>(key)), value);
    }
    final Finder scopedCheckbox2 = find.byKey(
      const ValueKey<String>('group-storage-scoped-key-confirm'),
    );
    await tester.ensureVisible(scopedCheckbox2);
    await tester.tap(scopedCheckbox2);
    await tester.tap(find.byKey(const ValueKey<String>('group-storage-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('拒绝保存'), findsOneWidget);
    expect(groups.storageConfigs, isEmpty);
  });
}
