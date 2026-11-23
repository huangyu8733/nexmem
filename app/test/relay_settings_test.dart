// P6-20 验收：中继开关默认关闭、保存后提示重启生效、地址形态校验、设置页入口联动。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/settings/relay_settings.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';
import 'package:nexmem_app/transport/transport.dart';

const String _relayA = '/ip4/127.0.0.1/tcp/4001/p2p/12D3KooWFoo';
const String _relayB = '/ip6/::1/tcp/4002/p2p/12D3KooWBar';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

class _FakeSettings implements SettingsService {
  _FakeSettings([Map<String, String>? initial])
      : values = <String, String>{...?initial};

  final Map<String, String> values;
  final List<(String, String)> writes = <(String, String)>[];
  NexmemException? readError;
  NexmemException? writeError;

  @override
  Future<String?> read(String key) async {
    final NexmemException? error = readError;
    if (error != null) {
      throw error;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final NexmemException? error = writeError;
    if (error != null) {
      throw error;
    }
    values[key] = value;
    writes.add((key, value));
  }

  @override
  Future<SettingsSnapshot> exportSnapshot() async =>
      SettingsSnapshot(snapshot: 'settings://v1/test', count: values.length);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async =>
      dryRun ? 0 : values.length;
}

void main() {
  test('中继地址按换行/逗号拆分并去重', () {
    final List<String> addrs = parseRelayAddrs('$_relayA\r\n$_relayB,$_relayA\n\n  ');
    expect(addrs, <String>[_relayA, _relayB]);
  });

  test('非法中继地址被拦截', () {
    expect(validateRelayAddr('127.0.0.1:4001'), isNotNull);
    expect(validateRelayAddr('/ip4/127.0.0.1/tcp/4001'), isNotNull);
    expect(validateRelayAddr(_relayA), isNull);
    expect(validateRelayAddrsText('  '), '请填写至少一个中继地址');
  });

  testWidgets('中继设置回显已保存开关与地址', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings(<String, String>{
      relayEnabledSettingKey: 'true',
      relayAddrsSettingKey: '$_relayA\n$_relayB',
    });
    await tester.pumpWidget(_wrap(RelaySettingsDialog(service: service)));
    await tester.pumpAndSettle();

    final SwitchListTile toggle = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('relay-enabled')),
    );
    expect(toggle.value, isTrue);
    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('relay-addrs')),
    );
    expect(field.controller?.text, '$_relayA\n$_relayB');
  });

  testWidgets('未保存过设置时中继默认关闭', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings();
    await tester.pumpWidget(_wrap(RelaySettingsDialog(service: service)));
    await tester.pumpAndSettle();

    final SwitchListTile toggle = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('relay-enabled')),
    );
    expect(toggle.value, isFalse);
  });

  testWidgets('开启中继并保存写入开关与去重后的地址', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings();
    await tester.pumpWidget(_wrap(RelaySettingsDialog(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('relay-enabled')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('relay-addrs')),
      '$_relayA\n$_relayA\n\n$_relayB',
    );
    await tester.tap(find.byKey(const ValueKey<String>('relay-save')));
    await tester.pumpAndSettle();

    expect(service.values[relayEnabledSettingKey], 'true');
    expect(service.values[relayAddrsSettingKey], '$_relayA\n$_relayB');
    expect(find.byKey(const ValueKey<String>('relay-saved')), findsOneWidget);
    expect(find.textContaining('重启应用后生效'), findsOneWidget);
  });

  testWidgets('关闭中继仍保留地址并提示重启生效', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings(<String, String>{
      relayEnabledSettingKey: 'true',
      relayAddrsSettingKey: _relayA,
    });
    await tester.pumpWidget(_wrap(RelaySettingsDialog(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('relay-enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('relay-save')));
    await tester.pumpAndSettle();

    expect(service.values[relayEnabledSettingKey], 'false');
    expect(service.values[relayAddrsSettingKey], _relayA);
    expect(find.textContaining('已关闭中继'), findsOneWidget);
  });

  testWidgets('开启中继但地址为空时拦截保存', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings();
    await tester.pumpWidget(_wrap(RelaySettingsDialog(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('relay-enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('relay-save')));
    await tester.pumpAndSettle();

    expect(service.writes, isEmpty);
    expect(find.byKey(const ValueKey<String>('relay-error')), findsOneWidget);
    expect(find.textContaining('请填写至少一个中继地址'), findsOneWidget);
  });

  testWidgets('地址形态非法时拦截保存', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings();
    await tester.pumpWidget(_wrap(RelaySettingsDialog(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('relay-enabled')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('relay-addrs')),
      '127.0.0.1:4001',
    );
    await tester.tap(find.byKey(const ValueKey<String>('relay-save')));
    await tester.pumpAndSettle();

    expect(service.writes, isEmpty);
    expect(find.textContaining('需以 / 开头'), findsOneWidget);
  });

  testWidgets('内核未接入时保存展示 NOT_STARTED 提示', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings(<String, String>{
      relayEnabledSettingKey: 'true',
      relayAddrsSettingKey: _relayA,
    });
    service.writeError = const NexmemException('NOT_STARTED', '未启动');
    await tester.pumpWidget(_wrap(RelaySettingsDialog(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('relay-save')));
    await tester.pumpAndSettle();

    expect(find.text('中继设置尚未接入内核'), findsOneWidget);
  });

  testWidgets('设置页「网络」可进入中继设置', (WidgetTester tester) async {
    final _FakeSettings service = _FakeSettings();
    await tester.pumpWidget(_wrap(SettingsPage(settings: service)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('settings-network')));
    await tester.pumpAndSettle();

    final Finder entry = find.byKey(
      const ValueKey<String>('settings-network-relay'),
    );
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('中继设置'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('relay-enabled')), findsOneWidget);
  });
}
