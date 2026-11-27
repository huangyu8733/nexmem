import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/account/account_local_store.dart';
import 'package:nexmem_app/features/account/account_manager.dart';
import 'package:nexmem_app/features/account/account_manager_page.dart';
import 'package:nexmem_app/features/account/account_profile.dart';
import 'package:nexmem_app/features/account/lock_screen.dart';
import 'package:nexmem_app/transport/transport.dart';

class _UiTransport implements CoreTransport {
  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int lastSeq = 0;

  bool started = true;
  String dataDir = '/tmp/nexmem/data';

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    switch (method) {
      case 'core.dataDir':
        return <String, dynamic>{'data_dir': dataDir};
      case 'core.stop':
        started = false;
        return <String, dynamic>{};
      case 'core.start':
        started = true;
        final Object? dir = params?['config']?['data_dir'];
        if (dir is String && dir.isNotEmpty) dataDir = dir;
        return <String, dynamic>{'state': 'online'};
      case 'account.me':
        if (!started) {
          throw const NexmemException('NOT_STARTED', '内核尚未启动');
        }
        return <String, dynamic>{
          'account_id': 'a' * 64,
          'device_id': 'b' * 64,
          'display_name': '测试账号',
        };
      case 'settings.get':
        return <String, dynamic>{
          'key': params?['key'],
          'value': '',
          'found': false,
        };
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

class _Store extends AccountLocalStore {
  Map<String, dynamic>? data;

  @override
  Future<Map<String, dynamic>?> read() async => data;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    data = Map<String, dynamic>.from(value);
  }
}

Future<AccountManager> _manager() async {
  final AccountManager manager = AccountManager(
    session: CoreSession(_UiTransport()),
    store: _Store(),
  );
  await manager.initialize();
  addTearDown(manager.dispose);
  return manager;
}

void main() {
  testWidgets('我的页可进入账号管理面板', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(NexmemApp(session: CoreSession(_UiTransport())));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('settings-account-manager')));
    await tester.pumpAndSettle();

    expect(find.text('账号管理'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('account-add')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('account-logout')), findsOneWidget);
  });

  testWidgets('账号管理页可设置锁屏密码', (WidgetTester tester) async {
    final AccountManager manager = await _manager();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountManagerPage(manager: manager)),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('account-lock-setup')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('account-pin-new')),
      '1234',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('account-pin-confirm')),
      '1234',
    );
    await tester.tap(find.byKey(const ValueKey<String>('account-pin-submit')));
    await tester.pumpAndSettle();

    expect(manager.lockSettings.hasPin, isTrue);
    expect(verifyPin('1234', manager.lockSettings.pinHash), isTrue);
  });

  testWidgets('锁屏页拒绝错误 PIN，正确 PIN 可解锁', (WidgetTester tester) async {
    final AccountManager manager = await _manager();
    await manager.setPin('2580');
    await manager.lockNow();
    await tester.pumpWidget(
      MaterialApp(home: LockScreen(manager: manager)),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('lock-pin-input')),
      '1111',
    );
    await tester.tap(find.byKey(const ValueKey<String>('lock-unlock')));
    await tester.pumpAndSettle();
    expect(find.text('锁屏密码错误，请重试'), findsOneWidget);
    expect(manager.locked, isTrue);

    await tester.enterText(
      find.byKey(const ValueKey<String>('lock-pin-input')),
      '2580',
    );
    await tester.tap(find.byKey(const ValueKey<String>('lock-unlock')));
    await tester.pumpAndSettle();
    expect(manager.locked, isFalse);
  });

  testWidgets('退出登录后可从账号选择页重新进入', (WidgetTester tester) async {
    final _UiTransport transport = _UiTransport();
    final AccountManager manager = AccountManager(
      session: CoreSession(transport),
      store: _Store(),
    );
    await manager.initialize();
    addTearDown(manager.dispose);
    await manager.logout();
    await tester.pumpWidget(
      MaterialApp(
        home: AccountGate(manager: manager),
      ),
    );

    expect(transport.started, isFalse);
    await tester.tap(find.byKey(const ValueKey<String>('gate-default')));
    await tester.pumpAndSettle();
    expect(manager.activeId, 'default');
    expect(transport.started, isTrue);
  });
}
