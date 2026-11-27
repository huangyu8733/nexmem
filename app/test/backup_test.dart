// P6-05 验收：加密备份导出/导入入口、口令校验与错误码提示。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/settings/backup.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/transport/transport.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

class _FakeBackup implements BackupService {
  _FakeBackup({this.error});

  final NexmemException? error;
  final List<String> exports = <String>[];
  final List<String> imports = <String>[];
  String lastPassphrase = '';

  @override
  Future<String> export({
    required String path,
    required String passphrase,
  }) async {
    if (error != null) {
      throw error!;
    }
    exports.add(path);
    lastPassphrase = passphrase;
    return path;
  }

  @override
  Future<String> import({required String path, required String passphrase}) async {
    if (error != null) {
      throw error!;
    }
    imports.add(path);
    lastPassphrase = passphrase;
    return path;
  }
}

class _RecordingTransport implements CoreTransport {
  final List<String> methods = <String>[];
  Map<String, dynamic>? lastParams;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    methods.add(method);
    lastParams = params;
    return <String, dynamic>{'path': params?['path'] ?? ''};
  }

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

Future<void> _openAccountDialog(WidgetTester tester, BackupService service) async {
  await tester.pumpWidget(_wrap(SettingsPage(backup: service, profileOnly: true)));
  await tester.tap(find.byKey(const ValueKey<String>('settings-account')));
  await tester.pumpAndSettle();
}

void main() {
  test('TransportBackupService 以 base64 口令调用 backup.export/import', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final BackupService service = TransportBackupService(transport);

    final String path = await service.export(
      path: '/data/nexmem/account.nexbak',
      passphrase: '口令-123',
    );
    expect(path, '/data/nexmem/account.nexbak');
    expect(transport.methods, <String>['backup.export']);
    expect(transport.lastParams!['path'], '/data/nexmem/account.nexbak');
    expect(
      utf8.decode(base64Decode(transport.lastParams!['passphrase_b64'] as String)),
      '口令-123',
    );

    await service.import(
      path: '/data/nexmem/old.nexbak',
      passphrase: 'another',
    );
    expect(transport.methods.last, 'backup.import');
    expect(transport.lastParams!['path'], '/data/nexmem/old.nexbak');
  });

  testWidgets('「账号与安全」导出备份：口令确认后回显成功', (WidgetTester tester) async {
    final _FakeBackup backup = _FakeBackup();
    await _openAccountDialog(tester, backup);
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('导入备份'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('account-export')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-path')),
      '/data/nexmem/account.nexbak',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase')),
      'backup-pass',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase-confirm')),
      'backup-pass',
    );
    await tester.tap(find.byKey(const ValueKey<String>('backup-submit')));
    await tester.pumpAndSettle();

    expect(backup.exports, <String>['/data/nexmem/account.nexbak']);
    expect(backup.lastPassphrase, 'backup-pass');
    expect(find.text('备份已导出，请妥善保管文件与口令'), findsOneWidget);
  });

  testWidgets('导入备份无需二次确认并提示重启', (WidgetTester tester) async {
    final _FakeBackup backup = _FakeBackup();
    await _openAccountDialog(tester, backup);

    await tester.tap(find.byKey(const ValueKey<String>('account-import')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('backup-passphrase-confirm')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-path')),
      '/data/nexmem/old.nexbak',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase')),
      'old-pass',
    );
    await tester.tap(find.byKey(const ValueKey<String>('backup-submit')));
    await tester.pumpAndSettle();

    expect(backup.imports, <String>['/data/nexmem/old.nexbak']);
    expect(find.text('备份已导入，重启后可查看恢复的好友与消息'), findsOneWidget);
  });

  testWidgets('导出时两次口令不一致被拦截', (WidgetTester tester) async {
    final _FakeBackup backup = _FakeBackup();
    await _openAccountDialog(tester, backup);
    await tester.tap(find.byKey(const ValueKey<String>('account-export')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-path')),
      '/data/nexmem/a.nexbak',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase')),
      'one',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase-confirm')),
      'two',
    );
    await tester.tap(find.byKey(const ValueKey<String>('backup-submit')));
    await tester.pumpAndSettle();

    expect(find.text('两次输入的口令不一致'), findsOneWidget);
    expect(backup.exports, isEmpty);
  });

  testWidgets('缺少路径或口令时给出明确提示', (WidgetTester tester) async {
    final _FakeBackup backup = _FakeBackup();
    await _openAccountDialog(tester, backup);
    await tester.tap(find.byKey(const ValueKey<String>('account-import')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('backup-submit')));
    await tester.pumpAndSettle();
    expect(find.text('请填写备份文件路径'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-path')),
      '/data/nexmem/a.nexbak',
    );
    await tester.tap(find.byKey(const ValueKey<String>('backup-submit')));
    await tester.pumpAndSettle();
    expect(find.text('请填写备份口令'), findsOneWidget);
    expect(backup.imports, isEmpty);
  });

  testWidgets('口令错误映射为可读文案', (WidgetTester tester) async {
    final _FakeBackup backup = _FakeBackup(
      error: const NexmemException('CRYPTO_ERROR', 'bad passphrase'),
    );
    await _openAccountDialog(tester, backup);
    await tester.tap(find.byKey(const ValueKey<String>('account-import')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-path')),
      '/data/nexmem/a.nexbak',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase')),
      'wrong',
    );
    await tester.tap(find.byKey(const ValueKey<String>('backup-submit')));
    await tester.pumpAndSettle();

    expect(find.text('口令错误或备份文件已损坏'), findsOneWidget);
  });

  testWidgets('备份能力未接入时提示 NOT_STARTED 文案', (WidgetTester tester) async {
    await _openAccountDialog(tester, const UnavailableBackupService());
    await tester.tap(find.byKey(const ValueKey<String>('account-export')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-path')),
      '/data/nexmem/a.nexbak',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase')),
      'pass',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-passphrase-confirm')),
      'pass',
    );
    await tester.tap(find.byKey(const ValueKey<String>('backup-submit')));
    await tester.pumpAndSettle();

    expect(find.text('备份能力尚未接入内核'), findsOneWidget);
  });
}
