/// 跨端图片裁剪页（纯 Dart，无原生插件）。
///
/// 头像用固定 1:1 方形裁剪框，推广图支持自由 / 1:1 / 4:3 / 16:9 比例。
/// 裁剪框存放在「图片显示坐标系」中，随 InteractiveViewer 的缩放 / 平移
/// 一起变换，所见即所得；手柄在屏幕层绘制，始终保持一致的可点击尺寸。
/// 确认后直接把图片坐标反算为原图像素，交给 `prepareProfileImage` 压缩。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:image/image.dart' as img;

import '../../l10n/l10n.dart';
import '../../app/theme.dart';

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

/// 把屏幕坐标的裁剪框反算为原图像素矩形（兼容旧调用与测试）。
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

/// 把图片显示坐标系中的裁剪框反算为原图像素矩形。
Rect localCropToSourceRect({
  required Rect cropRect,
  required Size displaySize,
  required Size sourceSize,
}) {
  if (displaySize.width <= 0 ||
      displaySize.height <= 0 ||
      sourceSize.width <= 0 ||
      sourceSize.height <= 0) {
    return Rect.zero;
  }
  final Rect pixels = Rect.fromLTWH(
    cropRect.left / displaySize.width * sourceSize.width,
    cropRect.top / displaySize.height * sourceSize.height,
    cropRect.width / displaySize.width * sourceSize.width,
    cropRect.height / displaySize.height * sourceSize.height,
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

/// 群等级图标尺寸：固定 64x64 PNG。
const int kLevelIconSize = 64;

/// 自动居中裁剪并缩放为 [size] x [size] 的 PNG 字节。
///
/// 群等级图标使用「自动裁剪」：用户只需选图，不做二次交互；先取图片中心最大
/// 正方形，再高质量缩放到目标尺寸。非法图片抛 [FormatException]。
Uint8List prepareSquarePng(Uint8List bytes, {int size = kLevelIconSize}) {
  if (size <= 0) {
    throw const FormatException('图标尺寸必须大于 0');
  }
  final img.Image? source = img.decodeImage(bytes);
  if (source == null || source.width < 1 || source.height < 1) {
    throw const FormatException('无法解码图片');
  }
  final int side = math.min(source.width, source.height);
  final int x = (source.width - side) >> 1;
  final int y = (source.height - side) >> 1;
  final img.Image cropped = img.copyCrop(
    source,
    x: x,
    y: y,
    width: side,
    height: side,
  );
  final img.Image resized = img.copyResize(
    cropped,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );
  return img.encodePng(resized);
}

/// 群头像边长：固定 512x512 正方形。
const int kGroupAvatarSize = 512;

/// 群头像 base64 上限，与内核 `MaxGroupAvatarBase64Chars` 保持一致。
const int kGroupAvatarMaxBase64Chars = 320 << 10;

/// 把裁剪后的图片居中裁成正方形并缩放为 512x512 JPEG。
///
/// 交互裁剪页已经让用户选定区域；这里再做一次中心正方形归一化，保证任何
/// 来源都严格输出 512x512。按质量从高到低编码，确保 base64 不超过群控制帧上限。
Uint8List prepareGroupAvatarJpeg(Uint8List bytes) {
  final img.Image? source = img.decodeImage(bytes);
  if (source == null || source.width < 1 || source.height < 1) {
    throw const FormatException('无法解码图片');
  }
  final int side = math.min(source.width, source.height);
  final img.Image cropped = img.copyCrop(
    source,
    x: (source.width - side) >> 1,
    y: (source.height - side) >> 1,
    width: side,
    height: side,
  );
  final img.Image resized = img.copyResize(
    cropped,
    width: kGroupAvatarSize,
    height: kGroupAvatarSize,
    interpolation: img.Interpolation.average,
  );
  for (final int quality in <int>[88, 80, 72, 64, 56]) {
    final Uint8List encoded = img.encodeJpg(resized, quality: quality);
    if (base64Encode(encoded).length <= kGroupAvatarMaxBase64Chars) {
      return encoded;
    }
  }
  throw const FormatException('图片压缩后仍过大，请换一张更小的图片');
}

enum _Handle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right,
}

extension _HandleX on _Handle {
  bool get isCorner =>
      this == _Handle.topLeft ||
      this == _Handle.topRight ||
      this == _Handle.bottomLeft ||
      this == _Handle.bottomRight;
}

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

  /// 裁剪框位于图片显示坐标系，范围恒在 [0, 0, displaySize] 内。
  Rect _cropRect = Rect.zero;
  Rect _initialCropRect = Rect.zero;
  Rect _startRect = Rect.zero;

  /// 0 表示自由比例；头像固定 1。
  double _aspect = 0;
  bool _panImageMode = false;
  String? _error;
  bool _busy = false;

  double get _scale => _controller.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _aspect = widget.square ? 1 : 0;
    // 图片的缩放 / 平移由 InteractiveViewer 改写到控制器上，覆盖层（裁剪框、
    // 手柄与遮罩）不在 InteractiveViewer 子树里，必须主动监听并重绘才能联动。
    _controller.addListener(_onTransformChanged);
    try {
      _source = img.decodeImage(widget.bytes);
      if (_source == null) {
        _error = '无法识别该图片，请选择 PNG / JPG / BMP';
      }
    } on Object {
      _error = '无法识别该图片，请选择 PNG / JPG / BMP';
    }
  }

  void _onTransformChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransformChanged);
    _controller.dispose();
    super.dispose();
  }

  static double _clamp(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);

  Rect _makeInitialRect() {
    final double width = _displaySize.width;
    final double height = _displaySize.height;
    if (width <= 0 || height <= 0) {
      return Rect.zero;
    }
    double cropW = width * 0.76;
    double cropH = height * 0.76;
    if (_aspect > 0) {
      if (cropW / cropH > _aspect) {
        cropW = cropH * _aspect;
      } else {
        cropH = cropW / _aspect;
      }
    }
    cropW = math.max(32, cropW);
    cropH = math.max(32, cropH);
    return Rect.fromCenter(
      center: Offset(width / 2, height / 2),
      width: math.min(cropW, width),
      height: math.min(cropH, height),
    );
  }

  void _initLayout(Size size) {
    if (_viewSize == size) {
      return;
    }
    final img.Image? source = _source;
    if (source == null) {
      return;
    }
    _viewSize = size;
    // body 已经排除了 AppBar 与 bottomNavigationBar，不能再扣减底部栏高度，
    // 否则图片会明显偏上、下方留一大块空白。
    const double padding = 16;
    final double maxW = math.max(80, size.width - padding * 2);
    final double maxH = math.max(80, size.height - padding * 2);
    final double aspect = source.width / source.height;
    final double displayW =
        aspect > maxW / maxH ? maxW : _clamp(maxH * aspect, 80, maxW);
    _displaySize = Size(displayW, displayW / aspect);
    _initialCropRect = _makeInitialRect();
    _cropRect = _initialCropRect;
    _startRect = _cropRect;
  }

  /// 裁剪框在舞台（屏幕）中的矩形，用于绘制遮罩、边框与手柄。
  Rect get _viewCropRect {
    if (_displaySize.isEmpty || _cropRect.isEmpty) {
      return Rect.zero;
    }
    final Matrix4 matrix = _controller.value;
    final double scale = matrix.getMaxScaleOnAxis();
    final Offset translation = Offset(matrix.storage[12], matrix.storage[13]);
    final Offset centerView = Offset(_viewSize.width / 2, _viewSize.height / 2);
    final Offset centerLocal =
        Offset(_displaySize.width / 2, _displaySize.height / 2);
    final Offset topLeft = centerView +
        translation +
        (_cropRect.topLeft - centerLocal) * scale;
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      _cropRect.width * scale,
      _cropRect.height * scale,
    );
  }

  void _beginGesture() => _startRect = _cropRect;

  Offset _localDelta(Offset viewDelta) => viewDelta / _scale;

  void _move(Offset viewDelta) {
    final Rect start = _startRect;
    final Offset delta = _localDelta(viewDelta);
    setState(() {
      _cropRect = Rect.fromLTWH(
        _clamp(start.left + delta.dx, 0, _displaySize.width - start.width),
        _clamp(start.top + delta.dy, 0, _displaySize.height - start.height),
        start.width,
        start.height,
      );
    });
  }

  void _resize(_Handle handle, Offset viewDelta) {
    final Rect start = _startRect;
    final Offset delta = _localDelta(viewDelta);
    final double minSide = math.min(
      48,
      math.min(_displaySize.width, _displaySize.height) * 0.2,
    );
    setState(() {
      if (_aspect > 0 && handle.isCorner) {
        // 固定比例：以对角为锚点等比缩放，并限制在图片范围内。
        final bool toRight = handle == _Handle.topRight ||
            handle == _Handle.bottomRight;
        final bool toBottom = handle == _Handle.bottomLeft ||
            handle == _Handle.bottomRight;
        final Offset anchor = toRight
            ? (toBottom ? start.topLeft : start.bottomLeft)
            : (toBottom ? start.topRight : start.bottomRight);
        double wantedW = start.width + (toRight ? delta.dx : -delta.dx);
        double wantedH = start.height + (toBottom ? delta.dy : -delta.dy);
        if (wantedW / wantedH > _aspect) {
          wantedH = wantedW / _aspect;
        } else {
          wantedW = wantedH * _aspect;
        }
        final double maxW = toRight
            ? _displaySize.width - anchor.dx
            : anchor.dx;
        final double maxH = toBottom
            ? _displaySize.height - anchor.dy
            : anchor.dy;
        final double limit = math.min(maxW, maxH / _aspect);
        wantedW = _clamp(wantedW, minSide, math.max(minSide, limit));
        wantedH = wantedW / _aspect;
        _cropRect = Rect.fromLTWH(
          toRight ? anchor.dx : anchor.dx - wantedW,
          toBottom ? anchor.dy : anchor.dy - wantedH,
          wantedW,
          wantedH,
        );
        return;
      }

      double left = start.left;
      double top = start.top;
      double right = start.right;
      double bottom = start.bottom;
      switch (handle) {
        case _Handle.topLeft:
          left = _clamp(start.left + delta.dx, 0, right - minSide);
          top = _clamp(start.top + delta.dy, 0, bottom - minSide);
        case _Handle.topRight:
          right = _clamp(start.right + delta.dx, left + minSide, _displaySize.width);
          top = _clamp(start.top + delta.dy, 0, bottom - minSide);
        case _Handle.bottomLeft:
          left = _clamp(start.left + delta.dx, 0, right - minSide);
          bottom = _clamp(
            start.bottom + delta.dy,
            top + minSide,
            _displaySize.height,
          );
        case _Handle.bottomRight:
          right = _clamp(
            start.right + delta.dx,
            left + minSide,
            _displaySize.width,
          );
          bottom = _clamp(
            start.bottom + delta.dy,
            top + minSide,
            _displaySize.height,
          );
        case _Handle.top:
          top = _clamp(start.top + delta.dy, 0, bottom - minSide);
        case _Handle.bottom:
          bottom = _clamp(
            start.bottom + delta.dy,
            top + minSide,
            _displaySize.height,
          );
        case _Handle.left:
          left = _clamp(start.left + delta.dx, 0, right - minSide);
        case _Handle.right:
          right = _clamp(
            start.right + delta.dx,
            left + minSide,
            _displaySize.width,
          );
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

  void _setAspect(double? aspect) {
    setState(() {
      _aspect = aspect ?? 0;
      _controller.value = Matrix4.identity();
      _initialCropRect = _makeInitialRect();
      _cropRect = _initialCropRect;
      _startRect = _cropRect;
    });
  }

  Future<void> _confirm() async {
    final img.Image? source = _source;
    if (source == null || _busy) {
      return;
    }
    final Rect rect = localCropToSourceRect(
      cropRect: _cropRect,
      displaySize: _displaySize,
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

  Widget _handle(_Handle handle) {
    final Offset pos = switch (handle) {
      _Handle.topLeft => _viewCropRect.topLeft,
      _Handle.topRight => _viewCropRect.topRight,
      _Handle.bottomLeft => _viewCropRect.bottomLeft,
      _Handle.bottomRight => _viewCropRect.bottomRight,
      _Handle.top => Offset(_viewCropRect.center.dx, _viewCropRect.top),
      _Handle.bottom => Offset(_viewCropRect.center.dx, _viewCropRect.bottom),
      _Handle.left => Offset(_viewCropRect.left, _viewCropRect.center.dy),
      _Handle.right => Offset(_viewCropRect.right, _viewCropRect.center.dy),
    };
    // 视觉手柄 24px，但触控区扩到 44px，否则手指很难精确拖到四角。
    const double visual = 24;
    const double hit = 44;
    return Positioned(
      left: pos.dx - hit / 2,
      top: pos.dy - hit / 2,
      width: hit,
      height: hit,
      child: GestureDetector(
        key: ValueKey<String>('image-crop-handle-${handle.name}'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _beginGesture(),
        onPanUpdate: (DragUpdateDetails details) =>
            _resize(handle, details.delta),
        child: Center(
          child: Container(
            width: visual,
            height: visual,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: NexmemColors.primary, width: 2),
              borderRadius: BorderRadius.circular(5),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sizeLabel(Size sourceSize) {
    final Rect rect = _viewCropRect;
    if (rect.isEmpty) {
      return const SizedBox.shrink();
    }
    final int width = (_cropRect.width / _displaySize.width * sourceSize.width)
        .round();
    final int height =
        (_cropRect.height / _displaySize.height * sourceSize.height).round();
    final double top = rect.top >= 26 ? rect.top - 24 : rect.top + 4;
    return Positioned(
      left: rect.left,
      top: top,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '$width×$height',
          key: const ValueKey<String>('image-crop-size-label'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            height: 1.2,
          ),
        ),
      ),
    );
  }

  List<_Handle> get _handles {
    if (_aspect > 0) {
      return const <_Handle>[
        _Handle.topLeft,
        _Handle.topRight,
        _Handle.bottomLeft,
        _Handle.bottomRight,
      ];
    }
    return _Handle.values;
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
                  context.t(_error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                _initLayout(constraints.biggest);
                final img.Image? source = _source;
                final Rect viewRect = _viewCropRect;
                final List<Widget> handles = <Widget>[
                  for (final _Handle handle in _handles) _handle(handle),
                ];
                return Stack(
                  key: const ValueKey<String>('image-crop-stage'),
                  children: <Widget>[
                    Positioned.fill(
                      child: InteractiveViewer(
                        key: const ValueKey<String>('image-crop-viewer'),
                        transformationController: _controller,
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
                          key: const ValueKey<String>('image-crop-mask'),
                          painter: _CropMaskPainter(viewRect),
                        ),
                      ),
                    ),
                    if (!_panImageMode)
                      Positioned(
                        left: viewRect.left,
                        top: viewRect.top,
                        width: viewRect.width,
                        height: viewRect.height,
                        child: GestureDetector(
                          key: const ValueKey<String>('image-crop-frame'),
                          behavior: HitTestBehavior.translucent,
                          onPanStart: (_) => _beginGesture(),
                          onPanUpdate: (DragUpdateDetails details) =>
                              _move(details.delta),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    if (!_panImageMode) ...handles,
                    if (source != null) _sizeLabel(Size(source.width.toDouble(), source.height.toDouble())),
                  ],
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
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
                if (!widget.square)
                  PopupMenuButton<double>(
                    key: const ValueKey<String>('image-crop-aspect'),
                    tooltip: context.t('比例'),
                    icon: const Icon(Icons.aspect_ratio),
                    onSelected: _setAspect,
                    itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
                      PopupMenuItem<double>(
                        value: 0,
                        child: Text(context.t('自由')),
                      ),
                      const PopupMenuItem<double>(
                        value: 1,
                        child: Text('1:1'),
                      ),
                      const PopupMenuItem<double>(
                        value: 4 / 3,
                        child: Text('4:3'),
                      ),
                      const PopupMenuItem<double>(
                        value: 16 / 9,
                        child: Text('16:9'),
                      ),
                    ],
                  ),
                IconButton(
                  key: const ValueKey<String>('image-crop-pan-mode'),
                  icon: Icon(
                    _panImageMode ? Icons.crop_rotate : Icons.pan_tool_alt,
                  ),
                  tooltip: _panImageMode ? context.t('裁剪框') : context.t('拖图'),
                  onPressed: () =>
                      setState(() => _panImageMode = !_panImageMode),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey<String>('image-crop-confirm'),
                  onPressed: _busy ? null : _confirm,
                  child: Text(context.t('保存')),
                ),
              ],
            ),
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
    if (rect.isEmpty) {
      return;
    }
    final Path outer = Path()..addRect(Offset.zero & size);
    final Path inner = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawRect(rect, border);
    final Paint grid = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white.withValues(alpha: 0.4)
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
