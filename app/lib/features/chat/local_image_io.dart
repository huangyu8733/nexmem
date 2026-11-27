import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// 桌面 / 移动端本机图片缩略图；文件缺失或解码失败时显示占位图标。
class LocalImage extends StatelessWidget {
  const LocalImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.sourceUri,
  });

  final String path;

  /// Web 在线播放源；桌面/移动端不使用，保留参数只为两端构造签名一致。
  final Uri? sourceUri;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = _fallback(context);
    if (path.isEmpty) {
      return fallback;
    }
    return Image.file(
      File(path),
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          fallback,
    );
  }

  Widget _fallback(BuildContext context) {
    final Color muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.4);
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
        child: Center(
          child: Icon(Icons.image_not_supported_outlined, size: 32, color: muted),
        ),
      ),
    );
  }
}
