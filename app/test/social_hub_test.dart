// 社交中心验收：只保留好友申请 / 入群申请 / 通知三个页签，
// 动态与投票功能不再出现在界面上。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/settings/settings_pane.dart';
import 'package:nexmem_app/features/social/social_hub_page.dart';
import 'package:nexmem_app/transport/transport.dart';

class _SocialTransport implements CoreTransport {
  final List<Map<String, dynamic>> friends = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> joins = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> notifs = <Map<String, dynamic>>[];
  final List<String> calls = <String>[];

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
    calls.add(method);
    switch (method) {
      case 'friend.request.list':
        return <String, dynamic>{'items': friends};
      case 'group.join.list':
        return <String, dynamic>{'items': joins};
      case 'notification.list':
        return <String, dynamic>{'items': notifs, 'unread': 0};
      case 'friend.request.delete':
        friends.removeWhere((e) => e['id'] == params?['id']);
        return <String, dynamic>{'deleted': 1};
      case 'friend.request.clear':
        final int n = friends.length;
        friends.clear();
        return <String, dynamic>{'deleted': n};
      case 'group.join.delete':
        joins.removeWhere((e) => e['id'] == params?['id']);
        return <String, dynamic>{'deleted': 1};
      case 'group.join.clear':
        final int n = joins.length;
        joins.clear();
        return <String, dynamic>{'deleted': n};
      case 'notification.delete':
        notifs.removeWhere((e) => e['id'] == params?['id']);
        return <String, dynamic>{'deleted': 1};
      case 'notification.clear':
        final int n = notifs.length;
        notifs.clear();
        return <String, dynamic>{'deleted': n};
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('社交中心只有好友申请 / 入群申请 / 通知三个页签',
      (WidgetTester tester) async {
    final CoreSession session = CoreSession(_SocialTransport());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SocialHubPage(session: session))),
    );
    await tester.pumpAndSettle();

    final TabBar bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.tabs.length, 3);
    expect(find.text('好友申请'), findsOneWidget);
    expect(find.text('入群申请'), findsOneWidget);
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('动态'), findsNothing);
    expect(find.text('投票'), findsNothing);
  });

  testWidgets('好友申请/入群申请/通知均可单条与批量删除',
      (WidgetTester tester) async {
    final _SocialTransport transport = _SocialTransport();
    transport.friends.add(<String, dynamic>{
      'id': 'f1',
      'from': 'a' * 64,
      'to': 'b' * 64,
      'message': '你好',
      'status': 0,
      'direction': 'in',
      'created_at': 1,
    });
    transport.friends.add(<String, dynamic>{
      'id': 'f2',
      'from': 'a' * 64,
      'to': 'b' * 64,
      'message': '历史',
      'status': 1,
      'direction': 'in',
      'created_at': 2,
    });
    transport.joins.add(<String, dynamic>{
      'id': 'j1',
      'group_id': 'g1',
      'group_title': '测试群',
      'applicant': 'c' * 64,
      'message': '想入群',
      'status': 0,
      'direction': 'in',
      'created_at': 1,
    });
    transport.notifs.add(<String, dynamic>{
      'id': 'n1',
      'kind': 'test',
      'title': '通知标题',
      'body': '通知内容',
      'read': false,
      'created_at': 1,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SocialHubPage(session: CoreSession(transport)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 好友申请：单条删除 + 批量清空。
    expect(find.byKey(const ValueKey<String>('friend-req-delete-f1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('friend-req-delete-f2')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('friend-req-delete-f1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('social-delete-confirm')));
    await tester.pumpAndSettle();
    expect(transport.calls, contains('friend.request.delete'));
    expect(find.byKey(const ValueKey<String>('friend-req-delete-f1')),
        findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('friend-req-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('social-delete-confirm')));
    await tester.pumpAndSettle();
    expect(transport.calls, contains('friend.request.clear'));
    expect(transport.friends, isEmpty);

    // 入群申请。
    await tester.tap(find.text('入群申请'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('join-req-delete-j1')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('join-req-delete-j1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('social-delete-confirm')));
    await tester.pumpAndSettle();
    expect(transport.calls, contains('group.join.delete'));
    expect(transport.joins, isEmpty);

    // 通知。
    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('notification-delete-n1')),
        findsOneWidget);
    transport.notifs.add(<String, dynamic>{
      'id': 'n2',
      'kind': 'test',
      'title': '另一条',
      'body': '内容',
      'read': true,
      'created_at': 2,
    });
    await tester.tap(find.byKey(const ValueKey<String>('notif-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('social-delete-confirm')));
    await tester.pumpAndSettle();
    expect(transport.calls, contains('notification.clear'));
    expect(transport.notifs, isEmpty);
  });

  testWidgets('内嵌面板里的删除确认框使用不透明实底，不继承透明主题',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _SocialTransport transport = _SocialTransport();
    transport.friends.add(<String, dynamic>{
      'id': 'f1',
      'from': 'a' * 64,
      'to': 'b' * 64,
      'message': '你好',
      'status': 1,
      'direction': 'in',
      'created_at': 1,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmbeddedSettingsPane(
            title: '社交中心',
            onDismiss: () {},
            builder: (_) => SocialHubPage(
              session: CoreSession(transport),
              showHeader: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
        find.byKey(const ValueKey<String>('friend-req-delete-f1')));
    await tester.pumpAndSettle();

    final AlertDialog dialog = tester.widget<AlertDialog>(
      find.byType(AlertDialog),
    );
    // 找不到显式颜色时回落到主题；两者都不能是透明，
    // 否则在嵌入式透明面板上会与底层列表重叠、无法阅读。
    final ThemeData theme = Theme.of(tester.element(find.byType(AlertDialog)));
    final Color background = dialog.backgroundColor ??
        theme.dialogTheme.backgroundColor ??
        theme.colorScheme.surface;
    expect(background.a, greaterThan(0));
    expect(theme.dialogTheme.elevation, greaterThan(0));
  });
}
