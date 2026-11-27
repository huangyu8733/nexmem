// P1-18 通讯录验收：A–Z 分组、QQ 式好友分组树与备注展示。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/contacts/contacts_page.dart';
import 'package:nexmem_app/features/group/group_service.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

/// 记录 `contact.setGroup` 调用的假服务。
class _GroupContacts implements ContactService {
  _GroupContacts(this.friends);

  final List<Contact> friends;
  final List<(String, String)> groupCalls = <(String, String)>[];

  @override
  Future<List<Contact>> list({int limit = 200}) async => friends;

  @override
  Future<Contact> add(String account, {String alias = ''}) async =>
      const Contact(id: 'new', name: 'new');

  @override
  Future<void> setRemark(String account, String remark) async {}

  @override
  Future<void> setGroup(String account, String group) async {
    groupCalls.add((account, group));
  }

  @override
  Future<void> setBlocked(String account, bool blocked) async {}

  @override
  Future<void> remove(String account) async {}

  @override
  Future<DeviceListResult> devices({String? peer}) async =>
      const DeviceListResult.empty();
}

/// 只实现 list 的群服务替身：左栏群列表只依赖 group.list。
class _GroupChatService implements GroupService {
  _GroupChatService(this.groups);

  final List<GroupSummary> groups;

  @override
  Future<List<GroupSummary>> list() async => groups;

  @override
  Future<String> create({required String title, required List<String> members}) =>
      throw UnimplementedError();

  @override
  Future<GroupInfo> members(String groupId) => throw UnimplementedError();

  @override
  Future<int> invite(String groupId, String account) => throw UnimplementedError();

  @override
  Future<int> remove(String groupId, String account) => throw UnimplementedError();

  @override
  Future<void> leave(String groupId) => throw UnimplementedError();

  @override
  Future<void> dissolve(String groupId) => throw UnimplementedError();

  @override
  Future<void> configureStorage(String groupId, GroupStorageConfig config) =>
      throw UnimplementedError();

  @override
  Future<int> removeStorage(String groupId) => throw UnimplementedError();

  @override
  Future<String> setAnnouncement(String groupId, String announcement) =>
      throw UnimplementedError();

  @override
  Future<bool> setAllowFriendAdd(String groupId, bool enabled) =>
      throw UnimplementedError();

  @override
  Future<String> setAlias(String groupId, String alias) =>
      throw UnimplementedError();

  @override
  Future<GroupLevels> setLevelConfig(
    String groupId, {
    required bool enabled,
    required List<GroupLevel> levels,
  }) =>
      throw UnimplementedError();

  @override
  Future<GroupMemberProfile> setMemberProfile(
    String groupId,
    String account, {
    String? nickname,
    String? levelId,
  }) =>
      throw UnimplementedError();
}

