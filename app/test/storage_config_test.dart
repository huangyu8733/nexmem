// P6-04 验收：云厂商接入引导页与 storage.test 自检交互。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/storage_config.dart';
import 'package:nexmem_app/transport/transport.dart';

class _FakeStorageTestService implements StorageTestService {
  _FakeStorageTestService({
    this.error,
    this.saveError,
    this.snapshot = const StorageConfigSnapshot(
      configured: false,
      enabled: false,
    ),
  });

  final NexmemException? error;
  final NexmemException? saveError;
  StorageConfigSnapshot snapshot;
  StorageTestRequest? lastRequest;
  StorageSaveRequest? lastSave;
  int calls = 0;
  int saveCalls = 0;

  @override
  Future<StorageTestResult> test(StorageTestRequest request) async {
    calls++;
    lastRequest = request;
    if (error != null) {
      throw error!;
    }
    return const StorageTestResult(
      ok: true,
      latencyMs: 12,
      writable: true,
      listable: true,
    );
  }

  @override
  Future<StorageConfigSnapshot> load() async => snapshot;

  @override
  Future<void> save(StorageSaveRequest request) async {
    saveCalls++;
    lastSave = request;
    if (saveError != null) {
      throw saveError!;
    }
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

Future<void> _pumpDialog(
  WidgetTester tester,
  StorageTestService service,
) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(StorageConfigDialog(service: service)));
  await tester.pumpAndSettle();
  // C-06：通用 helper 默认确认受限子密钥；门槛本身由独立用例覆盖。
  final Finder confirm = find.byKey(
    const ValueKey<String>('storage-scoped-key-confirm'),
  );
  if (confirm.evaluate().isNotEmpty) {
    await tester.tap(confirm);
    await tester.pumpAndSettle();
  }
}

Future<void> _fillRequired(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('storage-endpoint')),
    'https://example.r2.cloudflarestorage.com',
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('storage-bucket')),
    'nexmem-test',
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('storage-ak')),
    'AK123',
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('storage-sk')),
    'SK456',
  );
}

