import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../chat/chat_message.dart';

/// 选择本地目录并打包成 ZIP 附件。
///
/// 复用内核现有的 `dm.sendFile` 单文件通道：接收方看到的是一个 zip 附件，
/// 可用已有的文件预览 / 保存能力解压，避免为文件夹另开一套分片协议。
Future<ChatAttachment?> pickLocalFolderZip(
  Future<String?> Function()? directoryPicker,
) async {
  final Future<String?> Function()? picker = directoryPicker;
  if (picker == null) {
    return null;
  }
  final String? path = await picker();
  if (path == null || path.trim().isEmpty) {
    return null;
  }
  final Directory directory = Directory(path);
  if (!await directory.exists()) {
    throw StateError('文件夹不存在或无法读取');
  }

  final Archive archive = Archive();
  await for (final FileSystemEntity entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) {
      continue;
    }
    final String relative = p
        .relative(entity.path, from: directory.path)
        .replaceAll('\\', '/');
    if (relative.startsWith('../') || relative == '..') {
      continue;
    }
    final List<int> bytes = await entity.readAsBytes();
    archive.addFile(ArchiveFile(relative, bytes.length, bytes));
  }

  final List<int> zipBytes = ZipEncoder().encode(archive);
  final Directory temp = await getTemporaryDirectory();
  final String name = p.basename(directory.path).isEmpty
      ? 'folder'
      : p.basename(directory.path);
  final String zipName = '$name.zip';
  final File target = File(
    p.join(
      temp.path,
      'nexmem-folder-${DateTime.now().microsecondsSinceEpoch}.zip',
    ),
  );
  await target.writeAsBytes(zipBytes, flush: true);
  return ChatAttachment(
    name: zipName,
    size: zipBytes.length,
    mime: 'application/zip',
    path: target.path,
  );
}
