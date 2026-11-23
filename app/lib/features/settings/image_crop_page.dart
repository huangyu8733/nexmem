/// 跨端图片裁剪页（纯 Dart，无原生插件）。
///
/// 头像用固定 1:1 方形裁剪框，推广图用自由比例裁剪框；图片可拖动 / 缩放，
/// 裁剪框可移动并拖动四角调整。确认后按屏幕坐标反算原图像素并用 `image`
/// 包裁出结果，交给 `prepareProfileImage` 统一压缩为 JPEG/base64。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:image/image.dart' as img;

import '../../l10n/l10n.dart';

/// 打开裁剪页。返回裁剪后的 PNG 字节；取消返回 null。
Future<Uint8List?> showImageCropPage({
  required BuildContext context,
  required Uint8List bytes,
  required String fileName,
  required bool square,
}) {
  // 裁剪需要尽量大的操作区域：从右栏 / 嵌套导航里打开时也推到根导航全屏显示。
  return Navigator.of(context, rootNavigator: true).push<Uint8List>(
    MaterialPageRoute<Uint8List>(
      builder: (BuildContext context) => ImageCropPage(
        bytes: bytes,
        fileName: fileName,
        square: square,
      ),
    ),
  );
}

/// 把裁剪框的屏幕坐标反算为原图像素矩形。
///
/// [translation] 为 InteractiveViewer 控制器的平移量，[scale] 为其缩放倍数；
/// 图片以 contain 方式居中显示为 [displaySize]。返回空矩形表示裁剪框与图片
/// 没有交集。
Rect calculateCropSourceRect({
  required Rect cropRect,
  required Size viewSize,
  required Size displaySize,
  required double scale,
  required Offset translation,
  required Size sourceSize,
}) {
  if (scale <= 0 ||
      displaySize.width <= 0 ||
      displaySize.height <= 0 ||
      sourceSize.width <= 0 ||
      sourceSize.height <= 0) {
    return Rect.zero;
  }
  final Offset centerLocal = Offset(displaySize.width / 2, displaySize.height / 2);
  final Offset centerView = Offset(viewSize.width / 2, viewSize.height / 2);
  final Offset topLeft = centerLocal +
      (cropRect.topLeft - centerView - translation) / scale;
  final Offset bottomRight = centerLocal +
      (cropRect.bottomRight - centerView - translation) / scale;

  final Rect pixels = Rect.fromPoints(
    Offset(
      topLeft.dx / displaySize.width * sourceSize.width,
      topLeft.dy / displaySize.height * sourceSize.height,
    ),
    Offset(
      bottomRight.dx / displaySize.width * sourceSize.width,
      bottomRight.dy / displaySize.height * sourceSize.height,
    ),
  );
  final Rect clipped = pixels.intersect(Offset.zero & sourceSize);
  if (clipped.isEmpty || clipped.width < 1 || clipped.height < 1) {
    return Rect.zero;
  }
  return clipped;
}

/// 按原图像素矩形裁出图片，输出 PNG 字节（保留质量，压缩交给调用方）。
Uint8List cropImageBytes(img.Image source, Rect sourceRect) {
  final int maxX = source.width - 1;
  final int maxY = source.height - 1;
  final int x = math.max(0, math.min(sourceRect.left.round(), maxX));
  final int y = math.max(0, math.min(sourceRect.top.round(), maxY));
  final int width = math.max(
    1,
    math.min(sourceRect.width.round(), source.width - x),
  );
  final int height = math.max(
    1,
    math.min(sourceRect.height.round(), source.height - y),
  );
  return img.encodePng(img.copyCrop(
    source,
    x: x,
    y: y,
    width: width,
    height: height,
  ));
}

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

class ImageCropPage extends StatefulWidget {
  const ImageCropPage({
    super.key,
    required this.bytes,
    required this.fileName,
    required this.square,
  });

  final Uint8List bytes;
  final String fileName;
  final bool square;

