// 导航壳验收：720px 断点前后布局切换（开发进度文档 P1-17）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/connection_status.dart';

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const NexmemApp());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('移动端宽度使用底部三 Tab', (WidgetTester tester) async {
    await _pumpAt(tester, const Size(390, 844));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(ConnectionStatusBar), findsOneWidget);
    expect(find.text('暂无会话，点击 + 发起聊天'), findsOneWidget);
  });

  testWidgets('桌面宽度切换为三栏布局', (WidgetTester tester) async {
    await _pumpAt(tester, const Size(1280, 800));

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('选择一个会话开始聊天'), findsOneWidget);
    expect(find.text('消息'), findsWidgets);
  });

  testWidgets('第 719px 仍为移动布局，720px 切换为三栏', (WidgetTester tester) async {
    await _pumpAt(tester, const Size(719, 800));
    expect(find.byType(NavigationBar), findsOneWidget);

    await _pumpAt(tester, const Size(720, 800));
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('移动端切换 Tab 后页面保持挂载', (WidgetTester tester) async {
    await _pumpAt(tester, const Size(390, 844));

    await tester.tap(find.text('联系人'));
    await tester.pumpAndSettle();
    expect(find.byType(IndexedStack), findsOneWidget);
    expect(find.text('好友'), findsOneWidget);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('账号与安全'), findsOneWidget);
  });
}
