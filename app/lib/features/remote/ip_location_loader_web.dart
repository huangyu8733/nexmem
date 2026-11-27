// Web：IP 库随程序打包；浏览器无法写任意本地文件，更新库只在会话内缓存。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'ip_location.dart';

Uint8List? _memoryCache;

({IpLocationDownloader download, IpLocationBundledReader readBundled,
  Future<Uint8List?> Function() readCache,
  Future<void> Function(Uint8List bytes) writeCache})
    makeIpLocationLoader() {
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
          throw StateError('IP 库下载失败，HTTP ${response.statusCode}');
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
    readCache: () async => _memoryCache,
    writeCache: (Uint8List bytes) async {
      _memoryCache = bytes;
    },
  );
}
