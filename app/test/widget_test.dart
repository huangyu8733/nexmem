// 导航壳验收：720px 断点前后布局切换（开发进度文档 P1-17）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/connection_status.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/settings/settings_pane.dart';
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
  testWidgets('移动端宽度使用底部四 Tab', (WidgetTester tester) async {
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

  testWidgets('1079/1080px 宽屏断点切换列表栏宽度', (WidgetTester tester) async {
    await _pumpAt(tester, const Size(1079, 800));
    final double narrowPane =
        tester.getSize(find.byKey(const ValueKey<String>('desktop-pages'))).width;

    await _pumpAt(tester, const Size(1080, 800));
    final double widePane =
        tester.getSize(find.byKey(const ValueKey<String>('desktop-pages'))).width;

    expect(widePane, greaterThan(narrowPane));
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

    // 右栏不再空着，改为只读资料面板；中栏仍显示设置项。
    expect(find.text('选择一个会话开始聊天'), findsNothing);
    expect(find.text('个人资料'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('profile-view-name')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('profile-view-account')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('profile-view-device')),
      findsOneWidget,
    );
    expect(find.text('小艾'), findsWidgets);
    // 只读卡不含编辑输入框与保存按钮。
    expect(find.byKey(const ValueKey<String>('profile-save')), findsNothing);
  });

  testWidgets('桌面点击左栏头像时右栏展示个人详情', (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(1280, 800),
      CoreSession(_ProfileTransport()),
    );

    expect(find.text('选择一个会话开始聊天'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('rail-avatar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('rail-avatar')));
    await tester.pumpAndSettle();

    expect(find.text('选择一个会话开始聊天'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('profile-view-name')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('profile-view-account')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('profile-save')), findsNothing);
    expect(find.text('小艾'), findsWidgets);
  });

  testWidgets('桌面设置项点击在右栏展示面板而非弹框', (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(1280, 800),
      CoreSession(_ProfileTransport()),
    );
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();

    // 默认右栏是只读资料卡。
    expect(
      find.byKey(const ValueKey<String>('profile-view-name')),
      findsOneWidget,
    );

    // 点击「个人资料」菜单项后右栏切换为可编辑面板（无 Dialog）。
    await tester.tap(find.byKey(const ValueKey<String>('settings-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('profile-display-name')),
      findsOneWidget,
    );
    expect(find.text('个人介绍'), findsOneWidget);

    // 点击其它设置项右栏切到对应面板（语言）：右栏内容切换且仍是编辑面板之外。
    await tester.tap(find.byKey(const ValueKey<String>('settings-language')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('profile-save')), findsNothing);
    expect(find.text('跟随系统'), findsWidgets);
  });

  testWidgets('桌面好友与群聊点击在右栏展示而非全屏页或弹框', (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(1280, 800),
      CoreSession(_ProfileTransport()),
    );
    await tester.tap(find.byTooltip('联系人'));
    await tester.pumpAndSettle();

    // 右栏默认是好友面板。
    expect(
      find.byKey(const ValueKey<String>('pane-friends-empty')),
      findsOneWidget,
    );
    expect(find.byType(Dialog), findsNothing);

    // 点「群聊」入口：右栏切换到群聊面板，没有 push 新页面、没有弹框。
    await tester.tap(find.byKey(const ValueKey<String>('contact-groups-entry')));
    await tester.pumpAndSettle();
    expect(find.text('群聊'), findsWidgets);
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('pane-friends-empty')),
      findsNothing,
    );

    // 回到「好友」入口：右栏重新展示好友面板。
    await tester.tap(find.byKey(const ValueKey<String>('contact-friends-entry')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('pane-friends-empty')),
      findsOneWidget,
    );
  });

  testWidgets('移动端文件入口位于设置之前，打开后展示共享/传输/下载',
      (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(390, 844),
      CoreSession(_ProfileTransport()),
    );

    final NavigationBar nav = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    expect(
      nav.destinations
          .map((Widget d) => (d as NavigationDestination).label)
          .toList(),
      <String>['消息', '联系人', '文件', '我的'],
    );

    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();

    expect(find.text('发布文件夹'), findsOneWidget);
    expect(find.text('导入分享码'), findsOneWidget);
    expect(find.text('共享'), findsWidgets);
    expect(find.text('传输'), findsWidgets);
    expect(find.text('下载'), findsWidgets);
    // 文件入口已从设置页内部移除。
    expect(find.byKey(const ValueKey<String>('settings-file-hub-shortcut')),
        findsNothing);
  });

  testWidgets('窄屏内容面板使用全屏不透明页面，不再叠半透明浮层',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showPaneDialog<void>(
                  context: context,
                  builder: (BuildContext _) => const Text('面板内容'),
                ),
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(find.text('面板内容'), findsOneWidget);
    expect(find.byType(CloseButton), findsOneWidget);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.text('面板内容'), findsNothing);
  });

  testWidgets('桌面内容面板仍使用带表面色的模态对话框',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1280, 800)),
          child: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showPaneDialog<void>(
                  context: context,
                  builder: (BuildContext _) => const Text('面板内容'),
                ),
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(find.byType(CloseButton), findsNothing);
    expect(find.text('面板内容'), findsOneWidget);
  });

  testWidgets('桌面重复点击「我的」会回到资料首页，不残留设置子面板',
      (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(1280, 800),
      CoreSession(_ProfileTransport()),
    );

    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('settings-language')));
    await tester.pumpAndSettle();
    expect(find.text('语言'), findsWidgets);

    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('profile-view-name')),
      findsOneWidget,
    );
  });

  testWidgets('桌面切换到文件分区后再返回，文件页 Tab 状态保留',
      (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(1280, 800),
      CoreSession(_ProfileTransport()),
    );

    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '传输'));
    await tester.pumpAndSettle();
    TabBar bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.controller?.index, 1);

    await tester.tap(find.byTooltip('消息'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();

    bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.controller?.index, 1);
  });

  testWidgets('桌面文件图标在设置上方，文件页占用整块工作区',
      (WidgetTester tester) async {
    await _pumpWithSessionAt(
      tester,
      const Size(1280, 800),
      CoreSession(_ProfileTransport()),
    );

    expect(
      tester.getCenter(find.byTooltip('文件')).dy,
      lessThan(tester.getCenter(find.byTooltip('我的')).dy),
    );

    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();

    expect(find.text('发布文件夹'), findsOneWidget);
    expect(find.text('导入分享码'), findsOneWidget);
    expect(find.text('选择一个会话开始聊天'), findsNothing);
  });
}
