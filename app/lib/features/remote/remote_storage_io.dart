// 桌面/移动端存储：应用支持目录 + 下载目录。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'remote_storage.dart';

class IoRemoteStorage implements RemoteStorage {
  static const int _maxAuditBytes = 1024 * 1024;

  Future<File> _file(String name) async {
    final Directory dir = await getApplicationSupportDirectory();
    final Directory target = Directory('${dir.path}/remote');
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return File('${target.path}/$name');
  }

  @override
  Future<Map<String, dynamic>?> readJson(String name) async {
    try {
      final File file = await _file(name);
      if (!await file.exists()) {
        return null;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeJson(String name, Map<String, dynamic> data) async {
    final File file = await _file(name);
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  @override
  Future<List<String>> readLines(String name) async {
    try {
      final File file = await _file(name);
      if (!await file.exists()) {
        return const <String>[];
      }
      return await file.readAsLines();
    } on Object {
      return const <String>[];
    }
  }

  @override
  Future<void> appendLine(String name, String line) async {
    final File file = await _file(name);
    if (await file.exists() && await file.length() > _maxAuditBytes) {
      final File rotated = File('${file.path}.1');
      if (await rotated.exists()) {
        await rotated.delete();
      }
      await file.rename(rotated.path);
    }
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  @override
  Future<void> clear(String name) async {
    final File file = await _file(name);
    if (await file.exists()) {
      await file.delete();
    }
    final File rotated = File('${file.path}.1');
    if (await rotated.exists()) {
      await rotated.delete();
    }
  }

  @override
  Future<String> saveDownload(String fileName, Uint8List bytes) async {
    Directory? dir = await getDownloadsDirectory();
    dir ??= await getApplicationDocumentsDirectory();
    final String safe = _safeName(fileName);
    String path = '${dir.path}/$safe';
    File file = File(path);
    int index = 1;
    while (await file.exists()) {
      path = '${dir.path}/${_stem(safe)} ($index)${_ext(safe)}';
      file = File(path);
      index++;
    }
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  static String _safeName(String name) {
    final String base = name.split(RegExp(r'[/\\]')).last.trim();
    final String cleaned = base.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
    return cleaned.isEmpty || cleaned == '.' || cleaned == '..'
        ? 'nexmem-file'
        : cleaned;
  }

  static String _stem(String name) {
    final int dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  static String _ext(String name) {
    final int dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }
}

RemoteStorage createRemoteStorage() => IoRemoteStorage();
