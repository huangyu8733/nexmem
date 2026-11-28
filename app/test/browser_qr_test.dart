// 内置浏览器与图片二维码识别：URL 归一化、浏览器页面、二维码结果处理。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/browser/browser_url.dart';
import 'package:nexmem_app/features/qr/image_qr_decoder.dart';
import 'package:nexmem_app/features/qr/qr_result_handler.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('网址归一化与消息文本链接提取', () {
    expect(normalizeWebUrl('example.com'), 'https://example.com');
    expect(normalizeWebUrl('http://127.0.0.1:8080/a?b=1'),
        'http://127.0.0.1:8080/a?b=1');
    expect(normalizeWebUrl('nexmem://add/abc'), isNull);
    expect(normalizeWebUrl('not a url'), isNull);
    expect(
      extractFirstWebUrl('详情见 https://example.com/docs，谢谢。'),
      'https://example.com/docs',
    );
    expect(extractFirstWebUrl('普通文本'), isNull);
  });

  test('消息文本提取多个网址并自动补 https', () {
    final List<WebUrlMatch> matches = extractWebUrls(
      '见 example.com/a 和 https://foo.org/b，还有 127.0.0.1:8080/x。',
    );
    expect(
      matches.map((WebUrlMatch m) => m.url).toList(),
      <String>[
        'https://example.com/a',
        'https://foo.org/b',
        'https://127.0.0.1:8080/x',
      ],
    );
    expect(matches.first.text, 'example.com/a');
    expect(matches.first.start, 2);
  });

  testWidgets('二维码网址结果打开内置浏览器', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (BuildContext context) => FilledButton(
            key: const ValueKey<String>('qr-trigger'),
            onPressed: () async {
              await handleQrResult(context, 'example.com/qr');
            },
            child: const Text('识别'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('qr-trigger')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('browser-page')), findsOneWidget);
    final TextField address = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('browser-address')),
    );
    expect(address.controller?.text, 'https://example.com/qr');
    expect(
      find.byKey(const ValueKey<String>('browser-unsupported-url')),
      findsOneWidget,
    );
  });

  testWidgets('二维码普通文本显示可复制内容', (WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (BuildContext context) => FilledButton(
            key: const ValueKey<String>('qr-trigger'),
            onPressed: () async {
              await handleQrResult(context, 'HELLO-NEXMEM');
            },
            child: const Text('识别'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('qr-trigger')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('qr-result-text')), findsOneWidget);
    expect(find.text('HELLO-NEXMEM'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '复制'));
    await tester.pumpAndSettle();
    expect(copied, 'HELLO-NEXMEM');
  });

  testWidgets('图片解码入口可被注入，未识别时返回 null', (WidgetTester tester) async {
    final QrImageDecoder original = qrImageDecoder;
    addTearDown(() => qrImageDecoder = original);

    String? receivedPath;
    qrImageDecoder = ({
      required String path,
      String? sourceUri,
    }) async {
      receivedPath = path;
      return 'DECODED-QR';
    };
    expect(
      await decodeQrFromImage(path: '/tmp/qr.png'),
      'DECODED-QR',
    );
    expect(receivedPath, '/tmp/qr.png');

    qrImageDecoder = ({
      required String path,
      String? sourceUri,
    }) async => null;
    expect(await decodeQrFromImage(path: '/tmp/empty.png'), isNull);
  });
}
