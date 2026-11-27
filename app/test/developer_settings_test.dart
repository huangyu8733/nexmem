// 开发者配置面板：本机 KV 保存公开凭证、服务端私钥只生成配置文本。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/push/push_controller.dart';
import 'package:nexmem_app/features/push/push_platform.dart';
import 'package:nexmem_app/features/remote/device_map_page.dart';
import 'package:nexmem_app/features/settings/backup.dart';
import 'package:nexmem_app/features/settings/developer_settings.dart';
import 'package:nexmem_app/features/settings/diagnostics.dart';
import 'package:nexmem_app/features/settings/report.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';
import 'package:nexmem_app/features/settings/storage_config.dart';

class _MemorySettings implements SettingsService {
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
      SettingsSnapshot(snapshot: 'settings://v1/', count: values.length);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async => 0;
}

class _StubPlatform implements PushPlatform {
  final StreamController<PushOpenTarget> _open =
      StreamController<PushOpenTarget>.broadcast();
  int refreshCalls = 0;

  @override
  PushCapability get capability => PushCapability.browser;

  @override
  bool get supported => true;

  @override
  Future<PushPermission> permission() async => const PushPermission('granted');

  @override
  Future<PushPermission> requestPermission() async => await permission();

  @override
  Future<PushToken?> getToken() async => null;

  @override
  Stream<PushOpenTarget> get onOpen => _open.stream;

  @override
  Future<void> show(PushNotice notice) async {}

  @override
  Future<void> clear(String conversationId) async {}

  @override
  Future<void> refreshCredentials() async => refreshCalls++;

  @override
  void dispose() {
    _open.close();
  }
}

void main() {
  testWidgets('开发者面板保存地图 Key 与 VAPID 公钥，并通知推送刷新', (WidgetTester tester) async {
    final _MemorySettings settings = _MemorySettings();
    settings.values[deviceMapTencentKeySetting] = 'old-map-key';
    final _StubPlatform platform = _StubPlatform();
    final PushController push = PushController(
      platform: platform,
      settings: settings,
    );
    addTearDown(push.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeveloperPane(settings: settings, push: push),
      ),
    ));
    await tester.pumpAndSettle();

    final Finder mapField = find.byKey(const ValueKey<String>('developer-map-key'));
    expect(mapField, findsOneWidget);
    expect(find.text('old-map-key'), findsOneWidget);

    await tester.enterText(mapField, 'new-map-key');
    await tester.enterText(
      find.byKey(const ValueKey<String>('developer-vapid-public')),
      'BEl62iUYgUivxIkv69yViEuiBIa-Ib9',
    );
    await tester.tap(find.byKey(const ValueKey<String>('developer-save')));
    await tester.pumpAndSettle();

    expect(settings.values[deviceMapTencentKeySetting], 'new-map-key');
    expect(settings.values[kVapidPublicKeySetting], 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9');
    expect(platform.refreshCalls, 1);
  });

  testWidgets('服务端凭证只生成配置文本，私钥内容不进入文本', (WidgetTester tester) async {
    final _MemorySettings settings = _MemorySettings();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DeveloperPane(settings: settings)),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('developer-apns-key-id')),
      'KEY123',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('developer-apns-private')),
      '-----BEGIN PRIVATE KEY-----\nSECRET\n-----END PRIVATE KEY-----',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('developer-fcm-account')),
      '{"private_key":"SECRET"}',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('developer-generate')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('developer-generate')));
    await tester.pumpAndSettle();

    final SelectableText generated = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('developer-export-text')),
    );
    final String text = generated.data ?? '';
    expect(text, contains('NEXMEM_APNS_KEY_ID=KEY123'));
    expect(text, contains('NEXMEM_APNS_KEY=/opt/nexmem/AuthKey.p8'));
    expect(text, contains('NEXMEM_FCM_ACCOUNT=/opt/nexmem/fcm.json'));
    expect(text, isNot(contains('SECRET')));
    // 服务端私钥不应写入任何本机 KV。
    expect(settings.values, isEmpty);
  });

  testWidgets('设置页有开发者入口且可生成内嵌面板', (WidgetTester tester) async {
    String? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPage(
          settings: _MemorySettings(),
          onOpenPane: (String label) => opened = label,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('settings-developer')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('settings-developer')));
    await tester.pumpAndSettle();
    expect(opened, '开发者');

    final WidgetBuilder builder = settingsPaneBuilder(
      label: '开发者',
      settings: _MemorySettings(),
      backup: const UnavailableBackupService(),
      diagnostics: const UnavailableDiagnosticsService(),
      ping: const UnavailablePingService(),
      storage: const UnavailableStorageTestService(),
      themeMode: ThemeMode.system,
      reportSink: const UnavailableReportSink(),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: builder)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('地图与通知凭证'), findsOneWidget);
  });
}
