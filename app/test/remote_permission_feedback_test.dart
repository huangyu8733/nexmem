// 远控设置页「检查权限 / 前往授权」必须有可见反馈，不能点了像没反应。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/remote/input/desktop_input_injector.dart';
import 'package:nexmem_app/features/remote/remote_input_codec.dart';
import 'package:nexmem_app/features/remote/remote_password.dart';
import 'package:nexmem_app/features/remote/remote_prefs.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/features/remote/remote_settings_page.dart';
import 'package:nexmem_app/features/remote/remote_storage_stub.dart';

class _FakeInjector implements DesktopInputInjector {
  _FakeInjector({this.checkResult = InputPermissionStatus.unsupported});

  final InputPermissionStatus checkResult;
  int checkCalls = 0;
  int requestCalls = 0;

  @override
  bool get supportsInput => false;

  @override
  String get permissionHint => '测试注入器';

  @override
  Future<InputPermissionStatus> checkPermissions() async {
    checkCalls++;
    return checkResult;
  }

  @override
  Future<InputPermissionStatus> requestPermissions() async {
    requestCalls++;
    return InputPermissionStatus.granted;
  }

  @override
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  }) async {}

  @override
  Future<void> key(String key, {required bool down, int modifiers = 0}) async {}

  @override
  Future<void> text(String text) async {}

  @override
  Future<void> dispose() async {}
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('检查权限按钮点击后给出 SnackBar 反馈（即使状态未变化）', (
    WidgetTester tester,
  ) async {
    final _FakeInjector injector = _FakeInjector(
      checkResult: InputPermissionStatus.unsupported,
    );
    await tester.pumpWidget(
      _wrap(
        RemoteSettingsPage(
          embedded: false,
          injectorFactory: () => injector,
          storageFactory: MemoryRemoteStorage.new,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('检查权限', skipOffstage: false), findsOneWidget);
    // _load() 初始化时已调用一次，点击应再增加一次。
    final int callsBeforeTap = injector.checkCalls;
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('remote-check-permission'), skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('remote-check-permission'), skipOffstage: false));
    // SnackBar 的消失依赖真实计时器，用固定帧推进而非 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(injector.checkCalls, callsBeforeTap + 1);
    // 关键：不支持注入的平台状态没变化，但仍必须有结果提示。
    expect(find.textContaining('权限检查完成'), findsWidgets);
  });

  testWidgets('前往授权按钮点击后给出 SnackBar 反馈并刷新状态', (
    WidgetTester tester,
  ) async {
    final _FakeInjector injector = _FakeInjector();
    await tester.pumpWidget(
      _wrap(
        RemoteSettingsPage(
          embedded: false,
          injectorFactory: () => injector,
          storageFactory: MemoryRemoteStorage.new,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('remote-request-permission'), skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('remote-request-permission'), skipOffstage: false),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(injector.requestCalls, 1);
    expect(find.textContaining('授权请求已处理'), findsWidgets);
    expect(find.textContaining('已授权'), findsWidgets);
  });

  testWidgets('开启被远程控制前必须设置密码', (WidgetTester tester) async {
    // hostSupported 依赖当前平台；必须在测试体内恢复，避免 invariant 检查时仍未复位。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
    RemotePrefs.instance
      ..loaded = false
      ..enabled = false
      ..passwordCredential = ''
      ..requireConfirm = true
      ..allowInput = true
      ..allowClipboard = true
      ..allowFile = true;
    final MemoryRemoteStorage storage = MemoryRemoteStorage();

    await tester.pumpWidget(
      _wrap(
        RemoteSettingsPage(
          embedded: false,
          injectorFactory: () => _FakeInjector(),
          storageFactory: () => storage,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('remote-password-change')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('remote-enabled')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('remote-enabled')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('remote-password-input')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('remote-password-confirm')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-password-input')),
      '12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-password-confirm')),
      '12345',
    );
    await tester.tap(find.byKey(const ValueKey<String>('remote-password-submit')));
    await tester.pumpAndSettle();
    expect(find.text('远程控制密码至少 6 位'), findsOneWidget);
    expect(RemotePrefs.instance.enabled, isFalse);

    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-password-input')),
      '123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-password-confirm')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey<String>('remote-password-submit')));
    await tester.pumpAndSettle();

    expect(RemotePrefs.instance.enabled, isTrue);
    expect(
      RemotePrefs.instance.passwordCredential,
      remotePasswordCredential('123456'),
    );
    final Map<String, dynamic>? saved = await storage.readJson('prefs.json');
    expect(saved?['password_credential'], remotePasswordCredential('123456'));
    expect(saved.toString(), isNot(contains('123456')));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
