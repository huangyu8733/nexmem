import 'package:material_ui/material_ui.dart';

/// Web 端占位：浏览器无法读取服务端本机路径，仅提示图片不可预览。
class LocalImage extends StatelessWidget {
  const LocalImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
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
