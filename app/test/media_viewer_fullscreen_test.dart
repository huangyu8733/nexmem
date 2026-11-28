// 媒体查看器全屏：图片/视频/音乐三类都进入满屏查看器，提供关闭与播放控制。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/files/media_viewer.dart';
import 'package:nexmem_app/features/qr/image_qr_decoder.dart';

/// 吞掉原生播放器/系统 UI 的 MethodChannel，避免测试里 MissingPluginException。
void _mockChannels() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final String channel in <String>[
    'plugins.flutter.io/video_player_view',
    'com.bluehorn.audioplayers',
    'flutter/system_chrome',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(channel),
      (MethodCall call) async => switch (call.method) {
        'init' || 'create' || 'setSource' || 'getDuration' => 0,
        _ => null,
      },
    );
  }
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 固定帧推进：查看器含加载指示器/流订阅，pumpAndSettle 不会收敛。
Future<void> _pumpFrames(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(_mockChannels);

  test('媒体分类正确识别图片/视频/音频', () {
    expect(mediaKindOf('/tmp/a.jpg', mime: 'image/jpeg'), MediaKind.image);
    expect(mediaKindOf('/tmp/b.mp4', mime: 'video/mp4'), MediaKind.video);
    expect(mediaKindOf('/tmp/c.mp3', mime: 'audio/mpeg'), MediaKind.audio);
    expect(mediaKindOf('/tmp/d.txt'), MediaKind.other);
  });

  test('常用图片格式统一识别为图片并补齐 MIME', () {
    const List<String> formats = <String>[
      'jpg', 'jpeg', 'jfif', 'png', 'gif', 'webp', 'bmp',
      'heic', 'heif', 'tif', 'tiff', 'avif', 'ico',
    ];
    for (final String ext in formats) {
      expect(isImageAttachment(name: 'photo.$ext'), isTrue, reason: ext);
      expect(imageMimeFor('photo.$ext').startsWith('image/'), isTrue, reason: ext);
      expect(mediaKindOf('/tmp/photo.$ext'), MediaKind.image, reason: ext);
    }
    expect(imageMimeFor('photo.jfif'), 'image/jpeg');
    expect(imageMimeFor('photo.webp'), 'image/webp');
    expect(imageMimeFor('photo.avif'), 'image/avif');
  });

  testWidgets('图片全屏查看：占满屏幕、可缩放、有关闭按钮', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_wrap(const MediaViewerDialog(
      path: '/tmp/photo.png',
      mime: 'image/png',
      title: 'photo.png',
    )));
    await _pumpFrames(tester);

    final Material material = tester.widget<Material>(
      find.byKey(const ValueKey<String>('media-viewer-dialog')),
    );
    expect(material.color, Colors.black);
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Size viewer = tester.getSize(
      find.byKey(const ValueKey<String>('media-viewer-dialog')),
    );
    expect(viewer.width, closeTo(screen.width, 1));
    expect(viewer.height, closeTo(screen.height, 1));

    expect(
      find.byKey(const ValueKey<String>('media-viewer-image')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-viewer-close')),
      findsOneWidget,
    );
    // 缩放能力由 InteractiveViewer 提供，变换控制器已注入。
    final InteractiveViewer viewerWidget = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewerWidget.transformationController, isNotNull);
    expect(viewerWidget.maxScale, greaterThan(1));
  });

  testWidgets('视频全屏：有关闭、旋转、播放控件', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const MediaViewerDialog(
      path: '/tmp/movie.mp4',
      mime: 'video/mp4',
      title: 'movie.mp4',
    )));
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey<String>('media-viewer-close')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-viewer-orientation')),
      findsOneWidget,
    );
    // 解码失败也不崩溃，控制条（含播放按钮）仍在。
    expect(find.byType(Slider), findsWidgets);
  });

  testWidgets('音乐全屏：有播放控件与音频视图', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const MediaViewerDialog(
      path: '/tmp/music.mp3',
      mime: 'audio/mpeg',
      title: 'music.mp3',
    )));
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey<String>('media-viewer-audio')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-viewer-close')),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsWidgets);
  });

  testWidgets('图片长按识别二维码后打开内置浏览器', (WidgetTester tester) async {
    final QrImageDecoder original = qrImageDecoder;
    addTearDown(() => qrImageDecoder = original);
    qrImageDecoder = ({
      required String path,
      String? sourceUri,
    }) async {
      expect(path, '/tmp/photo-qr.png');
      return 'https://example.com/from-qr';
    };

    await tester.pumpWidget(_wrap(const MediaViewerDialog(
      path: '/tmp/photo-qr.png',
      mime: 'image/png',
      title: 'photo-qr.png',
    )));
    await _pumpFrames(tester);

    await tester.longPress(find.byKey(const ValueKey<String>('media-viewer-image')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('browser-page')), findsOneWidget);
    final TextField address = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('browser-address')),
    );
    expect(address.controller?.text, 'https://example.com/from-qr');
  });
}
