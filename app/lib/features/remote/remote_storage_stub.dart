// Web / 无文件系统：内存存储。
import 'dart:typed_data';

import 'remote_storage.dart';

class MemoryRemoteStorage implements RemoteStorage {
  final Map<String, Map<String, dynamic>> _json = <String, Map<String, dynamic>>{};
  final Map<String, List<String>> _lines = <String, List<String>>{};

  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name];

  @override
  Future<void> writeJson(String name, Map<String, dynamic> data) async {
    _json[name] = data;
  }

  @override
  Future<List<String>> readLines(String name) async =>
      List<String>.from(_lines[name] ?? const <String>[]);

  @override
  Future<void> appendLine(String name, String line) async {
    (_lines[name] ??= <String>[]).add(line);
  }

  @override
  Future<void> clear(String name) async {
    _lines.remove(name);
  }

  @override
  Future<String> saveDownload(String fileName, Uint8List bytes) async =>
      fileName;
}

RemoteStorage createRemoteStorage() => MemoryRemoteStorage();
