// 图片裁剪验收：坐标反算、方形/自由裁剪输出、裁剪页交互。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/settings/image_crop_page.dart';

void main() {
  test('裁剪框坐标按缩放与平移反算为原图像素', () {
    const Size view = Size(400, 400);
    const Size display = Size(200, 200);
    const Size source = Size(400, 400);
    const Rect frame = Rect.fromLTWH(150, 150, 100, 100);

    expect(
      calculateCropSourceRect(
        cropRect: frame,
        viewSize: view,
        displaySize: display,
        scale: 1,
        translation: Offset.zero,
        sourceSize: source,
      ),
      const Rect.fromLTWH(100, 100, 200, 200),
    );

    final Rect scaled = calculateCropSourceRect(
      cropRect: frame,
      viewSize: view,
      displaySize: display,
      scale: 2,
      translation: const Offset(20, 10),
      sourceSize: source,
    );
    expect(scaled.left, closeTo(130, 1e-6));
    expect(scaled.top, closeTo(140, 1e-6));
    expect(scaled.width, closeTo(100, 1e-6));
    expect(scaled.height, closeTo(100, 1e-6));
  });

  test('裁剪框与图片无交集时返回空矩形', () {
    expect(
      calculateCropSourceRect(
        cropRect: const Rect.fromLTWH(-500, -500, 10, 10),
        viewSize: const Size(400, 400),
        displaySize: const Size(200, 200),
        scale: 1,
        translation: Offset.zero,
        sourceSize: const Size(400, 400),
      ).isEmpty,
      isTrue,
    );
  });

  test('按原图像素矩形裁出 PNG 且尺寸正确', () {
    final img.Image source = img.Image(width: 100, height: 80);
    final Uint8List encoded = cropImageBytes(
      source,
      const Rect.fromLTWH(10, 10, 40, 20),
    );
    final img.Image? result = img.decodeImage(encoded);
    expect(result, isNotNull);
    expect(result!.width, 40);
    expect(result.height, 20);
  });

  testWidgets('头像裁剪页固定输出正方形图片', (WidgetTester tester) async {
    final Uint8List sample = img.encodePng(img.Image(width: 200, height: 120));
    Future<Uint8List?>? result;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => ElevatedButton(
          onPressed: () {
            result = showImageCropPage(
              context: context,
              bytes: sample,
              fileName: 'avatar.png',
              square: true,
            );
          },
          child: const Text('open crop'),
        ),
      ),
    ));
    await tester.tap(find.text('open crop'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('image-crop-page')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('image-crop-frame')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('image-crop-confirm')), findsOneWidget);

    // constrained=true 时图片应位于舞台正中，坐标反算才与裁剪框一致。
    final Rect imageRect = tester.getRect(find.byKey(const ValueKey<String>('image-crop-image')));
    final Rect stageRect = tester.getRect(find.byKey(const ValueKey<String>('image-crop-stage')));
    expect(imageRect.center.dx, closeTo(stageRect.center.dx, 1));
    expect(imageRect.center.dy, closeTo(stageRect.center.dy, 1));

    // 放大后仍按当前变换反算裁剪区域，结果应正常且保持方形。
    await tester.tap(find.byKey(const ValueKey<String>('image-crop-zoom-in')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('image-crop-confirm')));
    await tester.pumpAndSettle();

    final Uint8List? cropped = await result;
    expect(cropped, isNotNull);
    final img.Image? decoded = img.decodeImage(cropped!);
    expect(decoded, isNotNull);
    expect(decoded!.width, decoded.height);
  });

  test('图片坐标裁剪框直接反算原图像素', () {
    expect(
      localCropToSourceRect(
        cropRect: const Rect.fromLTWH(50, 50, 100, 100),
        displaySize: const Size(200, 200),
        sourceSize: const Size(400, 400),
      ),
      const Rect.fromLTWH(100, 100, 200, 200),
    );
  });

  Future<void> openCrop(
    WidgetTester tester, {
    required bool square,
  }) async {
    final Uint8List sample = img.encodePng(img.Image(width: 320, height: 200));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => ElevatedButton(
          onPressed: () => showImageCropPage(
            context: context,
            bytes: sample,
            fileName: square ? 'avatar.png' : 'promo.png',
            square: square,
          ),
          child: const Text('open crop'),
        ),
      ),
    ));
    await tester.tap(find.text('open crop'));
    await tester.pumpAndSettle();
  }

  testWidgets('裁剪框随图片缩放联动且手柄保持可点击尺寸', (WidgetTester tester) async {
    await openCrop(tester, square: false);

    final Rect stage = tester.getRect(
      find.byKey(const ValueKey<String>('image-crop-stage')),
    );
    final Offset handleBefore = tester.getCenter(
      find.byKey(const ValueKey<String>('image-crop-handle-topLeft')),
    );
    expect(
      tester.getRect(
        find.byKey(const ValueKey<String>('image-crop-handle-topLeft')),
      ).width,
      greaterThanOrEqualTo(24),
    );

    await tester.tap(find.byKey(const ValueKey<String>('image-crop-zoom-in')));
    await tester.pump();
    final Offset handleAfter = tester.getCenter(
      find.byKey(const ValueKey<String>('image-crop-handle-topLeft')),
    );
    expect(
      (handleAfter - stage.center).distance,
      greaterThan((handleBefore - stage.center).distance + 1),
    );
  });

  testWidgets('拖动裁剪框不会移出图片范围', (WidgetTester tester) async {
    await openCrop(tester, square: true);

    final Rect image = tester.getRect(
      find.byKey(const ValueKey<String>('image-crop-image')),
    );
    await tester.drag(
      find.byKey(const ValueKey<String>('image-crop-frame')),
      const Offset(600, 600),
    );
    await tester.pump();

    final Rect handle = tester.getRect(
      find.byKey(const ValueKey<String>('image-crop-handle-bottomRight')),
    );
    expect(handle.right, lessThanOrEqualTo(image.right + 13));
    expect(handle.bottom, lessThanOrEqualTo(image.bottom + 13));
  });

  testWidgets('推广图可切换比例，拖图模式可切换裁剪框交互', (WidgetTester tester) async {
    await openCrop(tester, square: false);

    await tester.tap(find.byKey(const ValueKey<String>('image-crop-aspect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1:1').last);
    await tester.pumpAndSettle();

    final Text label = tester.widget<Text>(
      find.byKey(const ValueKey<String>('image-crop-size-label')),
    );
    final List<String> parts = label.data!.split('×');
    expect(parts.length, 2);
    expect(parts[0], parts[1]);

    expect(
      find.byKey(const ValueKey<String>('image-crop-frame')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('image-crop-pan-mode')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('image-crop-frame')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('image-crop-pan-mode')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('image-crop-frame')),
      findsOneWidget,
    );
  });
}
