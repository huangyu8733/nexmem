// P6-06 验收：网络诊断展示、诊断导出脱敏路径回显、举报入口与诊断包附带。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/features/chat/chat_store.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/settings/diagnostics.dart';
import 'package:nexmem_app/features/settings/profile_panel.dart';
import 'package:nexmem_app/features/settings/report.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';
import 'package:nexmem_app/transport/transport.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

class _FakeDiagnostics implements DiagnosticsService {
  _FakeDiagnostics({
    this.value,
    this.exportPath = '/tmp/nexmem-diag.jsonl',
    this.snapshotError,
    this.exportError,
  });

  final DiagnosticsSnapshot? value;
  final String exportPath;
  final NexmemException? snapshotError;
  final NexmemException? exportError;
  int exportCalls = 0;

  @override
  Future<DiagnosticsSnapshot> snapshot() async {
    if (snapshotError != null) {
      throw snapshotError!;
    }
    return value ??
        const DiagnosticsSnapshot(
          uptimeMs: 0,
          dhtLookups: 0,
          dhtErrors: 0,
          dhtP50Ms: 0,
          dhtP95Ms: 0,
        );
  }

  @override
  Future<String> exportBundle() async {
    exportCalls++;
    if (exportError != null) {
      throw exportError!;
    }
    return exportPath;
  }
}

class _FakePing implements PingService {
  _FakePing({this.result, this.error});

  final PingResult? result;
  final NexmemException? error;
  int calls = 0;

  @override
  Future<PingResult> ping() async {
    calls++;
    if (error != null) {
      throw error!;
    }
    return result ??
        const PingResult(pong: true, serverTs: 1730000000000, roundTripMs: 12);
  }
}

class _PingTransport implements CoreTransport {
  _PingTransport({this.pong = true, this.serverTs = 1730000000000});

  final bool pong;
  final int serverTs;
  final List<String> methods = <String>[];

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
    methods.add(method);
    return <String, dynamic>{'pong': pong, 'server_ts': serverTs};
  }

  @override
  Future<void> close() async {}
}

class _FakeReportSink implements ReportSink {
  final List<ReportRequest> requests = <ReportRequest>[];

  @override
  Future<void> submit(ReportRequest request) async {
    requests.add(request);
  }
}

class _RecordingTransport implements CoreTransport {
  final List<String> methods = <String>[];
  final List<Map<String, dynamic>?> params = <Map<String, dynamic>?>[];

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
    methods.add(method);
    this.params.add(params);
    return <String, dynamic>{'report_id': 'report-1'};
  }

  @override
  Future<void> close() async {}
}

class _SettingsTransport implements CoreTransport {
  final Map<String, String> stored = <String, String>{};
  final List<String> methods = <String>[];

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
    methods.add(method);
    final String key = params?['key'] as String? ?? '';
    switch (method) {
      case 'settings.get':
        final String? value = stored[key];
        return value == null
            ? <String, dynamic>{'key': key, 'value': '', 'found': false}
            : <String, dynamic>{'key': key, 'value': value, 'found': true};
      case 'settings.set':
        final String value = params?['value'] as String? ?? '';
        if (value.isEmpty) {
          stored.remove(key);
        } else {
          stored[key] = value;
        }
        return <String, dynamic>{};
      default:
        throw NexmemException('INVALID_ARG', '未知方法 $method');
    }
  }

  @override
  Future<void> close() async {}
}

class _AppThemeTransport implements CoreTransport {
  _AppThemeTransport({this.theme});

  final String? theme;
  final Map<String, String> written = <String, String>{};

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
      case 'settings.get':
        return <String, dynamic>{
          'key': params?['key'],
          'value': theme ?? '',
          'found': theme != null,
        };
      case 'settings.set':
        written[params?['key'] as String? ?? ''] =
            params?['value'] as String? ?? '';
        return <String, dynamic>{};
      case 'account.me':
        return <String, dynamic>{'account_id': 'a' * 64, 'device_id': 'b' * 64};
      case 'conversation.list':
        return <String, dynamic>{'items': <dynamic>[]};
      default:
        throw NexmemException('INVALID_ARG', '未知方法 $method');
    }
  }

  @override
  Future<void> close() async {}
}

