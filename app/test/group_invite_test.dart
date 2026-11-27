// 群「拉人进群」验收：好友多选 / 指定账号 / 批量导入 `账号|备注`。
// 备注写入本群称呼，复用 group.invite + group.setMemberProfile 契约。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/group/group_info_page.dart';
import 'package:nexmem_app/features/group/group_invite_dialogs.dart';
import 'package:nexmem_app/features/group/group_service.dart';
import 'package:nexmem_app/transport/transport.dart';

String _hex(int n) => n.toRadixString(16).padLeft(2, '0');
String _account(int seed) =>
    List<int>.generate(32, (int i) => (seed + i * 7) % 256).map(_hex).join();

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
  const _FakeContacts(this.contacts);

  final List<Contact> contacts;

  @override
  Future<List<Contact>> list({int limit = 200}) async => contacts;

  @override
  Future<Contact> add(String account, {String alias = ''}) async =>
      throw UnimplementedError();

  @override
  Future<void> setRemark(String account, String remark) async {}

  @override
  Future<void> setGroup(String account, String group) async {}

  @override
  Future<void> setBlocked(String account, bool blocked) async {}

  @override
  Future<void> remove(String account) async {}

  @override
  Future<DeviceListResult> devices({String? peer}) async =>
      const DeviceListResult(items: <DeviceInfo>[], found: true, self: true);
}

class _FakeGroups implements GroupService {
  _FakeGroups(this.info);

  GroupInfo info;
  final List<String> invited = <String>[];
  final List<(String, String?)> nicknames = <(String, String?)>[];
  final Set<String> inviteFailures = <String>{};
  int inviteCalls = 0;

  @override
  Future<String> create({
    required String title,
    required List<String> members,
  }) async =>
      'g';

  @override
  Future<List<GroupSummary>> list() async => <GroupSummary>[];

  @override
  Future<GroupInfo> members(String groupId) async => info;

  @override
  Future<int> invite(String groupId, String account) async {
    inviteCalls++;
    if (inviteFailures.contains(account)) {
      throw const NexmemException('PEER_UNREACHABLE', '地址不可达');
    }
    invited.add(account);
    final GroupInfo current = info;
    info = GroupInfo(
      groupId: current.groupId,
      title: current.title,
      keyVersion: current.keyVersion,
      storageConfigured: current.storageConfigured,
      members: <GroupMember>[
        ...current.members,
        GroupMember(
          account: normalizeAccountHex(account),
          role: 'member',
        ),
      ],
    );
    return current.keyVersion;
  }

  @override
  Future<int> remove(String groupId, String account) async => 1;

  @override
  Future<void> leave(String groupId) async {}

  @override
  Future<void> dissolve(String groupId) async {}

  @override
  Future<void> configureStorage(
    String groupId,
    GroupStorageConfig config,
  ) async {}

  @override
  Future<int> removeStorage(String groupId) async => 0;

  @override
  Future<String> setAnnouncement(String groupId, String text) async => text;

  @override
  Future<bool> setAllowFriendAdd(String groupId, bool enabled) async => enabled;

  @override
  Future<String> setAlias(String groupId, String alias) async => alias;

  @override
  Future<GroupLevels> setLevelConfig(
    String groupId, {
    required bool enabled,
    required List<GroupLevel> levels,
  }) async =>
      GroupLevels(enabled: enabled, items: levels);

  @override
  Future<GroupMemberProfile> setMemberProfile(
    String groupId,
    String account, {
    String? nickname,
    String? levelId,
  }) async {
    nicknames.add((normalizeAccountHex(account), nickname));
    info = GroupInfo(
      groupId: info.groupId,
      title: info.title,
      keyVersion: info.keyVersion,
      storageConfigured: info.storageConfigured,
      members: <GroupMember>[
        for (final GroupMember m in info.members)
          if (m.account == normalizeAccountHex(account))
            m.copyWith(nickname: nickname ?? m.nickname)
          else
            m,
      ],
    );
    return GroupMemberProfile(account: account, nickname: nickname ?? '');
  }
}

Widget _page(_FakeGroups groups, _FakeContacts contacts) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: GroupInfoPage(
      groupId: 'Z3JvdXA',
      title: '测试群',
      service: groups,
      selfAccount: 'admin-account',
      contacts: contacts,
    ),
  );
}

