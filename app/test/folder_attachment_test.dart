import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/files/folder_attachment_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final Directory tempRoot = Directory.systemTemp.createTempSync(
    'nexmem-folder-attachment-',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => tempRoot.path,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider_android'),
    (MethodCall call) async => tempRoot.path,
  );
  tearDownAll(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('选择目录后打包为 ZIP 附件并保留相对路径', () async {
    final Directory source = await Directory.systemTemp.createTemp(
      'nexmem-folder-src-',
    );
    addTearDown(() async {
      if (await source.exists()) {
        await source.delete(recursive: true);
      }
    });
    await File(p.join(source.path, 'a.txt')).writeAsString('hello');
    await Directory(p.join(source.path, 'sub')).create();
    await File(p.join(source.path, 'sub', 'b.txt')).writeAsString('world');

    final ChatAttachment? zip = await pickLocalFolderZip(
      () async => source.path,
    );
    expect(zip, isNotNull);
    expect(zip!.name, endsWith('.zip'));
    expect(zip.mime, 'application/zip');
    expect(zip.size, greaterThan(0));

    final List<int> bytes = await File(zip.path).readAsBytes();
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final List<String> names = archive.files
        .map((ArchiveFile file) => file.name)
        .toList()
      ..sort();
    expect(names, <String>['a.txt', 'sub/b.txt']);
  });

  test('用户取消选择时不产生附件', () async {
    final Object? attachment = await pickLocalFolderZip(() async => null);
    expect(attachment, isNull);
  });
}
