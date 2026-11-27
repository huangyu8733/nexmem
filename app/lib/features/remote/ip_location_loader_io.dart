// 桌面/移动：IP 库随程序内置；下载缓存仅作为可选的手动更新通道。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ip_location.dart';

({IpLocationDownloader download, IpLocationBundledReader readBundled,
  Future<Uint8List?> Function() readCache,
  Future<void> Function(Uint8List bytes) writeCache})
    makeIpLocationLoader() {
  Future<File> dbFile() async {
    final Directory dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, kIpLocationDbFileName));
  }

  return (
    readBundled: () async {
      try {
        final ByteData data = await rootBundle.load(kIpLocationBundledAsset);
        return data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } on Object {
        return null;
      }
    },
    download: ({required String url, void Function(int received, int total)? onProgress}) async {
      final http.Client client = http.Client();
      try {
        final http.StreamedResponse response =
            await client.send(http.Request('GET', Uri.parse(url)));
        if (response.statusCode != 200) {
          throw HttpException('IP 库下载失败，HTTP ${response.statusCode}');
        }
        final int total = response.contentLength ?? -1;
        final List<int> chunks = <int>[];
        final Completer<Uint8List> completer = Completer<Uint8List>();
        response.stream.listen(
          (List<int> chunk) {
            chunks.addAll(chunk);
            onProgress?.call(chunks.length, total);
          },
          onDone: () => completer.complete(Uint8List.fromList(chunks)),
          onError: (Object error, StackTrace stack) =>
              completer.completeError(error, stack),
          cancelOnError: true,
        );
        return await completer.future;
      } finally {
        client.close();
      }
    },
    readCache: () async {
      try {
        final File file = await dbFile();
        if (!await file.exists()) {
          return null;
        }
        return await file.readAsBytes();
      } on Object {
        return null;
      }
    },
    writeCache: (Uint8List bytes) async {
      final File file = await dbFile();
      final File temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
    },
  );
}