void main() {
  group('parseGroupInviteBatch', () {
    test('解析一行一个账号与 账号|备注，忽略空行和注释', () {
      final String a = _account(1);
      final String b = _account(2);
      final String c = _account(3);
      final GroupInviteParseResult result = parseGroupInviteBatch(
        '# 一行一个账号\n'
        '$a|张三\n'
        '\n'
        '  $b | 李四  \n'
        '$c\n',
      );
      expect(result.invalidLines, isEmpty);
      expect(result.duplicates, 0);
      expect(result.entries, hasLength(3));
      expect(result.entries[0].account, a);
      expect(result.entries[0].nickname, '张三');
      expect(result.entries[1].account, b);
      expect(result.entries[1].nickname, '李四');
      expect(result.entries[2].nickname, '');
    });

    test('接受 base64url 账号，按规范化账号去重保留首条', () {
      final String a = _account(10);
      final String b64 = base64Url
          .encode(List<int>.generate(32, (int i) => 20 + i))
          .replaceAll('=', '');
      final GroupInviteParseResult result = parseGroupInviteBatch(
        '$a|首条\n$b64|重复\n',
      );
      // a 与 b64 是不同账号，不应去重。
      expect(result.entries, hasLength(2));
      expect(result.entries.last.nickname, '重复');
      expect(result.duplicates, 0);

      final GroupInviteParseResult dup = parseGroupInviteBatch(
        '$a|首条\n${a.toUpperCase()}|第二条\n',
      );
      expect(dup.entries, hasLength(1));
      expect(dup.entries.single.nickname, '首条');
      expect(dup.duplicates, 1);
    });

    test('非法账号计入无效行，超长备注截断到 24 字', () {
      final String a = _account(30);
      final GroupInviteParseResult result = parseGroupInviteBatch(
        'not-an-account|坏账号\n$a|${'备' * 30}\n',
      );
      expect(result.invalidLines, <String>['not-an-account|坏账号']);
      expect(result.entries, hasLength(1));
      expect(result.entries.single.nickname.runes.length, 24);
    });

    test('空文本返回空结果', () {
      final GroupInviteParseResult result = parseGroupInviteBatch('  \n\n');
      expect(result.entries, isEmpty);
      expect(result.invalidLines, isEmpty);
    });
  });

  group('拉人进群弹窗', () {
    testWidgets('两个来源Partition切换，好友多选与批量导入合并去重', (
      WidgetTester tester,
    ) async {
      final String a = _account(40);
      final String b = _account(41);
      final _FakeGroups groups = _FakeGroups(
        GroupInfo(
          groupId: 'Z3JvdXA',
          title: '测试群',
          keyVersion: 1,
          storageConfigured: false,
          members: <GroupMember>[
            GroupMember(account: 'admin-account', role: 'admin'),
          ],
        ),
      );
      final _FakeContacts contacts = _FakeContacts(<Contact>[
        Contact(id: a, name: '好友甲', peer: a),
      ]);

      await tester.pumpWidget(_page(groups, contacts));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('group-invite-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('group-invite-dialog')), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('group-invite-contact-$a')),
        findsOneWidget,
      );
      // 勾选好友。
      await tester.tap(find.byKey(ValueKey<String>('group-invite-contact-$a')));
      await tester.pumpAndSettle();
      expect(find.text('待邀请 1 人'), findsOneWidget);

      // 切到批量导入，输入两个账号：一个与好友重复，一个新账号带备注。
      await tester.tap(
        find.byKey(const ValueKey<String>('group-invite-tab-batch')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('group-invite-batch-field')),
        '$a|重复好友\n$b|新成员',
      );
      await tester.pumpAndSettle();
      expect(find.text('待邀请 2 人'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('group-invite-batch-summary')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('group-invite-confirm')),
      );
      await tester.pumpAndSettle();

      // 好友甲（备注名作为称呼）+ 新成员（备注作为称呼），重复账号只邀请一次。
      expect(groups.inviteCalls, 2);
      expect(groups.invited, contains(a));
      expect(groups.invited, contains(b));
      expect(groups.nicknames, contains((a, '好友甲')));
      expect(groups.nicknames, contains((b, '新成员')));
    });

    testWidgets('批量邀请单项失败不影响其余账号', (
      WidgetTester tester,
    ) async {
      final String a = _account(50);
      final String b = _account(51);
      final String c = _account(52);
      final _FakeGroups groups = _FakeGroups(
        GroupInfo(
          groupId: 'Z3JvdXA',
          title: '测试群',
          keyVersion: 1,
          storageConfigured: false,
          members: <GroupMember>[
            GroupMember(account: 'admin-account', role: 'admin'),
          ],
        ),
      );
      groups.inviteFailures.add(b);
      final _FakeContacts contacts = _FakeContacts(<Contact>[]);

      await tester.pumpWidget(_page(groups, contacts));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('group-invite-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('group-invite-tab-batch')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('group-invite-batch-field')),
        '$a|甲\n$b|乙\n$c|丙',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('group-invite-confirm')),
      );
      await tester.pumpAndSettle();

      expect(groups.inviteCalls, 3);
      expect(groups.invited, <String>[a, c]);
      // 失败账号不写称呼，其余两个写入。
      expect(groups.nicknames, <(String, String?)>[
        (a, '甲'),
        (c, '丙'),
      ]);
    });

    testWidgets('TransportGroupService.invite 与 setMemberProfile 契约映射', (
      WidgetTester tester,
    ) async {
      final String a = _account(60);
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        if (method == 'group.invite') {
          expect(params?['group_id'], 'Z3JvdXA');
          expect(params?['account'], a);
          return <String, dynamic>{
            'group_id': 'Z3JvdXA',
            'key_version': 2,
            'failed': 0,
          };
        }
        expect(method, 'group.setMemberProfile');
        expect(params?['nickname'], '张三');
        expect(params?.containsKey('level_id'), isFalse);
        return <String, dynamic>{
          'account': a,
          'nickname': '张三',
          'level_id': '',
        };
      });
      final TransportGroupService service = TransportGroupService(transport);
      final int version = await service.invite('Z3JvdXA', a);
      expect(version, 2);
      await service.setMemberProfile('Z3JvdXA', a, nickname: '张三');
      expect(transport.calls.map((dynamic c) => c.$1).toList(), <String>[
        'group.invite',
        'group.setMemberProfile',
      ]);
    });
  });
}
