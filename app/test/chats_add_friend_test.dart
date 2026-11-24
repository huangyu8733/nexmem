// P6-19 验收：会话列表 `+` 菜单「添加好友」入口复用统一弹窗并刷新通讯录。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chats/chats_page.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';

class _FakeContacts implements ContactService {
  final List<(String, String)> added = <(String, String)>[];

  @override
  Future<List<Contact>> list({int limit = 200}) async => const <Contact>[];

  @override
  Future<Contact> add(String account, {String alias = ''}) async {
    added.add((account, alias));
    return const Contact(id: 'new', name: '新好友');
  }

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

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('+ 菜单：添加好友弹窗提交后回调 onContactAdded', (WidgetTester tester) async {
    final _FakeContacts contacts = _FakeContacts();
    int refreshed = 0;

    await tester.pumpWidget(
      _wrap(
        ChatsPage(
          contacts: contacts,
          onContactAdded: () => refreshed++,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('chats-add')));
    await tester.pumpAndSettle();
    expect(find.text('添加好友'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('start-chat-add-friend')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-add-account')),
      'abc123',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-add-alias')),
      '同事',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('contact-add-submit')),
    );
    await tester.pumpAndSettle();

    expect(contacts.added.single, ('abc123', '同事'));
    expect(refreshed, 1);
    expect(find.text('已添加好友'), findsOneWidget);
  });

  testWidgets('+ 菜单：空账号提交展示校验错误', (WidgetTester tester) async {
    final _FakeContacts contacts = _FakeContacts();

    await tester.pumpWidget(_wrap(ChatsPage(contacts: contacts)));

    await tester.tap(find.byKey(const ValueKey<String>('chats-add')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('start-chat-add-friend')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('contact-add-submit')),
    );
    await tester.pump();

    expect(find.text('请输入对方账号公钥'), findsOneWidget);
    expect(contacts.added, isEmpty);
  });
}