  @override
  State<ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<ImageCropPage> {
  final TransformationController _controller = TransformationController();
  img.Image? _source;
  Size _viewSize = Size.zero;
  Size _displaySize = Size.zero;
  Rect _cropRect = Rect.zero;
  Rect _initialCropRect = Rect.zero;
  Rect _startRect = Rect.zero;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    try {
      _source = img.decodeImage(widget.bytes);
      if (_source == null) {
        _error = '无法识别该图片，请选择 PNG / JPG / BMP';
      }
    } on Object {
      _error = '无法识别该图片，请选择 PNG / JPG / BMP';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static double _clamp(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);

  void _initLayout(Size size) {
    if (_viewSize == size) {
      return;
    }
    final img.Image? source = _source;
    if (source == null) {
      return;
    }
    _viewSize = size;
    const double padding = 20;
    const double barSpace = 96;
    final double maxW = math.max(80, size.width - padding * 2);
    final double maxH = math.max(80, size.height - barSpace);
    final double aspect = source.width / source.height;
    final double displayW =
        aspect > maxW / maxH ? maxW : _clamp(maxH * aspect, 80, maxW);
    final double displayH = displayW / aspect;
    _displaySize = Size(displayW, displayH);

    final double side = math.min(maxW, maxH) * (widget.square ? 0.72 : 0.8);
    final Offset center = Offset(size.width / 2, (size.height - barSpace) / 2 + 24);
    _initialCropRect = widget.square
        ? Rect.fromCenter(center: center, width: side, height: side)
        : Rect.fromCenter(
            center: center,
            width: math.min(maxW, side * 1.4),
            height: side,
          );
    _cropRect = _initialCropRect;
  }

  void _beginGesture() => _startRect = _cropRect;

  void _move(Offset delta) {
    final Rect start = _startRect;
    setState(() {
      _cropRect = Rect.fromLTWH(
        _clamp(start.left + delta.dx, 0, _viewSize.width - start.width),
        _clamp(start.top + delta.dy, 0, _viewSize.height - start.height),
        start.width,
        start.height,
      );
    });
  }

  void _resize(_Corner corner, Offset delta) {
    final Rect start = _startRect;
    const double minSide = 64;
    setState(() {
      if (widget.square) {
        double wanted = start.width;
        double maxSide;
        double left = start.left;
        double top = start.top;
        switch (corner) {
          case _Corner.bottomRight:
            wanted += (delta.dx + delta.dy) / 2;
            maxSide = math.min(_viewSize.width - start.left, _viewSize.height - start.top);
            break;
          case _Corner.topLeft:
            wanted -= (delta.dx + delta.dy) / 2;
            maxSide = math.min(start.right, start.bottom);
            break;
          case _Corner.topRight:
            wanted += (delta.dx - delta.dy) / 2;
            maxSide = math.min(_viewSize.width - start.left, start.bottom);
            break;
          case _Corner.bottomLeft:
            wanted += (-delta.dx + delta.dy) / 2;
            maxSide = math.min(start.right, _viewSize.height - start.top);
            break;
        }
        final double side = _clamp(wanted, minSide, math.max(minSide, maxSide));
        switch (corner) {
          case _Corner.topLeft:
            left = start.right - side;
            top = start.bottom - side;
            break;
          case _Corner.topRight:
            top = start.bottom - side;
            break;
          case _Corner.bottomLeft:
            left = start.right - side;
            break;
          case _Corner.bottomRight:
            break;
        }
        _cropRect = Rect.fromLTWH(
          _clamp(left, 0, _viewSize.width - side),
          _clamp(top, 0, _viewSize.height - side),
          side,
          side,
        );
        return;
      }

      double left = start.left;
      double top = start.top;
      double right = start.right;
      double bottom = start.bottom;
      switch (corner) {
        case _Corner.topLeft:
          left = _clamp(start.left + delta.dx, 0, right - minSide);
          top = _clamp(start.top + delta.dy, 0, bottom - minSide);
          break;
        case _Corner.topRight:
          right = _clamp(start.right + delta.dx, left + minSide, _viewSize.width);
          top = _clamp(start.top + delta.dy, 0, bottom - minSide);
          break;
        case _Corner.bottomLeft:
          left = _clamp(start.left + delta.dx, 0, right - minSide);
          bottom = _clamp(
            start.bottom + delta.dy,
            top + minSide,
            _viewSize.height,
          );
          break;
        case _Corner.bottomRight:
          right = _clamp(
            start.right + delta.dx,
            left + minSide,
            _viewSize.width,
          );
          bottom = _clamp(
            start.bottom + delta.dy,
            top + minSide,
            _viewSize.height,
          );
          break;
      }
      _cropRect = Rect.fromLTRB(left, top, right, bottom);
    });
  }

  void _zoom(double factor) {
    final Matrix4 matrix = _controller.value.clone();
    final double current = matrix.getMaxScaleOnAxis();
    final double next = _clamp(current * factor, 0.5, 8);
    // 以舞台中心为缩放锚点，避免放大时图片整体跑向右下角。
    final double ratio = next / current;
    final Offset center = Offset(_viewSize.width / 2, _viewSize.height / 2);
    final double tx = center.dx + (matrix.storage[12] - center.dx) * ratio;
    final double ty = center.dy + (matrix.storage[13] - center.dy) * ratio;
    _controller.value = Matrix4.identity()
      ..scaleByDouble(next, next, 1, 1)
      ..setTranslationRaw(tx, ty, 0);
  }

  void _reset() {
    _controller.value = Matrix4.identity();
    setState(() => _cropRect = _initialCropRect);
  }

  Future<void> _confirm() async {
    final img.Image? source = _source;
    if (source == null || _busy) {
      return;
    }
    final Matrix4 matrix = _controller.value;
    final Rect rect = calculateCropSourceRect(
      cropRect: _cropRect,
      viewSize: _viewSize,
      displaySize: _displaySize,
      scale: matrix.getMaxScaleOnAxis(),
      translation: Offset(matrix.storage[12], matrix.storage[13]),
      sourceSize: Size(source.width.toDouble(), source.height.toDouble()),
    );
    if (rect.isEmpty) {
      setState(() => _error = '裁剪框未覆盖图片，请移动图片或裁剪框');
      return;
    }
    setState(() => _busy = true);
    try {
      final Uint8List result = cropImageBytes(source, rect);
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = '裁剪失败，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _handle(_Corner corner) {
    final Rect r = _cropRect;
    final Offset pos = switch (corner) {
      _Corner.topLeft => r.topLeft,
      _Corner.topRight => r.topRight,
      _Corner.bottomLeft => r.bottomLeft,
      _Corner.bottomRight => r.bottomRight,
    };
    return Positioned(
      left: pos.dx - 9,
      top: pos.dy - 9,
      width: 18,
      height: 18,
      child: GestureDetector(
        key: ValueKey<String>('image-crop-handle-${corner.name}'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _beginGesture(),
        onPanUpdate: (DragUpdateDetails details) =>
            _resize(corner, details.delta),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFF12B7F5), width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey<String>('image-crop-page'),
      appBar: AppBar(
        title: Text(context.t('裁剪')),
        leading: IconButton(
          key: const ValueKey<String>('image-crop-cancel'),
          icon: const Icon(Icons.close),
          tooltip: context.t('取消'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                _initLayout(constraints.biggest);
                return Stack(
                  key: const ValueKey<String>('image-crop-stage'),
                  children: <Widget>[
                    Positioned.fill(
                      child: InteractiveViewer(
                        key: const ValueKey<String>('image-crop-viewer'),
                        transformationController: _controller,
                        // 让 child 以整个舞台为坐标系，图片再由 Center 居中；
                        // 这样坐标反算可直接用舞台中心 + 控制器平移量。
                        constrained: true,
                        minScale: 0.5,
                        maxScale: 8,
                        child: Center(
                          child: SizedBox(
                            width: _displaySize.width,
                            height: _displaySize.height,
                            child: Image.memory(
                              widget.bytes,
                              key: const ValueKey<String>('image-crop-image'),
                              fit: BoxFit.fill,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _CropMaskPainter(_cropRect),
                        ),
                      ),
                    ),
                    Positioned(
                      left: _cropRect.left,
                      top: _cropRect.top,
                      width: _cropRect.width,
                      height: _cropRect.height,
                      child: GestureDetector(
                        key: const ValueKey<String>('image-crop-frame'),
                        behavior: HitTestBehavior.translucent,
                        onPanStart: (_) => _beginGesture(),
                        onPanUpdate: (DragUpdateDetails details) =>
                            _move(details.delta),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    _handle(_Corner.topLeft),
                    _handle(_Corner.topRight),
                    _handle(_Corner.bottomLeft),
                    _handle(_Corner.bottomRight),
                  ],
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              IconButton(
                key: const ValueKey<String>('image-crop-zoom-out'),
                icon: const Icon(Icons.zoom_out),
                tooltip: context.t('缩小'),
                onPressed: () => _zoom(1 / 1.25),
              ),
              IconButton(
                key: const ValueKey<String>('image-crop-zoom-in'),
                icon: const Icon(Icons.zoom_in),
                tooltip: context.t('放大'),
                onPressed: () => _zoom(1.25),
              ),
              IconButton(
                key: const ValueKey<String>('image-crop-reset'),
                icon: const Icon(Icons.restart_alt),
                tooltip: context.t('刷新'),
                onPressed: _reset,
              ),
              const Spacer(),
              FilledButton(
                key: const ValueKey<String>('image-crop-confirm'),
                onPressed: _busy ? null : _confirm,
                child: Text(context.t('保存')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CropMaskPainter extends CustomPainter {
  const _CropMaskPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final Path outer = Path()..addRect(Offset.zero & size);
    final Path inner = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawRect(rect, border);
    final Paint grid = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (int i = 1; i < 3; i++) {
      final double x = rect.left + rect.width * i / 3;
      final double y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _CropMaskPainter oldDelegate) =>
      oldDelegate.rect != rect;
}
