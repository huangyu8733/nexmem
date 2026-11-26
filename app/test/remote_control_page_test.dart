// 远控控制端页面：多设备会话切换与键盘功能键。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/remote/remote_control_page.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';

RemoteInfo _info({RemotePermissions permissions = RemotePermissions.all}) {
  return RemoteInfo(
    sid: 'r-1',
    peer: 'p1',
    peerName: '设备 A',
    role: RemoteRole.controller,
    state: RemoteState.active,
    permissions: permissions,
  );
}

void main() {
  testWidgets('多台设备时顶栏可切换远控会话', (WidgetTester tester) async {
    String? selected;
    await tester.pumpWidget(MaterialApp(
      home: RemoteControlPage(
        info: _info(),
        sessions: const <RemoteSessionTab>[
          RemoteSessionTab(peer: 'p1', name: '设备 A', active: true),
          RemoteSessionTab(peer: 'p2', name: '设备 B', active: false),
        ],
        onSelectSession: (String peer) => selected = peer,
      ),
    ));

    expect(
      find.byKey(const ValueKey<String>('remote-sessions')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('remote-sessions')));
    await tester.pumpAndSettle();
    expect(find.text('设备 A'), findsWidgets);
    expect(find.text('设备 B'), findsWidgets);

    await tester.tap(find.text('设备 B'));
    await tester.pumpAndSettle();
    expect(selected, 'p2');
  });

  testWidgets('键盘栏提供常用功能键，无服务时禁用', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: RemoteControlPage(info: _info())));

    await tester.tap(find.byKey(const ValueKey<String>('remote-keyboard')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('remote-key-enter')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-key-backspace')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-key-arrowUp')),
      findsOneWidget,
    );
    final Finder enter = find.byKey(const ValueKey<String>('remote-key-enter'));
    final OutlinedButton button = tester.widget<OutlinedButton>(enter);
    expect(button.onPressed, isNull);
  });

  testWidgets('仅查看会话在顶部标注权限状态', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RemoteControlPage(info: _info(permissions: RemotePermissions.none)),
    ));
    expect(find.textContaining('仅查看'), findsOneWidget);
  });
}
