// 权限中心与权限管理面板测试。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/permissions/app_permissions.dart';
import 'package:nexmem_app/features/permissions/app_permissions_io.dart';
import 'package:nexmem_app/features/permissions/permissions_pane.dart';

class _FakePermissions implements AppPermissions {
  _FakePermissions(this.states);

  final Map<AppPermissionKind, AppPermissionState> states;
  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<AppPermissionState> status(AppPermissionKind kind) async =>
      states[kind] ?? AppPermissionState.unsupported;

  @override
  Future<AppPermissionState> request(AppPermissionKind kind) async {
    requests++;
    states[kind] = AppPermissionState.granted;
    return AppPermissionState.granted;
  }

  @override
  Future<bool> openSettings(AppPermissionKind kind) async {
    settingsOpened++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('权限类型', () {
    test('枚举与线格式互转', () {
      expect(AppPermissionKind.fromWire('camera'), AppPermissionKind.camera);
      expect(AppPermissionKind.fromWire('unknown'), isNull);
      expect(AppPermissionState.fromWire('permanently_denied'),
          AppPermissionState.permanentlyDenied);
      expect(AppPermissionState.permanentlyDenied.wire, 'permanently_denied');
      expect(AppPermissionState.prompt.canRequest, isTrue);
      expect(AppPermissionState.granted.canRequest, isFalse);
    });
  });

  group('原生权限通道', () {
    const MethodChannel channel = MethodChannel('nexmem/permissions');
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        final Map<Object?, Object?> args =
            (call.arguments as Map).cast<Object?, Object?>();
        switch (call.method) {
          case 'status':
            return args['kind'] == 'camera' ? 'granted' : 'prompt';
          case 'request':
            return 'granted';
          case 'openSettings':
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('查询、申请与跳转设置都走统一 MethodChannel', () async {
      const MethodChannelAppPermissions permissions =
          MethodChannelAppPermissions();
      expect(await permissions.status(AppPermissionKind.camera),
          AppPermissionState.granted);
      expect(await permissions.status(AppPermissionKind.microphone),
          AppPermissionState.prompt);
      expect(await permissions.request(AppPermissionKind.notifications),
          AppPermissionState.granted);
      expect(await permissions.openSettings(AppPermissionKind.camera), isTrue);
      expect(calls.map((MethodCall c) => c.method), <String>[
        'status',
        'status',
        'request',
        'openSettings',
      ]);
      expect(
        (calls.first.arguments as Map)['kind'],
        'camera',
      );
    });

    test('宿主未实现时安全降级为 unsupported', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        throw MissingPluginException('not implemented');
      });
      const MethodChannelAppPermissions permissions =
          MethodChannelAppPermissions();
      expect(await permissions.status(AppPermissionKind.camera),
          AppPermissionState.unsupported);
      expect(await permissions.openSettings(AppPermissionKind.camera), isFalse);
    });
  });

  testWidgets('权限面板展示状态，并可申请与跳系统设置', (WidgetTester tester) async {
    final _FakePermissions permissions = _FakePermissions(
      <AppPermissionKind, AppPermissionState>{
        AppPermissionKind.camera: AppPermissionState.granted,
        AppPermissionKind.microphone: AppPermissionState.denied,
        AppPermissionKind.notifications: AppPermissionState.permanentlyDenied,
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PermissionsPane(permissions: permissions),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('权限管理'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('permission-camera')), findsOneWidget);
    expect(find.textContaining('扫码与视频通话 · 已授权'), findsOneWidget);
    expect(find.textContaining('语音与视频通话 · 已拒绝'), findsOneWidget);
    expect(find.textContaining('离线消息提醒 · 永久拒绝'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('permission-request-microphone')),
    );
    await tester.pumpAndSettle();
    expect(permissions.requests, 1);
    expect(find.textContaining('权限状态：已授权'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('permission-settings-notifications')),
    );
    await tester.pumpAndSettle();
    expect(permissions.settingsOpened, 1);
  });
}