const DiagnosticsSnapshot _sample = DiagnosticsSnapshot(
  uptimeMs: 3723000,
  dhtLookups: 12,
  dhtErrors: 1,
  dhtP50Ms: 31.5,
  dhtP95Ms: 128,
  holePunch: <String, int>{
    'quic/direct': 2,
    'tcp/direct': 1,
    'quic/relayed': 1,
  },
  s3Status: <String, int>{'PUT/200': 3, 'GET/500': 1},
  logRecords: 42,
  logDropped: 2,
);

void main() {
  test('诊断快照解析与摘要：打洞结果按结果归并，无样本有明确提示', () {
    final DiagnosticsSnapshot parsed = DiagnosticsSnapshot.fromJson(
      <String, dynamic>{
        'uptime_ms': 125000,
        'dht_lookups': 4,
        'dht_errors': 0,
        'dht_p50_ms': 12.34,
        'dht_p95_ms': 20,
        'holepunch': <String, dynamic>{
          'quic/direct': 2,
          'tcp/direct': 1,
          'quic/relayed': 1,
        },
        's3_status': <String, dynamic>{'PUT/200': 2},
        'log_records': 9,
        'log_dropped': 0,
      },
    );
    expect(parsed.uptimeText, '2m 5s');
    expect(parsed.dhtLatencyText, 'p50 12.3ms · p95 20.0ms');
    expect(parsed.directCount, 3);
    expect(parsed.relayedCount, 1);
    expect(parsed.failedCount, 0);
    expect(parsed.holePunchText, '直连 3 · 中继 1 · 失败 0');
    expect(parsed.s3Text, 'PUT/200×2');

    const DiagnosticsSnapshot empty = DiagnosticsSnapshot(
      uptimeMs: 0,
      dhtLookups: 0,
      dhtErrors: 0,
      dhtP50Ms: 0,
      dhtP95Ms: 0,
    );
    expect(empty.dhtLatencyText, '暂无样本');
    expect(empty.s3Text, '暂无请求');
  });

  testWidgets('设置页「网络」展示 DHT 耗时与打洞结果', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(SettingsPage(diagnostics: _FakeDiagnostics(value: _sample))),
    );

    await tester.tap(find.byKey(const ValueKey<String>('settings-network')));
    await tester.pumpAndSettle();

    expect(find.text('网络诊断'), findsOneWidget);
    expect(find.text('1h 2m'), findsOneWidget);
    expect(find.text('12 次 · 失败 1'), findsOneWidget);
    expect(find.text('p50 31.5ms · p95 128.0ms'), findsOneWidget);
    expect(find.text('直连 3 · 中继 1 · 失败 0'), findsOneWidget);
  });

  testWidgets('诊断能力未接入时展示 NOT_STARTED 文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        SettingsPage(
          diagnostics: _FakeDiagnostics(
            snapshotError: const NexmemException('NOT_STARTED', '未接入'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('settings-network')));
    await tester.pumpAndSettle();

    expect(find.text('诊断能力尚未接入内核'), findsOneWidget);
  });

  test('TransportPingService 调用 core.ping 并解析回包（P6-34）', () async {
    final _PingTransport transport = _PingTransport(
      pong: true,
      serverTs: 1730000000000,
    );
    final PingResult result = await TransportPingService(transport).ping();
    expect(transport.methods, <String>['core.ping']);
    expect(result.pong, isTrue);
    expect(result.serverTs, 1730000000000);
    expect(result.roundTripMs, greaterThanOrEqualTo(0));
    expect(result.summary, contains('内核正常'));
  });

  testWidgets('网络诊断「连接自检」展示往返结果（P6-34）',
      (WidgetTester tester) async {
    final _FakePing ping = _FakePing(
      result: const PingResult(
        pong: true,
        serverTs: 1730000000000,
        roundTripMs: 12,
      ),
    );
    await tester.pumpWidget(_wrap(SettingsPage(
      diagnostics: _FakeDiagnostics(value: _sample),
      ping: ping,
    )));

    await tester.tap(find.byKey(const ValueKey<String>('settings-network')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('settings-network-ping')),
        findsOneWidget);
    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();

    expect(ping.calls, 1);
    expect(find.text('内核正常 · 往返 12 ms'), findsOneWidget);
  });

  testWidgets('内核未接入时连接自检展示 NOT_STARTED 文案（P6-34）',
      (WidgetTester tester) async {
    final _FakePing ping = _FakePing(
      error: const NexmemException('NOT_STARTED', '未接入'),
    );
    await tester.pumpWidget(_wrap(SettingsPage(
      diagnostics: _FakeDiagnostics(value: _sample),
      ping: ping,
    )));

    await tester.tap(find.byKey(const ValueKey<String>('settings-network')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();

    expect(find.text('内核尚未接入，无法自检'), findsOneWidget);
  });

  testWidgets('关于页诊断导出回显落盘路径', (WidgetTester tester) async {
    final _FakeDiagnostics diagnostics = _FakeDiagnostics(
      value: _sample,
      exportPath: '/data/nexmem/diag.jsonl',
    );
    await tester.pumpWidget(_wrap(SettingsPage(diagnostics: diagnostics)));

    await tester.tap(find.byKey(const ValueKey<String>('settings-about')));
    await tester.pumpAndSettle();
    expect(find.text('版本 1.0.0'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('about-export')));
    await tester.pumpAndSettle();

    expect(diagnostics.exportCalls, 1);
    expect(find.text('诊断包已导出：/data/nexmem/diag.jsonl'), findsOneWidget);
  });

  testWidgets('关于页诊断导出失败时提示错误码', (WidgetTester tester) async {
    final _FakeDiagnostics diagnostics = _FakeDiagnostics(
      value: _sample,
      exportError: const NexmemException('IO_ERROR', '磁盘不可写'),
    );
    await tester.pumpWidget(_wrap(SettingsPage(diagnostics: diagnostics)));

    await tester.tap(find.byKey(const ValueKey<String>('settings-about')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('about-export')));
    await tester.pumpAndSettle();

    expect(find.text('诊断导出失败（IO_ERROR），请稍后再试'), findsOneWidget);
  });

  testWidgets('关于页举报入口提交原因并附带诊断包', (WidgetTester tester) async {
    final _FakeReportSink sink = _FakeReportSink();
    final _FakeDiagnostics diagnostics = _FakeDiagnostics(
      value: _sample,
      exportPath: '/data/nexmem/report-diag.jsonl',
    );
    await tester.pumpWidget(
      _wrap(SettingsPage(diagnostics: diagnostics, reportSink: sink)),
    );

    await tester.tap(find.byKey(const ValueKey<String>('settings-about')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('about-report')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('report-reason-spam')));
    await tester.enterText(
      find.byKey(const ValueKey<String>('report-detail-field')),
      '重复广告',
    );
    await tester.tap(find.byKey(const ValueKey<String>('report-submit')));
    await tester.pumpAndSettle();

    expect(sink.requests, hasLength(1));
    expect(sink.requests.single.reason, ReportReason.spam);
    expect(sink.requests.single.conversationId, isNull);
    expect(sink.requests.single.detail, '重复广告');
    expect(sink.requests.single.diagnostics, '/data/nexmem/report-diag.jsonl');
    expect(find.text('举报已提交，感谢反馈'), findsOneWidget);
  });

  test('TransportReportSink 走 report.submit 并透传诊断包路径', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final TransportReportSink sink = TransportReportSink(
      transport,
      clientVersion: 'nexmem-app/0.1.0',
    );
    await sink.submit(
      const ReportRequest(
        reason: ReportReason.fraud,
        conversationId: 'dm:alice',
        detail: '骗取转账',
        diagnostics: '/data/nexmem/diag.jsonl',
      ),
    );
    expect(transport.methods, <String>['report.submit']);
    expect(transport.params.single, <String, dynamic>{
      'reason': 'fraud',
      'client_version': 'nexmem-app/0.1.0',
      'conversation_id': 'dm:alice',
      'detail': '骗取转账',
      'diagnostics_path': '/data/nexmem/diag.jsonl',
    });
  });

  testWidgets('未选择举报原因时提交被拦截', (WidgetTester tester) async {
    final _FakeReportSink sink = _FakeReportSink();
    await tester.pumpWidget(
      _wrap(
        SettingsPage(
          diagnostics: _FakeDiagnostics(value: _sample),
          reportSink: sink,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('settings-about')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('about-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('report-submit')));
    await tester.pumpAndSettle();

    expect(find.text('请选择举报原因'), findsOneWidget);
    expect(sink.requests, isEmpty);
  });

  testWidgets('聊天页举报入口携带会话 ID，上报服务未接入时保留弹窗提示', (WidgetTester tester) async {
    final _FakeReportSink sink = _FakeReportSink();
    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: const ConversationItem(
            id: 'alice',
            title: 'Alice',
            presence: PresenceStatus.online,
          ),
          store: ChatStore(conversationId: 'alice'),
          reportSink: sink,
          diagnostics: _FakeDiagnostics(value: _sample),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('举报'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('report-reason-fraud')));
    await tester.tap(find.byKey(const ValueKey<String>('report-submit')));
    await tester.pumpAndSettle();

    expect(sink.requests.single.conversationId, 'alice');
    expect(sink.requests.single.reason, ReportReason.fraud);
  });

  testWidgets('上报未接入时展示错误且不丢失输入', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: const ConversationItem(id: 'bob', title: 'Bob'),
          store: ChatStore(conversationId: 'bob'),
          diagnostics: _FakeDiagnostics(value: _sample),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('举报'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('report-reason-other')));
    await tester.tap(find.byKey(const ValueKey<String>('report-submit')));
    await tester.pumpAndSettle();

    expect(find.text('举报上报服务尚未接入，请稍后再试'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('report-submit')), findsOneWidget);
  });

  test('主题设置映射：未知值返回 null，三个模式可双向映射', () {
    expect(themeModeFromSetting('system'), ThemeMode.system);
    expect(themeModeFromSetting('light'), ThemeMode.light);
    expect(themeModeFromSetting('dark'), ThemeMode.dark);
    expect(themeModeFromSetting(null), isNull);
    expect(themeModeFromSetting('twilight'), isNull);
    expect(themeModeSettingValue(ThemeMode.system), 'system');
    expect(themeModeSettingValue(ThemeMode.light), 'light');
    expect(themeModeSettingValue(ThemeMode.dark), 'dark');
  });

  test('TransportSettingsService 走 settings.get/set 并可清除', () async {
    final _SettingsTransport transport = _SettingsTransport();
    final TransportSettingsService service = TransportSettingsService(
      transport,
    );

    expect(await service.read(themeModeSettingKey), isNull);
    await service.write(themeModeSettingKey, 'dark');
    expect(await service.read(themeModeSettingKey), 'dark');
    await service.write(themeModeSettingKey, '');
    expect(await service.read(themeModeSettingKey), isNull);

    expect(transport.methods, <String>[
      'settings.get',
      'settings.set',
      'settings.get',
      'settings.set',
      'settings.get',
    ]);
  });

  testWidgets('设置页账号卡片展示昵称与账号/设备缩略', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        SettingsPage(
          account: CoreAccount(
            accountId: 'a' * 64,
            deviceId: 'b' * 64,
            displayName: '小艾',
          ),
        ),
      ),
    );

    final Text name = tester.widget<Text>(
      find.byKey(const ValueKey<String>('settings-account-name')),
    );
    expect(name.data, '小艾');
    expect(find.text('账号 ${'a' * 10}… · 设备 ${'b' * 10}…'), findsOneWidget);
  });

  testWidgets('设置页未接入内核时账号卡片保持离线占位', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));

    expect(find.text('未登录设备'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('settings-account-meta')),
      findsNothing,
    );
  });

  testWidgets('设置页「外观」回传主题选择并关闭弹窗', (WidgetTester tester) async {
    ThemeMode? selected;
    await tester.pumpWidget(
      _wrap(
        SettingsPage(
          themeMode: ThemeMode.system,
          onThemeModeChanged: (ThemeMode mode) => selected = mode,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('settings-appearance')));
    await tester.pumpAndSettle();
    expect(find.byType(AppearanceDialog), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('appearance-dark')));
    await tester.pumpAndSettle();

    expect(selected, ThemeMode.dark);
    expect(find.text('浅色'), findsNothing);
  });

  testWidgets('应用启动时从内核恢复上次主题', (WidgetTester tester) async {
    final _AppThemeTransport transport = _AppThemeTransport(theme: 'dark');
    await tester.pumpWidget(NexmemApp(session: CoreSession(transport)));
    await tester.pumpAndSettle();

    final MaterialApp app = tester.widget<MaterialApp>(
      find.byType(MaterialApp),
    );
    expect(app.themeMode, ThemeMode.dark);
  });

  testWidgets('内核未提供主题设置时保持跟随系统', (WidgetTester tester) async {
    final _AppThemeTransport transport = _AppThemeTransport();
    await tester.pumpWidget(NexmemApp(session: CoreSession(transport)));
    await tester.pumpAndSettle();

    final MaterialApp app = tester.widget<MaterialApp>(
      find.byType(MaterialApp),
    );
    expect(app.themeMode, ThemeMode.system);
  });

  // P6-29：关于页展示内核版本、API 版本与能力数量，并提示主版本不兼容。
  testWidgets('关于页展示内核版本与已接入能力数量', (WidgetTester tester) async {
    final CoreInfo info = CoreInfo.fromJson(<String, dynamic>{
      'api_version': '1.0.0',
      'core_version': '0.1.0-dev',
      'features': <String>['core.info', 'msg.list', 'rtc.sendSignal'],
    });
    await tester.pumpWidget(_wrap(SettingsPage(coreInfo: info)));

    await tester.tap(find.byKey(const ValueKey<String>('settings-about')));
    await tester.pumpAndSettle();

    expect(find.text('版本 1.0.0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('about-core-version')),
      findsOneWidget,
    );
    expect(find.textContaining('0.1.0-dev'), findsOneWidget);
    expect(
      find.text('API 1.0.0 · 已接入 3 项能力'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('about-api-incompatible')),
      findsNothing,
    );
  });

  testWidgets('关于页在内核未接入时显示未知版本', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.tap(find.byKey(const ValueKey<String>('settings-about')));
    await tester.pumpAndSettle();

    expect(
      find.text('内核版本 未知'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('about-api-version')),
      findsNothing,
    );
  });

  testWidgets('API 主版本不兼容时展示警告', (WidgetTester tester) async {
    final CoreInfo info = CoreInfo.fromJson(<String, dynamic>{
      'api_version': '2.0.0',
      'core_version': '2.0.0',
    });
    await tester.pumpWidget(_wrap(SettingsPage(coreInfo: info)));

    await tester.tap(find.byKey(const ValueKey<String>('settings-about')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('about-api-incompatible')),
      findsOneWidget,
    );
  });

  testWidgets('个人资料面板展示账号详情并加载已保存的介绍/推广信息',
      (WidgetTester tester) async {
    final _SettingsTransport transport = _SettingsTransport();
    transport.stored[profileIntroSettingKey] = '这是我的个人介绍';
    transport.stored[profilePromoSettingKey] = '推广：example.com';
    final TransportSettingsService service = TransportSettingsService(
      transport,
    );

    await tester.pumpWidget(
      _wrap(
        ProfileDetailPanel(
          account: CoreAccount(
            accountId: 'a' * 64,
            deviceId: 'b' * 64,
            displayName: '小艾',
          ),
          settings: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('个人资料'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-display-name')), findsOneWidget);
    expect(find.text('小艾'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey<String>('profile-account-id'))).data,
      '${'a' * 20}…',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey<String>('profile-device-id'))).data,
      '${'b' * 20}…',
    );
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey<String>('profile-intro')))
          .controller!.text,
      '这是我的个人介绍',
    );
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey<String>('profile-promo')))
          .controller!.text,
      '推广：example.com',
    );
  });

  testWidgets('个人资料编辑保存介绍与推广信息到 KV 并回显成功',
      (WidgetTester tester) async {
    final _SettingsTransport transport = _SettingsTransport();
    final TransportSettingsService service = TransportSettingsService(
      transport,
    );
    int saved = 0;

    await tester.pumpWidget(
      _wrap(
        ProfileBody(
          account: CoreAccount(accountId: 'a' * 64, deviceId: 'b' * 64),
          settings: service,
          onSaved: () => saved++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('profile-intro')),
      '  热心开发者  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('profile-promo')),
      '  官网 home.page  ',
    );
    await tester.tap(find.byKey(const ValueKey<String>('profile-save')));
    await tester.pumpAndSettle();

    expect(transport.stored[profileIntroSettingKey], '热心开发者');
    expect(transport.stored[profilePromoSettingKey], '官网 home.page');
    expect(saved, 1);
    expect(find.byKey(const ValueKey<String>('profile-status')), findsOneWidget);
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('设置页新增个人资料入口且点击弹出编辑框',
      (WidgetTester tester) async {
    final _SettingsTransport transport = _SettingsTransport();
    await tester.pumpWidget(
      _wrap(
        SettingsPage(
          account: CoreAccount(accountId: 'a' * 64, deviceId: 'b' * 64),
          settings: TransportSettingsService(transport),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('settings-profile')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('settings-profile-card')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('profile-save')), findsOneWidget);
    expect(find.text('个人推广信息'), findsOneWidget);
  });
}
