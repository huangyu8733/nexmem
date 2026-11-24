// 「允许群成员加好友」群设置回归：默认关闭、管理员可切换、
// 传输层正确映射 group.members 与 group.setAllowFriendAdd。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/group/group_info_page.dart';
import 'package:nexmem_app/features/group/group_service.dart';
import 'package:nexmem_app/transport/transport.dart';

String _hex(String ch) => List<String>.filled(64, ch).join();

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handler);

  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic>? params,
  )
  handler;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) =>
      handler(method, params);

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

class _FakeGroups extends UnavailableGroupService {
  _FakeGroups(this.info);

  GroupInfo info;
  final List<(String, bool)> updates = <(String, bool)>[];

  @override
  Future<GroupInfo> members(String groupId) async => info;

  @override
  Future<bool> setAllowFriendAdd(String groupId, bool enabled) async {
    updates.add((groupId, enabled));
    info = GroupInfo(
      groupId: info.groupId,
      title: info.title,
      keyVersion: info.keyVersion,
      storageConfigured: info.storageConfigured,
      announcement: info.announcement,
      alias: info.alias,
      allowFriendAdd: enabled,
      members: info.members,
    );
    return enabled;
  }
}

Widget _wrap(Widget child) => MaterialApp(
  theme: NexmemTheme.light(),
  home: Scaffold(body: SizedBox(width: 720, child: child)),
);

GroupInfo _info({required bool allowFriendAdd}) => GroupInfo(
  groupId: 'Z3JvdXA',
  title: '项目群',
  keyVersion: 2,
  storageConfigured: true,
  allowFriendAdd: allowFriendAdd,
  members: <GroupMember>[
    GroupMember(account: _hex('a'), role: 'admin'),
    GroupMember(account: _hex('b'), role: 'member'),
  ],
);

void main() {
  test('group.members 回包映射加好友开关，group.setAllowFriendAdd 提交参数', () async {
    final _FakeTransport transport = _FakeTransport((
      String method,
      Map<String, dynamic>? params,
    ) async {
      if (method == 'group.members') {
        expect(params?['group_id'], 'Z3JvdXA');
        return <String, dynamic>{
          'group_id': 'Z3JvdXA',
          'title': '项目群',
          'key_version': 2,
          'members': <dynamic>[],
          'allow_friend_add': true,
        };
      }
      expect(method, 'group.setAllowFriendAdd');
      expect(params?['group_id'], 'Z3JvdXA');
      expect(params?['enabled'], true);
      return <String, dynamic>{'enabled': true};
    });
    final TransportGroupService service = TransportGroupService(transport);

    final GroupInfo info = await service.members('Z3JvdXA');
    expect(info.allowFriendAdd, isTrue);
    expect(await service.setAllowFriendAdd('Z3JvdXA', true), isTrue);
  });

  testWidgets('新群默认关闭，管理员可在群设置中开启', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(_info(allowFriendAdd: false));
    await tester.pumpWidget(
      _wrap(
        GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '项目群',
          service: groups,
          selfAccount: _hex('a'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const Key key = ValueKey<String>('group-allow-friend-switch');
    expect(find.text('允许群成员加好友'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isFalse);
    expect(groups.updates, isEmpty);

    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();

    expect(groups.updates, <(String, bool)>[('Z3JvdXA', true)]);
    expect(tester.widget<SwitchListTile>(find.byKey(key)).value, isTrue);
  });

  testWidgets('普通成员不能切换加好友开关', (WidgetTester tester) async {
    final _FakeGroups groups = _FakeGroups(_info(allowFriendAdd: false));
    await tester.pumpWidget(
      _wrap(
        GroupInfoPage(
          groupId: 'Z3JvdXA',
          title: '项目群',
          service: groups,
          selfAccount: _hex('b'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const Key key = ValueKey<String>('group-allow-friend-switch');
    expect(tester.widget<SwitchListTile>(find.byKey(key)).onChanged, isNull);
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    expect(groups.updates, isEmpty);
  });
}