/// 弹窗内容现在按屏幕高度限高滚动，操作前先滚动到目标控件。
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('C-06 主密钥形态识别：高置信前缀与默认 root 凭证被拒', () {
    for (final String ak in <String>[
      'AKIAIOSFODNN7EXAMPLE',
      'ASIAIOSFODNN7EXAMPLE',
      'LTAI5t7TestAccessKey',
      'AKIDz8krbsJ5yKBZQ',
      'minioadmin',
      'root',
    ]) {
      expect(looksLikeMasterAccessKey(ak), isTrue, reason: ak);
    }
    // 受限子密钥与自建随机 key 不受影响。
    for (final String ak in <String>['AK123', 'scoped-im_offline-01', 'mykey']) {
      expect(looksLikeMasterAccessKey(ak), isFalse, reason: ak);
    }
  });

  test('C-06 validate 拒绝疑似主密钥', () {
    final StorageTestRequest testReq = StorageTestRequest(
      provider: StorageProvider.r2,
      endpoint: 'https://x.r2.cloudflarestorage.com',
      bucket: 'bucket',
      prefix: 'im_offline',
      region: 'auto',
      accessKey: 'AKIAIOSFODNN7EXAMPLE',
      secretKey: 'secret',
      pathStyle: false,
    );
    expect(testReq.validate(), contains('主密钥'));
    final StorageSaveRequest saveReq = StorageSaveRequest(
      endpoint: 'https://x.r2.cloudflarestorage.com',
      bucket: 'bucket',
      prefix: 'im_offline',
      region: 'auto',
      accessKey: 'LTAI5t7TestAccessKey',
      secretKey: 'secret',
      pathStyle: false,
      enabled: true,
      public: true,
    );
    expect(saveReq.validate(hasStoredCredentials: false), contains('主密钥'));
  });

  test('自检结果解析与摘要文案', () {
    final StorageTestResult ok = StorageTestResult.fromJson(<String, dynamic>{
      'ok': true,
      'latency_ms': 18.0,
      'writable': true,
      'listable': true,
    });
    expect(ok.ok, isTrue);
    expect(ok.latencyMs, 18);
    expect(ok.summary, '自检通过 · 18ms');

    final StorageTestResult failed = StorageTestResult.fromJson(
      <String, dynamic>{
        'ok': false,
        'latency_ms': 7,
        'writable': true,
        'listable': false,
      },
    );
    expect(failed.summary, '自检未通过 · 7ms');
    expect(failed.writable, isTrue);
    expect(failed.listable, isFalse);
  });

  test('公开开关解析：缺省视为公开，显式 false 时关闭', () {
    final StorageConfigSnapshot legacy = StorageConfigSnapshot.fromJson(
      <String, dynamic>{'configured': true, 'enabled': true},
    );
    expect(legacy.public, isTrue);

    final StorageConfigSnapshot closed = StorageConfigSnapshot.fromJson(
      <String, dynamic>{'configured': true, 'enabled': true, 'public': false},
    );
    expect(closed.public, isFalse);
  });

  test('C-03 六类 S3 provider 反推与默认值', () {
    StorageConfigSnapshot snap(String ep, String region) =>
        StorageConfigSnapshot.fromJson(<String, dynamic>{
          'configured': true,
          'enabled': true,
          'endpoint': ep,
          'region': region,
        });

    expect(snap('https://s3.us-west-001.backblazeb2.com', 'us-west-001').provider,
        StorageProvider.backblazeB2);
    expect(snap('http://192.168.1.10:9000', 'us-east-1').provider,
        StorageProvider.nas);
    expect(snap('http://10.0.0.5:9000', 'us-east-1').provider,
        StorageProvider.nas);
    expect(snap('https://x.r2.cloudflarestorage.com', 'auto').provider,
        StorageProvider.r2);
    expect(snap('https://minio.example.com', 'us-east-1').provider,
        StorageProvider.minio);

    expect(StorageProvider.backblazeB2.label, 'Backblaze B2');
    expect(StorageProvider.backblazeB2.defaultPathStyle, isFalse);
    expect(StorageProvider.nas.label, '个人 NAS / 自建 S3');
    expect(StorageProvider.nas.defaultPathStyle, isTrue);
  });

  test('请求校验与网关参数：缺字段给出中文提示，path_style 随厂商变化', () {
    const StorageTestRequest empty = StorageTestRequest(
      provider: StorageProvider.r2,
      endpoint: '',
      bucket: 'b',
      prefix: 'p',
      region: 'auto',
      accessKey: 'a',
      secretKey: 's',
      pathStyle: false,
    );
    expect(empty.validate(), '请填写 Endpoint');

    const StorageTestRequest badScheme = StorageTestRequest(
      provider: StorageProvider.r2,
      endpoint: 'example.com',
      bucket: 'b',
      prefix: 'p',
      region: 'auto',
      accessKey: 'a',
      secretKey: 's',
      pathStyle: false,
    );
    expect(badScheme.validate(), 'Endpoint 必须以 http:// 或 https:// 开头');

    const StorageTestRequest missingSecret = StorageTestRequest(
      provider: StorageProvider.minio,
      endpoint: 'http://127.0.0.1:9000',
      bucket: 'b',
      prefix: 'p',
      region: 'us-east-1',
      accessKey: 'a',
      secretKey: '',
      pathStyle: true,
    );
    expect(missingSecret.validate(), '请填写 AK 与 SK');

    final Map<String, dynamic> params = missingSecret.toParams();
    expect(params['ak'], 'a');
    expect(params['path_style'], isTrue);
    expect(params['endpoint'], 'http://127.0.0.1:9000');
  });

  testWidgets('接入引导展示计费归属与最小权限提示', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);

    expect(
      find.byKey(const ValueKey<String>('storage-billing-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('计入本账号所填云存储的账单'), findsOneWidget);
    expect(find.textContaining('im_offline/*'), findsOneWidget);
    expect(find.textContaining('严禁填入主密钥'), findsOneWidget);
  });

  testWidgets('空表单自检被拦截，不调用内核', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);

    await tester.tap(find.byKey(const ValueKey<String>('storage-selftest')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('storage-error')), findsOneWidget);
    expect(find.text('请填写 Endpoint'), findsOneWidget);
    expect(fake.calls, 0);
  });

  testWidgets('C-06 未确认受限子密钥时自检与保存均被拦截', (
    WidgetTester tester,
  ) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(StorageConfigDialog(service: fake)));
    await tester.pumpAndSettle();
    await _fillRequired(tester);

    await tester.tap(find.byKey(const ValueKey<String>('storage-selftest')));
    await tester.pumpAndSettle();
    expect(fake.calls, 0);
    expect(find.textContaining('请先确认使用专用桶与受限子密钥'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('storage-save')));
    await tester.pumpAndSettle();
    expect(fake.saveCalls, 0);
  });

  testWidgets('填写完整后自检通过，展示耗时与写入/列举结论', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);
    await _fillRequired(tester);

    await tester.tap(find.byKey(const ValueKey<String>('storage-selftest')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    expect(fake.lastRequest!.bucket, 'nexmem-test');
    expect(fake.lastRequest!.provider, StorageProvider.r2);
    expect(fake.lastRequest!.pathStyle, isFalse);
    expect(
      find.byKey(const ValueKey<String>('storage-result')),
      findsOneWidget,
    );
    expect(find.text('自检通过 · 12ms'), findsOneWidget);
    expect(find.text('写入 通过 · 列举 通过'), findsOneWidget);
  });

  testWidgets('切换 MinIO 后 Region 与 path_style 自动适配', (
    WidgetTester tester,
  ) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);
    await _fillRequired(tester);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-provider-minio')),
    );
    expect(find.text('us-east-1'), findsOneWidget);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-selftest')),
    );

    expect(fake.lastRequest!.provider, StorageProvider.minio);
    expect(fake.lastRequest!.region, 'us-east-1');
    expect(fake.lastRequest!.pathStyle, isTrue);
    expect(fake.lastRequest!.toParams()['path_style'], isTrue);
  });

  testWidgets('C-03 切换 B2/个人 NAS 后 Region 与 path_style 自动适配', (
    WidgetTester tester,
  ) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-provider-backblazeB2')),
    );
    expect(find.text('us-west-001'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('storage-endpoint')),
      'https://s3.us-west-001.backblazeb2.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('storage-bucket')),
      'b2-bucket',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('storage-ak')),
      'b2-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('storage-sk')),
      'b2-secret',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-selftest')),
    );
    expect(fake.lastRequest!.provider, StorageProvider.backblazeB2);
    expect(fake.lastRequest!.pathStyle, isFalse);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-provider-nas')),
    );
    expect(find.text('us-east-1'), findsOneWidget);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-selftest')),
    );
    expect(fake.lastRequest!.provider, StorageProvider.nas);
    expect(fake.lastRequest!.pathStyle, isTrue);
  });

  testWidgets('鉴权失败给出明确文案', (WidgetTester tester) async {
    final _FakeStorageTestService auth = _FakeStorageTestService(
      error: const NexmemException('S3_AUTH', 'denied'),
    );
    await _pumpDialog(tester, auth);
    await _fillRequired(tester);
    await tester.tap(find.byKey(const ValueKey<String>('storage-selftest')));
    await tester.pumpAndSettle();
    expect(find.text('鉴权失败：请检查 AK/SK 与桶权限（S3_AUTH）'), findsOneWidget);
  });

  testWidgets('未接入内核自检给出 NOT_STARTED 文案', (WidgetTester tester) async {
    final _FakeStorageTestService unavailable = _FakeStorageTestService(
      error: const NexmemException('NOT_STARTED', 'not ready'),
    );
    await _pumpDialog(tester, unavailable);
    await _fillRequired(tester);
    await tester.tap(find.byKey(const ValueKey<String>('storage-selftest')));
    await tester.pumpAndSettle();
    expect(find.text('存储自检尚未接入内核'), findsOneWidget);
  });

  testWidgets('设置页「离线存储」打开接入引导', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(SettingsPage(storage: fake)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('settings-storage')));
    await tester.pumpAndSettle();

    expect(find.text('离线存储'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('storage-selftest')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('storage-provider-r2')),
      findsOneWidget,
    );
  });

  testWidgets('已保存配置回显：字段回填且 Secret Key 留空并提示沿用', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService(
      snapshot: const StorageConfigSnapshot(
        configured: true,
        enabled: true,
        endpoint: 'http://127.0.0.1:9000',
        bucket: 'nexmem',
        prefix: 'im_offline',
        region: 'us-east-1',
        accessKey: 'AK12345678',
        pathStyle: true,
      ),
    );
    await _pumpDialog(tester, fake);

    String fieldText(String key) => tester
        .widget<TextField>(find.byKey(ValueKey<String>(key)))
        .controller!
        .text;
    expect(fieldText('storage-endpoint'), 'http://127.0.0.1:9000');
    expect(fieldText('storage-bucket'), 'nexmem');
    expect(fieldText('storage-prefix'), 'im_offline');
    expect(fieldText('storage-region'), 'us-east-1');
    expect(fieldText('storage-ak'), 'AK12345678');
    expect(fieldText('storage-sk'), isEmpty);
    expect(find.text('留空则沿用已保存的 Secret Key'), findsOneWidget);
    final SwitchListTile toggle = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('storage-enabled')),
    );
    expect(toggle.value, isTrue);
    final SwitchListTile publicToggle = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('storage-public')),
    );
    expect(publicToggle.value, isTrue);
  });

  testWidgets('保存配置：参数完整且保存成功后关闭弹窗', (
    WidgetTester tester,
  ) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);
    await _fillRequired(tester);

    await tester.tap(find.byKey(const ValueKey<String>('storage-save')));
    await tester.pumpAndSettle();

    expect(fake.saveCalls, 1);
    expect(fake.lastSave!.bucket, 'nexmem-test');
    expect(fake.lastSave!.accessKey, 'AK123');
    expect(fake.lastSave!.secretKey, 'SK456');
    expect(fake.lastSave!.enabled, isTrue);
    expect(fake.lastSave!.public, isTrue);
    expect(fake.lastSave!.pathStyle, isFalse);
    expect(fake.lastSave!.toParams()['public'], isTrue);
    // C-02：默认 lifecycle 模式，不删除云端对象。
    expect(fake.lastSave!.deleteAfterRead, isFalse);
    expect(find.byKey(const ValueKey<String>('storage-save')), findsNothing);
    expect(find.byType(StorageConfigDialog), findsNothing);
  });

  testWidgets('C-02 已读后删除云端密文开关：开启后保存 delete_after_read=true', (
    WidgetTester tester,
  ) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);

    final Finder toggle = find.byKey(
      const ValueKey<String>('storage-delete-after-read'),
    );
    expect(toggle, findsOneWidget);
    await _tapVisible(tester, toggle);

    await _fillRequired(tester);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-save')),
    );

    expect(fake.saveCalls, 1);
    expect(fake.lastSave!.deleteAfterRead, isTrue);
    expect(fake.lastSave!.toParams()['delete_after_read'], isTrue);
  });

  testWidgets('关闭对外公开后保存 public=false 并关闭弹窗', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService(
      snapshot: const StorageConfigSnapshot(
        configured: true,
        enabled: true,
        endpoint: 'http://127.0.0.1:9000',
        bucket: 'nexmem',
        prefix: 'im_offline',
        region: 'us-east-1',
        accessKey: 'AK12345678',
        pathStyle: true,
      ),
    );
    await _pumpDialog(tester, fake);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-public')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-save')),
    );

    expect(fake.saveCalls, 1);
    expect(fake.lastSave!.enabled, isTrue);
    expect(fake.lastSave!.public, isFalse);
    expect(fake.lastSave!.toParams()['public'], isFalse);
    expect(find.byType(StorageConfigDialog), findsNothing);
  });

  testWidgets('已有凭证可留空 SK 保存，关闭开关后 enabled=false 且关闭弹窗', (
    WidgetTester tester,
  ) async {
    final _FakeStorageTestService fake = _FakeStorageTestService(
      snapshot: const StorageConfigSnapshot(
        configured: true,
        enabled: true,
        endpoint: 'http://127.0.0.1:9000',
        bucket: 'nexmem',
        prefix: 'im_offline',
        region: 'us-east-1',
        accessKey: 'AK12345678',
        pathStyle: true,
      ),
    );
    await _pumpDialog(tester, fake);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-enabled')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey<String>('storage-save')),
    );

    expect(fake.saveCalls, 1);
    expect(fake.lastSave!.secretKey, isEmpty);
    expect(fake.lastSave!.enabled, isFalse);
    expect(find.byType(StorageConfigDialog), findsNothing);
  });

  testWidgets('保存校验：空表单被拦截且不调用内核', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService();
    await _pumpDialog(tester, fake);

    await tester.tap(find.byKey(const ValueKey<String>('storage-save')));
    await tester.pumpAndSettle();

    expect(fake.saveCalls, 0);
    expect(find.text('请填写 Endpoint'), findsOneWidget);
  });

  testWidgets('保存失败给出明确文案', (WidgetTester tester) async {
    final _FakeStorageTestService fake = _FakeStorageTestService(
      saveError: const NexmemException('DB_ERROR', 'disk'),
    );
    await _pumpDialog(tester, fake);
    await _fillRequired(tester);

    await tester.tap(find.byKey(const ValueKey<String>('storage-save')));
    await tester.pumpAndSettle();

    expect(find.text('保存配置失败：本机配置写入异常（DB_ERROR）'), findsOneWidget);
  });
}
