// 远控本地存储：偏好、审计与文件落盘。
//
// Web 无文件系统，使用内存实现；桌面/移动端落应用支持目录。

import 'dart:typed_data';

import 'remote_storage_stub.dart'
    if (dart.library.io) 'remote_storage_io.dart' as impl;

abstract class RemoteStorage {
  Future<Map<String, dynamic>?> readJson(String name);

  Future<void> writeJson(String name, Map<String, dynamic> data);

  Future<List<String>> readLines(String name);

  Future<void> appendLine(String name, String line);

  Future<void> clear(String name);

  /// 将接收到的文件写入下载目录，返回展示用路径。
  Future<String> saveDownload(String fileName, Uint8List bytes);
}

RemoteStorage createRemoteStorage() => impl.createRemoteStorage();
