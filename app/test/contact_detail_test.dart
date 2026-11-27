// P2-06 好友资料验收：备注本地编辑、拉黑开关与发消息入口。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_detail_page.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/contacts/contacts_page.dart';
import 'package:nexmem_app/transport/transport.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: child,
  );
}

/// 记录分组写入调用的假服务；[fail] 为真时模拟内核落库失败。
class _RecordingContacts implements ContactService {
  _RecordingContacts({this.fail = false});

  final bool fail;
  final List<String> calls = <String>[];

  @override
  Future<List<Contact>> list({int limit = 200}) async => const <Contact>[];

  @override
  Future<Contact> add(String account, {String alias = ''}) async =>
      const Contact(id: 'new', name: 'new');

  @override
  Future<void> setRemark(String account, String remark) async {}

  @override
  Future<void> setGroup(String account, String group) async {
    calls.add(group);
    if (fail) {
      throw const NexmemException('DB', '落库失败');
    }
  }

  @override
  Future<void> setBlocked(String account, bool blocked) async {}

  @override
  Future<void> remove(String account) async {
    calls.add('remove:$account');
  }

  @override
  Future<DeviceListResult> devices({String? peer}) async =>
      const DeviceListResult.empty();
}

void main() {
  testWidgets('好友资料页展示账号与备注说明，保存备注回调本地更新', (WidgetTester tester) async {
    final List<Contact> changes = <Contact>[];
    await tester.pumpWidget(
      _wrap(
        ContactDetailPage(
          contact: const Contact(id: 'alice-account', name: 'Alice'),
          onChanged: changes.add,
        ),
      ),
    );

    expect(find.text('好友资料'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('alice-account'), findsOneWidget);
    expect(find.text('仅本机可见，不会发送给对方'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-remark-field')),
      '  同事小王 ',
    );
    await tester.tap(find.byKey(const ValueKey<String>('contact-note-save')));
    await tester.pump();

    expect(changes, hasLength(1));
    expect(changes.single.note, '同事小王');
    expect(changes.single.blocked, isFalse);
    // 标题优先展示备注名。
    expect(find.text('同事小王'), findsOneWidget);
  });

  testWidgets('拉黑后展示常驻提示且发消息按钮不可用', (WidgetTester tester) async {
    bool? blocked;
    int sends = 0;
    await tester.pumpWidget(
      _wrap(
        ContactDetailPage(
          contact: const Contact(id: 'bob-account', name: 'bob'),
          onChanged: (Contact c) => blocked = c.blocked,
          onSendMessage: () => sends++,
        ),
      ),
    );

    final Finder sendButton = find.byKey(const ValueKey<String>('contact-send-button'));
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNotNull);
    expect(find.text('已拉黑，双方无法互发消息'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('contact-block-switch')));
    await tester.pump();

    expect(blocked, isTrue);
    expect(find.text('已拉黑，双方无法互发消息'), findsOneWidget);
    expect(tester.widget<FilledButton>(sendButton).onPressed, isNull);
    await tester.tap(sendButton);
    await tester.pump();
    expect(sends, 0);
  });

  testWidgets('从通讯录打开好友资料，拉黑状态回写到列表', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const Scaffold(
          body: ContactsPage(
            friends: <Contact>[
              Contact(id: '1', name: 'Alice', note: '老同学'),
            ],
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('contact-friends-entry')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('contact-info-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('好友资料'), findsOneWidget);
    // 列表页仍挂载在 Navigator 栈内，备注会同时出现在列表与备注输入框。
    expect(find.text('老同学'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey<String>('contact-block-switch')));
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();

    // 返回列表后仍保留备注；再次进入资料页应看到拉黑已生效。
    expect(find.text('老同学'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('contact-info-1')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey<String>('contact-block-switch')),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('好友资料页保存分组：本地更新并回写内核，留空清除', (WidgetTester tester) async {
    final _RecordingContacts service = _RecordingContacts();
    final List<Contact> changes = <Contact>[];
    await tester.pumpWidget(
      _wrap(
        ContactDetailPage(
          contact: const Contact(id: 'alice-account', name: 'Alice'),
          service: service,
          onChanged: changes.add,
        ),
      ),
    );

    expect(find.text('仅本机可见，留空表示不分组'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-group-field')),
      '  家人  ',
    );
    await tester.tap(find.byKey(const ValueKey<String>('contact-group-save')));
    await tester.pumpAndSettle();

    expect(service.calls, <String>['家人']);
    expect(changes.isNotEmpty, isTrue);
    expect(changes.last.groupName, '家人');

    // 留空清除分组。
    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-group-field')),
      '  ',
    );
    await tester.tap(find.byKey(const ValueKey<String>('contact-group-save')));
    await tester.pumpAndSettle();

    expect(service.calls, <String>['家人', '']);
    expect(changes.last.groupName, '');
  });

  testWidgets('分组超过 32 字时拒绝写入并提示', (WidgetTester tester) async {
    final _RecordingContacts service = _RecordingContacts();
    await tester.pumpWidget(
      _wrap(
        ContactDetailPage(
          contact: const Contact(id: 'alice-account', name: 'Alice'),
          service: service,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-group-field')),
      '字' * 33,
    );
    await tester.pump();

    // 超限：计数变红且保存按钮禁用；即使绕过按钮调用也被 _saveGroup 拒绝。
    expect(find.text('33/32'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey<String>('contact-group-save')),
          )
          .onPressed,
      isNull,
    );
    expect(service.calls, isEmpty);
  });

  testWidgets('分组落库失败时回滚本地分组值', (WidgetTester tester) async {
    final _RecordingContacts service = _RecordingContacts(fail: true);
    final List<Contact> changes = <Contact>[];
    await tester.pumpWidget(
      _wrap(
        ContactDetailPage(
          contact: const Contact(
            id: 'alice-account',
            name: 'Alice',
            groupName: '原分组',
          ),
          service: service,
          onChanged: changes.add,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-group-field')),
      '新分组',
    );
    await tester.tap(find.byKey(const ValueKey<String>('contact-group-save')));
    await tester.pumpAndSettle();

    expect(service.calls, <String>['新分组']);
    // 失败后回滚：最后一次回写恢复为原分组。
    expect(changes.last.groupName, '原分组');
  });

  testWidgets('contact.list 解析 group_name 到 Contact.groupName', (WidgetTester tester) async {
    // 直接验证映射函数：分组名裁剪空白；缺失时为空。
    expect(
      contactFromJson(<String, dynamic>{
        'account_pub': 'a' * 64,
        'alias': '老王',
        'group_name': '  同事  ',
        'blocked': false,
      }).groupName,
      '同事',
    );
    expect(
      contactFromJson(<String, dynamic>{
        'account_pub': 'a' * 64,
        'alias': '老王',
      }).groupName,
      '',
    );
  });
}
