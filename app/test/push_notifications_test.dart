// 消息通知：控制器注册/注销、权限降级、通知点击跳转与设置面板。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/push/push_controller.dart';
import 'package:nexmem_app/features/push/push_platform.dart';
import 'package:nexmem_app/features/push/push_settings_dialog.dart';
import 'package:nexmem_app/features/settings/push.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';

class _FakeSettings implements SettingsService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (value.isEmpty) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<SettingsSnapshot> exportSnapshot() async =>
      SettingsSnapshot(snapshot: 'settings://v1/', count: 0);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async => 0;
}

class _FakePush implements PushService {
  final List<String> registered = <String>[];
  final List<String> unregistered = <String>[];

  @override
  Future<int> register(String token, {PushEnvironment env = PushEnvironment.production}) async {
    registered.add('$token|$env');
    return 1;
  }

  @override
  Future<bool> unregister(String token, {PushEnvironment env = PushEnvironment.production}) async {
    unregistered.add(token);
    return true;
  }
}

class _FakePlatform implements PushPlatform {
  _FakePlatform({this.capability = PushCapability.system, this.granted = true, this.token});

  @override
  PushCapability capability;
  bool granted;
  PushToken? token;

  final StreamController<PushOpenTarget> _open =
      StreamController<PushOpenTarget>.broadcast();
  int credentialReloads = 0;

  @override
  Future<void> refreshCredentials() async => credentialReloads++;

  final List<PushNotice> shown = <PushNotice>[];
  final List<String> cleared = <String>[];

  @override
  bool get supported => capability != PushCapability.unsupported;

  @override
  Future<PushPermission> permission() async =>
      PushPermission(granted ? 'granted' : 'denied');

  @override
  Future<PushPermission> requestPermission() async => await permission();

  @override
  Future<PushToken?> getToken() async => token;

  @override
  Stream<PushOpenTarget> get onOpen => _open.stream;

  @override
  Future<void> show(PushNotice notice) async => shown.add(notice);

  @override
  Future<void> clear(String conversationId) async => cleared.add(conversationId);

  @override
  void dispose() => unawaited(_open.close());
}

void main() {
  testWidgets('开启通知后取令牌并上报，关闭时注销', (WidgetTester tester) async {
    final _FakeSettings settings = _FakeSettings();
    final _FakePush push = _FakePush();
    final _FakePlatform platform = _FakePlatform(
      token: const PushToken(token: 'tok123', platform: 'fcm', env: 'production'),
    );
    final PushController controller = PushController(
      platform: platform,
      settings: settings,
      pushService: push,
    );
    addTearDown(controller.dispose);

    await controller.setEnabled(true);
    expect(push.registered, <String>['fcm:tok123|PushEnvironment.production']);
    expect(settings.values[kPushEnabledSettingKey], 'true');

    await controller.setEnabled(false);
    expect(push.unregistered, <String>['fcm:tok123']);
    expect(settings.values[kPushEnabledSettingKey], isNull);
  });

  testWidgets('权限被拒绝时不注册令牌', (WidgetTester tester) async {
    final _FakePush push = _FakePush();
    final _FakePlatform platform = _FakePlatform(granted: false);
    final PushController controller = PushController(
      platform: platform,
      settings: _FakeSettings(),
      pushService: push,
      // ignore: avoid_returning_null_for_void
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    expect(push.registered, isEmpty);
    expect(controller.error, contains('系统设置'));
  });

  testWidgets('平台未接线时优雅降级，不抛异常', (WidgetTester tester) async {
    final PushController controller = PushController(
      platform: _FakePlatform(capability: PushCapability.unsupported),
      settings: _FakeSettings(),
      pushService: _FakePush(),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    expect(controller.supported, isFalse);
    expect(controller.error, contains('不支持'));
  });

  testWidgets('当前会话收到消息不弹通知，其他会话才弹', (WidgetTester tester) async {
    final _FakeSettings settings = _FakeSettings();
    await settings.write(kPushEnabledSettingKey, 'true');
    final _FakePlatform platform = _FakePlatform(
      token: const PushToken(token: 'tok', platform: 'apns', env: 'production'),
    );
    final PushController controller = PushController(
      platform: platform,
      settings: settings,
      pushService: _FakePush(),
    );
    addTearDown(controller.dispose);
    await controller.refresh();

    controller.activeConversationId = 'dm:me|a';
    await controller.onIncomingMessage(
      conversationId: 'dm:me|a', title: 'A', body: '新消息');
    expect(platform.shown, isEmpty);

    await controller.onIncomingMessage(
      conversationId: 'group:g1', title: '群', body: '新消息');
    expect(platform.shown.length, 1);
    expect(platform.shown.first.conversationId, 'group:g1');
  });

  testWidgets('通知点击回调携带会话 ID', (WidgetTester tester) async {
    final _FakePlatform platform = _FakePlatform();
    final Completer<String> opened = Completer<String>();
    final PushController controller = PushController(
      platform: platform,
      settings: _FakeSettings(),
      onOpenConversation: opened.complete,
    );
    addTearDown(controller.dispose);
    platform._open.add(const PushOpenTarget('dm:me|b'));
    expect(await opened.future.timeout(const Duration(seconds: 2)), 'dm:me|b');
  });

  testWidgets('设置面板展示开关与说明，可切换', (WidgetTester tester) async {
    final _FakePush push = _FakePush();
    final _FakePlatform platform = _FakePlatform(
      token: const PushToken(token: 'tok', platform: 'web', env: 'production'),
    );
    final PushController controller = PushController(
      platform: platform,
      settings: _FakeSettings(),
      pushService: push,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PushSettingsPane(controller: controller)),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('push-enabled')), findsOneWidget);
    expect(find.text('消息通知'), findsOneWidget);
    expect(find.textContaining('不携带正文'), findsOneWidget);
    expect(find.textContaining('系统推送').evaluate().isNotEmpty ||
        find.textContaining('浏览器通知').evaluate().isNotEmpty, isTrue);
  });
}
