// 远控文件发送：按 16 KiB 分片顺序读取，避免一次性载入大文件。
//
// Web 无本地路径，使用不支持实现；桌面/移动端走 dart:io。
import 'dart:typed_data';

import 'remote_file_stub.dart'
    if (dart.library.io) 'remote_file_io.dart' as impl;

/// 已打开的文件句柄：先算 CRC，再顺序读分片。
class RemoteFileHandle {
  RemoteFileHandle({
    required this.name,
    required this.size,
    required this.chunks,
    required this.crc,
    required this.reader,
    required this.closer,
  });

  final String name;
  final int size;
  final int chunks;
  final int crc;
  final Future<Uint8List?> Function() reader;
  final Future<void> Function() closer;

  Future<Uint8List?> nextChunk() => reader();

  Future<void> close() => closer();
}

abstract class RemoteFileReader {
  int get chunkSize;

  Future<RemoteFileHandle> open(String path);
}

RemoteFileReader createRemoteFileReader() => impl.createRemoteFileReader();
