// 桌面/移动端文件读取：RandomAccessFile 分片 + 全文件 CRC。
import 'dart:io';
import 'dart:typed_data';

import 'remote_crc32.dart';
import 'remote_file.dart';

class IoRemoteFileReader implements RemoteFileReader {
  const IoRemoteFileReader();

  @override
  int get chunkSize => 16 * 1024;

  @override
  Future<RemoteFileHandle> open(String path) async {
    final File file = File(path);
    final int size = await file.length();
    final RandomAccessFile raf = await file.open();
    final Crc32 crc = Crc32();
    final Uint8List buffer = Uint8List(64 * 1024);
    try {
      while (true) {
        final int read = await raf.readInto(buffer);
        if (read <= 0) {
          break;
        }
        crc.add(Uint8List.sublistView(buffer, 0, read));
      }
      await raf.setPosition(0);
    } on Object {
      await raf.close();
      rethrow;
    }
    final int chunks = size == 0 ? 0 : (size + chunkSize - 1) ~/ chunkSize;
    bool closed = false;
    return RemoteFileHandle(
      name: path.split(RegExp(r'[/\\]')).last,
      size: size,
      chunks: chunks,
      crc: crc.value,
      reader: () async {
        if (closed) {
          return null;
        }
        final Uint8List data = await raf.read(chunkSize);
        return data.isEmpty ? null : data;
      },
      closer: () async {
        if (!closed) {
          closed = true;
          await raf.close();
        }
      },
    );
  }
}

RemoteFileReader createRemoteFileReader() => const IoRemoteFileReader();
