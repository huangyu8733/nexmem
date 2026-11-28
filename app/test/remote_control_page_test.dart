// 远控控制端页面：多设备会话切换与键盘功能键。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/remote/remote_control_page.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/features/remote/remote_video_view.dart';

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

  testWidgets('远控画面避开顶栏和底栏，只占可操作区域', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: RemoteControlPage(info: _info())));

    final Rect video = tester.getRect(find.byType(RemoteVideoView));
    expect(video.top, greaterThanOrEqualTo(50));
    expect(video.bottom, lessThanOrEqualTo(600 - 50));
  });

  testWidgets('点击远程画面后收起虚拟键盘', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: RemoteControlPage(info: _info())));

    await tester.tap(find.byKey(const ValueKey<String>('remote-keyboard')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('remote-text-field')),
      findsOneWidget,
    );

    // 画面中央不属于键盘区域，点击后应收起键盘。
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('remote-text-field')),
      findsNothing,
    );
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

  testWidgets('虚拟键盘使用 ASCII 标签避免 iOS 字体缺字方框', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: RemoteControlPage(info: _info())));

    await tester.tap(find.byKey(const ValueKey<String>('remote-keyboard')));
    await tester.pumpAndSettle();

    for (final String label in <String>['Back', 'Left', 'Up', 'Down', 'Right']) {
      expect(find.text(label), findsOneWidget, reason: '$label 应可见');
    }
    expect(find.text('⌫'), findsNothing);
    expect(find.text('←'), findsNothing);
    expect(find.text('↑'), findsNothing);
    expect(find.text('↓'), findsNothing);
    expect(find.text('→'), findsNothing);
  });

  testWidgets('键盘栏提供修饰键锁存与常见组合键按钮', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: RemoteControlPage(info: _info())));

    await tester.tap(find.byKey(const ValueKey<String>('remote-keyboard')));
    await tester.pump();

    // 修饰键锁存按钮存在。
    expect(
      find.byKey(const ValueKey<String>('remote-mod-Ctrl')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-mod-Shift')),
      findsOneWidget,
    );
    // 常见组合键快捷按钮存在（复制 = Ctrl+C）。
    expect(
      find.byKey(const ValueKey<String>('remote-combo-c-2')),
      findsOneWidget,
    );
    // 扩展功能键存在。
    expect(
      find.byKey(const ValueKey<String>('remote-key-insert')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-key-contextMenu')),
      findsOneWidget,
    );

    // 点击修饰键可切换锁存态（按钮背景色变化）。
    final Finder ctrl = find.byKey(const ValueKey<String>('remote-mod-Ctrl'));
    final DecoratedBox before = tester.widget<DecoratedBox>(
      find.descendant(of: ctrl, matching: find.byType(DecoratedBox)),
    );
    await tester.tap(ctrl);
    await tester.pump();
    final DecoratedBox after = tester.widget<DecoratedBox>(
      find.descendant(of: ctrl, matching: find.byType(DecoratedBox)),
    );
    expect(before.decoration, isNot(after.decoration));
  });

  testWidgets('控制端可切换触屏模式与鼠标模式', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: RemoteControlPage(info: _info())));

    const Key toggle = ValueKey<String>('remote-touch-mode');
    expect(find.byKey(toggle), findsOneWidget);
    final bool initialTouch = find.text('触屏模式').evaluate().isNotEmpty;
    expect(find.text(initialTouch ? '触屏模式' : '鼠标模式'), findsOneWidget);

    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    expect(find.text(initialTouch ? '鼠标模式' : '触屏模式'), findsOneWidget);
  });

  testWidgets('仅查看会话在顶部标注权限状态', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RemoteControlPage(info: _info(permissions: RemotePermissions.none)),
    ));
    expect(find.textContaining('仅查看'), findsOneWidget);
  });
}
