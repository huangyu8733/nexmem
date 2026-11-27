import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/files/web_download.dart';
import 'package:nexmem_app/transport/transport.dart';

class _StubTransport implements CoreTransport {
  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();
  @override
  int lastSeq = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async => <String, dynamic>{};
  @override
  Future<void> close() async {}
}

void main() {
  group('Web 鉴权下载链接', () {
    test('ws 端点换算为 http download，带 token 与编码后的服务端路径', () {
      final Uri url = webDownloadUri(
        Uri.parse('ws://127.0.0.1:8082/ws'),
        'devtoken',
        '/data/web-downloads/我的 报告.bin',
      );
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, 8082);
      expect(url.path, '/download');
      expect(url.queryParameters['token'], 'devtoken');
      expect(
        url.queryParameters['path'],
        '/data/web-downloads/我的 报告.bin',
        reason: '路径须原样保留供网关白名单校验',
      );
    });

    test('wss 端点换算为 https', () {
      final Uri url = webDownloadUri(
        Uri.parse('wss://example.com/ws?token=x'),
        'tk',
        '/data/web-downloads/a.bin',
      );
      expect(url.scheme, 'https');
      expect(url.path, '/download');
      expect(url.queryParameters, <String, String>{
        'token': 'tk',
        'path': '/data/web-downloads/a.bin',
      });
    });

    test('在线播放链接复用鉴权端点并声明 inline', () {
      final Uri url = webMediaUri(
        Uri.parse('ws://127.0.0.1:8082/ws'),
        'devtoken',
        '/data/web-downloads/voice.m4a',
      );
      expect(url.scheme, 'http');
      expect(url.path, '/download');
      expect(url.queryParameters, <String, String>{
        'token': 'devtoken',
        'path': '/data/web-downloads/voice.m4a',
        'disposition': 'inline',
      });
    });
  });

  test('CoreSession 可注入 Web 下载回调并透传服务端路径与文件名', () async {
    String? gotPath;
    String? gotName;
    final CoreSession session = CoreSession(
      _StubTransport(),
      downloadToBrowser: (String serverPath, String fileName) async {
        gotPath = serverPath;
        gotName = fileName;
      },
    );
    expect(session.downloadToBrowser, isNotNull);
    await session.downloadToBrowser!('/data/web-downloads/x.bin', 'x.bin');
    expect(gotPath, '/data/web-downloads/x.bin');
    expect(gotName, 'x.bin');
  });

  test('CoreSession 可注入 Web 媒体播放源', () {
    final CoreSession session = CoreSession(
      _StubTransport(),
      mediaSourceUri: (String path) =>
          webMediaUri(Uri.parse('wss://example.com/ws'), 'tk', path),
    );
    final Uri? source = session.mediaSourceUri?.call('/data/inbox/clip.mp4');
    expect(source, isNotNull);
    expect(source!.scheme, 'https');
    expect(source.queryParameters['disposition'], 'inline');
    expect(source.queryParameters['path'], '/data/inbox/clip.mp4');
  });
}
