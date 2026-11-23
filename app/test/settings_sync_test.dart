// P6-41 验收：多设备设置同步弹窗从设置页进入，导出填充快照文本、导入合并并反馈结果，
// 非法快照与未接入内核时给出明确提示。这里只验证本地搬运闭环，不伪造实时跨端推送。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';
import 'package:nexmem_app/features/settings/settings_sync.dart';
import 'package:nexmem_app/transport/transport.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

const String _sampleSnapshot = 'settings://v1/eyJ2IjoxLCJlIjpbXSwicyI6ImFiYyJ9';

class _FakeSettings implements SettingsService {
  _FakeSettings({this.exportError, this.importError});

  final NexmemException? exportError;
  final NexmemException? importError;
  final List<String> imported = <String>[];
  int exportCalls = 0;

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<SettingsSnapshot> exportSnapshot() async {
    exportCalls++;
    if (exportError != null) {
      throw exportError!;
    }
    return const SettingsSnapshot(snapshot: _sampleSnapshot, count: 3);
  }

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async {
    if (importError != null) {
      throw importError!;
    }
    imported.add(snapshot);
    return 3;
  }
}

void main() {
  // Clipboard 在 widget 测试里是平台通道，需注入内存实现，否则 setData 抛 MissingPluginException。
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      return null;
    });
  });

  testWidgets('设置页「多设备同步」进入同步弹窗', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(SettingsPage(settings: _FakeSettings())));

    await tester.tap(find.byKey(const ValueKey<String>('settings-device-sync')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSyncDialog), findsOneWidget);
    expect(find.text('多设备设置同步'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('settings-sync-snapshot')),
      findsOneWidget,
    );
  });

  testWidgets('导出填充快照文本并反馈条目数', (WidgetTester tester) async {
    final _FakeSettings settings = _FakeSettings();
    await tester.pumpWidget(_wrap(SettingsSyncDialog(settings: settings)));

    await tester.tap(find.byKey(const ValueKey<String>('settings-sync-export')));
    await tester.pumpAndSettle();

    expect(settings.exportCalls, 1);
    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('settings-sync-snapshot')),
    );
    expect(field.controller?.text, _sampleSnapshot);
    expect(find.textContaining('已导出 3 项设置'), findsOneWidget);
  });

  testWidgets('导入合并快照并反馈应用条数', (WidgetTester tester) async {
    final _FakeSettings settings = _FakeSettings();
    await tester.pumpWidget(_wrap(SettingsSyncDialog(settings: settings)));

    await tester.enterText(
      find.byKey(const ValueKey<String>('settings-sync-snapshot')),
      _sampleSnapshot,
    );
    await tester.tap(find.byKey(const ValueKey<String>('settings-sync-import')));
    await tester.pumpAndSettle();

    expect(settings.imported, <String>[_sampleSnapshot]);
    expect(find.textContaining('已合并 3 项设置'), findsOneWidget);
  });

  testWidgets('空快照导入被拦截', (WidgetTester tester) async {
    final _FakeSettings settings = _FakeSettings();
    await tester.pumpWidget(_wrap(SettingsSyncDialog(settings: settings)));

    await tester.tap(find.byKey(const ValueKey<String>('settings-sync-import')));
    await tester.pumpAndSettle();

    expect(settings.imported, isEmpty);
    expect(find.textContaining('请先粘贴'), findsOneWidget);
  });

  testWidgets('非法快照展示校验失败提示', (WidgetTester tester) async {
    final _FakeSettings settings = _FakeSettings(
      importError: const NexmemException('INVALID_ARG', 'bad'),
    );
    await tester.pumpWidget(_wrap(SettingsSyncDialog(settings: settings)));

    await tester.enterText(
      find.byKey(const ValueKey<String>('settings-sync-snapshot')),
      'settings://v1/bad',
    );
    await tester.tap(find.byKey(const ValueKey<String>('settings-sync-import')));
    await tester.pumpAndSettle();

    expect(find.text('设置快照无效或校验失败'), findsOneWidget);
  });

  testWidgets('内核未接入时导出展示失败', (WidgetTester tester) async {
    final _FakeSettings settings = _FakeSettings(
      exportError: const NexmemException('NOT_STARTED', '未启动'),
    );
    await tester.pumpWidget(_wrap(SettingsSyncDialog(settings: settings)));

    await tester.tap(find.byKey(const ValueKey<String>('settings-sync-export')));
    await tester.pumpAndSettle();

    expect(find.textContaining('导出失败'), findsOneWidget);
  });
}
