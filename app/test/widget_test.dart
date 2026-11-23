// 导航壳验收：720px 断点前后布局切换（开发进度文档 P1-17）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/connection_status.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/transport/transport.dart';

/// 提供 account.me / settings.get / conversation.list 的最小内核替身。
class _ProfileTransport implements CoreTransport {
  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int lastSeq = 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    switch (method) {
      case 'account.me':
        return <String, dynamic>{
          'account_id': 'a' * 64,
          'device_id': 'b' * 64,
          'display_name': '小艾',
        };
      case 'settings.get':
        return <String, dynamic>{'key': params?['key'], 'value': '', 'found': false};
      case 'conversation.list':
        return <String, dynamic>{'items': <dynamic>[]};
      case 'core.info':
        return <String, dynamic>{
          'api_version': '1',
          'core_version': 'test',
          'features': <String>[],
        };
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<void> close() async {}
}

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const NexmemApp());
  await tester.pumpAndSettle();
}

Future<void> _pumpWithSessionAt(
  WidgetTester tester,
  Size size,
  CoreSession session,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(NexmemApp(session: session));
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

  testWidgets('桌面点击「我的」时右栏展示个人详情而非空占位',
      (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(1280, 800),
      CoreSession(_ProfileTransport()),
    );

    // 初始在消息栏：右栏是聊天空占位。
    expect(find.text('选择一个会话开始聊天'), findsOneWidget);
    expect(find.text('个人推广信息'), findsNothing);

    // 通过左栏导航按钮（tooltip「我的」）切换到设置区。
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    // 右栏不再空着，改为个人资料面板；中栏仍显示设置项。
    expect(find.text('选择一个会话开始聊天'), findsNothing);
    expect(find.text('个人资料'), findsWidgets);
    expect(find.text('个人介绍'), findsWidgets);
    expect(find.text('个人推广信息'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-save')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-display-name')), findsOneWidget);
    expect(find.text('小艾'), findsWidgets);
  });
}
