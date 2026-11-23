/// Nexmem 品牌标识的 Flutter 绘制版本。
///
/// 与 `assets/nexmem_icon.svg` / `app/web/favicon.svg` 使用同一套几何与配色，
/// 不依赖额外图片插件，桌面 / Web / 移动端均可直接绘制。
library;

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 圆角方形 N 字标：两端节点经中央记忆核心相连。
class NexmemMark extends StatelessWidget {
  const NexmemMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Nexmem',
      container: true,
      child: SizedBox(
        key: const ValueKey<String>('nexmem-logo-mark'),
        width: size,
        height: size,
        child: CustomPaint(painter: const _NexmemMarkPainter()),
      ),
    );
  }
}

class _NexmemMarkPainter extends CustomPainter {
  const _NexmemMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width;
    if (s <= 0) {
      return;
    }

    final Rect bounds = Offset.zero & Size(s, s);
    final RRect background = RRect.fromRectAndRadius(
      bounds,
      Radius.circular(s * 0.22),
    );
    const LinearGradient gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[Color(0xFF35D0FF), Color(0xFF0A78C8)],
    );
    canvas.drawRRect(
      background,
      Paint()..shader = gradient.createShader(bounds),
    );

    canvas.drawCircle(
      Offset(s * 0.79, s * 0.20),
      s * 0.14,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.08),
    );

    final Paint line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.078
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final Path n = Path()
      ..moveTo(s * 0.328, s * 0.672)
      ..lineTo(s * 0.328, s * 0.328)
      ..lineTo(s * 0.672, s * 0.672)
      ..lineTo(s * 0.672, s * 0.328);
    canvas.drawPath(n, line);

    final Paint dot = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(s * 0.328, s * 0.328), s * 0.043, dot);
    canvas.drawCircle(Offset(s * 0.672, s * 0.672), s * 0.043, dot);
    canvas.drawCircle(Offset(s * 0.5, s * 0.5), s * 0.037, dot);
    canvas.drawCircle(
      Offset(s * 0.5, s * 0.5),
      s * 0.0156,
      Paint()..color = const Color(0xFF0A78C8),
    );
  }

  @override
  bool shouldRepaint(covariant _NexmemMarkPainter oldDelegate) => false;
}

/// 图标 + 本地化应用名，供「关于」等品牌位置复用。
class NexmemBrand extends StatelessWidget {
  const NexmemBrand({
    super.key,
    required this.name,
    this.markSize = 48,
    this.subtitle,
  });

  final String name;
  final double markSize;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final TextStyle? titleStyle = Theme.of(context).textTheme.titleLarge;
    return Row(
      key: const ValueKey<String>('nexmem-brand'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NexmemMark(size: markSize),
        SizedBox(width: NexmemMetrics.space12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              name,
              style: (titleStyle ?? const TextStyle(fontSize: 20)).copyWith(
                fontWeight: FontWeight.w700,
                color: NexmemColors.primary,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
