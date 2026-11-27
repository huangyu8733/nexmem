import 'package:material_ui/material_ui.dart';

/// Web 端图片气泡：有鉴权播放源时直接 `Image.network` 显示，否则占位。
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
  final Uri? sourceUri;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (sourceUri != null) {
      return Image.network(
        sourceUri!.toString(),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _placeholder(context),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
        child: Center(
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 32,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
