// P1-18 通讯录验收：A–Z 分组、`#` 兜底与备注展示。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contacts_page.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
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

  testWidgets('通讯录展示分组入口、字母索引与好友备注', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const ContactsPage(
          friends: <Contact>[
            Contact(id: '1', name: 'Alice'),
            Contact(id: '2', name: 'bob', note: '老鲍'),
            Contact(id: '3', name: '张三'),
          ],
        ),
      ),
    );

    expect(find.text('好友'), findsOneWidget);
    expect(find.text('群聊'), findsOneWidget);
    expect(find.text('我的设备'), findsOneWidget);

    // 字母索引：A / B / #（分组头 + 索引条，头像首字可能再占一份）。
    expect(find.text('A'), findsAtLeastNWidgets(2));
    expect(find.text('B'), findsAtLeastNWidgets(2));
    expect(find.text('#'), findsAtLeastNWidgets(2));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('老鲍'), findsOneWidget);
    expect(find.text('张三'), findsOneWidget);
  });
}