void main() {
  test('联系人按首字母分组，非字母归入 # 且排在最后', () {
    final List<(String, List<Contact>)> groups = groupContacts(<Contact>[
      const Contact(id: '3', name: '张三'),
      const Contact(id: '2', name: 'bob', note: '老鲍'),
      const Contact(id: '1', name: 'Alice'),
    ]);

    expect(groups.map(((String, List<Contact>) g) => g.$1).toList(), <String>['A', 'B', '#']);
    expect(groups[0].$2.single.name, 'Alice');
    expect(groups[1].$2.single.note, '老鲍');
    expect(groups[2].$2.single.name, '张三');
  });

  test('好友分组：默认组排在最前，其余按名称排序', () {
    final List<(String, List<Contact>)> groups = groupFriends(<Contact>[
      const Contact(id: '3', name: '张三', groupName: '同事'),
      const Contact(id: '1', name: 'Alice'),
      const Contact(id: '4', name: 'Bob', groupName: '家人'),
      const Contact(id: '2', name: 'Amy'),
    ]);

    expect(groups.map(((String, List<Contact>) g) => g.$1).toList(),
        <String>['我的好友', '同事', '家人']);
    expect(groups[0].$2.map((Contact c) => c.name).toList(),
        <String>['Alice', 'Amy']);
  });

  testWidgets('通讯录展示分组入口，点好友才展开分组列表', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        ContactsPage(
          friends: <Contact>[
            const Contact(id: '1', name: 'Alice'),
            const Contact(id: '2', name: 'bob', note: '老鲍'),
            const Contact(id: '3', name: '张三'),
          ],
        ),
      ),
    );

    expect(find.text('好友'), findsOneWidget);
    expect(find.text('群聊'), findsOneWidget);
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('contact-friends-entry')));
    await tester.pump();

    expect(find.text('我的好友（3）'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('老鲍'), findsOneWidget);
    expect(find.text('张三'), findsOneWidget);
  });

  testWidgets('点击分组内好友打开右侧聊天，点分组头可收起', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      _wrap(
        ContactsPage(
          friends: <Contact>[
            const Contact(id: '1', name: 'Alice', groupName: '同事'),
            const Contact(id: '2', name: 'Bob'),
          ],
          onOpenContactChat: (Contact contact) => opened.add(contact.name),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('contact-friends-entry')));
    await tester.pump();

    expect(find.text('我的好友（1）'), findsOneWidget);
    expect(find.text('同事（1）'), findsOneWidget);

    await tester.tap(find.text('Alice'));
    await tester.pump();
    expect(opened, <String>['Alice']);

    await tester.tap(find.byKey(const ValueKey<String>('contact-group-同事')));
    await tester.pump();
    expect(find.text('Alice'), findsNothing);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('新建分组写入内核并把选中好友移入新分组', (WidgetTester tester) async {
    final _GroupContacts service = _GroupContacts(<Contact>[
      const Contact(id: '1', name: 'Alice'),
      const Contact(id: '2', name: 'Bob'),
    ]);
    await tester.pumpWidget(
      _wrap(ContactsPage(service: service, friends: service.friends)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('contact-friends-entry')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('contact-new-group-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('new-group-name-field')),
      '同事',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('new-group-contact-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('new-group-submit')),
    );
    await tester.pumpAndSettle();

    expect(service.groupCalls, <(String, String)>[('1', '同事')]);
    expect(find.text('同事（1）'), findsOneWidget);
    expect(find.text('我的好友（1）'), findsOneWidget);
  });

  testWidgets('分组菜单重命名/删除与移动好友都写入内核', (WidgetTester tester) async {
    final _GroupContacts service = _GroupContacts(<Contact>[
      const Contact(id: '1', name: 'Alice', groupName: '同事'),
      const Contact(id: '2', name: 'Bob'),
    ]);
    await tester.pumpWidget(
      _wrap(ContactsPage(service: service, friends: service.friends)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('contact-friends-entry')));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('contact-group-menu-同事')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名分组'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-group-name-field')),
      '伙伴',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('rename-group-submit')),
    );
    await tester.pumpAndSettle();
    expect(service.groupCalls, contains(('1', '伙伴')));
    expect(find.text('伙伴（1）'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('contact-move-2')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('move-to-伙伴')));
    await tester.pumpAndSettle();
    expect(service.groupCalls, contains(('2', '伙伴')));

    await tester.tap(
      find.byKey(const ValueKey<String>('contact-group-menu-伙伴')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('delete-group-submit')));
    await tester.pumpAndSettle();
    expect(service.groupCalls, contains(('1', '')));
    expect(find.text('我的好友（2）'), findsOneWidget);
  });

  testWidgets('点群聊展开群列表，点群在右栏打开群会话', (WidgetTester tester) async {
    final _GroupChatService service = _GroupChatService(<GroupSummary>[
      const GroupSummary(
        groupId: 'g1',
        title: '项目组',
        memberCount: 3,
        role: 'admin',
      ),
    ]);
    final List<(String, String)> opened = <(String, String)>[];
    await tester.pumpWidget(
      _wrap(
        ContactsPage(
          groups: service,
          onOpenPane: (String pane, {Object? data}) {},
          onOpenGroup: (String groupId, String title) =>
              opened.add((groupId, title)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('项目组'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('contact-groups-entry')));
    await tester.pumpAndSettle();

    expect(find.text('项目组'), findsOneWidget);
    expect(find.text('3 人 · 管理员'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('contact-group-chat-g1')),
    );
    await tester.pumpAndSettle();
    expect(opened, <(String, String)>[('g1', '项目组')]);
  });

  testWidgets('分组入口图标与文字在行内垂直居中', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const ContactsPage(friends: <Contact>[]),
      ),
    );

    final Finder row = find.byKey(const ValueKey<String>('contact-friends-entry'));
    final Rect rowRect = tester.getRect(row);
    final Rect iconRect = tester.getRect(
      find.descendant(of: row, matching: find.byIcon(Icons.person_outline)),
    );
    final Rect textRect = tester.getRect(
      find.descendant(of: row, matching: find.text('好友')),
    );

    expect((iconRect.center.dy - rowRect.center.dy).abs(), lessThanOrEqualTo(1));
    expect((textRect.center.dy - rowRect.center.dy).abs(), lessThanOrEqualTo(1));
  });
}
