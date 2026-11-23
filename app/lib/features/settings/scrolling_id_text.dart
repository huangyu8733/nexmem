import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

/// 单行完整展示长 ID，超出可视宽度时用左右小箭头平移，不引入滚动条。
///
/// 账号与设备 ID 可能是 64 位十六进制 / PeerID，换行会撑破卡片、截断又看不到完整值。
/// 这里用 [Transform.translate] 手动平移：整行不是 Scrollable，因此不会出现滚动条。
/// ID 固定按 LTR 阅读，箭头按物理方向排列，不受 RTL 布局镜像影响。
class ScrollingIdText extends StatefulWidget {
  const ScrollingIdText({
    super.key,
    required this.text,
    required this.keyName,
    this.label,
    this.onCopy,
    this.copyKeyName,
    this.style = const TextStyle(fontSize: 12),
  });

  /// 完整文本（不截断）。
  final String text;

  /// SelectableText 的 ValueKey；箭头键为 `<keyName>-prev` / `<keyName>-next`。
  final String keyName;

  /// 可选行首标签，如「账号」/「设备」。
  final String? label;

  /// 可选复制回调；为空时不显示复制按钮。
  final VoidCallback? onCopy;

  /// 复制按钮的 ValueKey；默认 `<keyName>-copy`。
  final String? copyKeyName;

  final TextStyle style;

  @override
  State<ScrollingIdText> createState() => _ScrollingIdTextState();
}

class _ScrollingIdTextState extends State<ScrollingIdText> {
  static const double _arrowSize = 22;
  static const double _step = 120;

  double _offset = 0;

  @override
  void didUpdateWidget(covariant ScrollingIdText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _offset = 0;
    }
  }

  double _measureTextWidth() {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  void _move({required bool forward, required double maxOffset}) {
    setState(() {
      final double next = _offset + (forward ? _step : -_step);
      _offset = next.clamp(0.0, maxOffset).toDouble();
    });
  }

  Widget _arrow({
    required bool forward,
    required bool enabled,
    required double maxOffset,
  }) {
    return SizedBox(
      width: _arrowSize,
      height: _arrowSize,
      child: IconButton(
        key: ValueKey<String>(
          forward ? '${widget.keyName}-next' : '${widget.keyName}-prev',
        ),
        onPressed: enabled
            ? () => _move(forward: forward, maxOffset: maxOffset)
            : null,
        icon: Icon(
          forward ? Icons.chevron_right : Icons.chevron_left,
          size: 16,
        ),
        tooltip: context.t(forward ? '向右移动' : '向左移动'),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double viewport = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        final double maxOffset = (_measureTextWidth() - viewport)
            .clamp(0.0, double.infinity)
            .toDouble();
        return Row(
          textDirection: TextDirection.ltr,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (widget.label case final String label)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            Expanded(
              child: Row(
                textDirection: TextDirection.ltr,
                children: <Widget>[
                  _arrow(
                    forward: false,
                    enabled: maxOffset > 0 && _offset > 0,
                    maxOffset: maxOffset,
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 20,
                      child: ClipRect(
                        child: Transform.translate(
                          offset: Offset(-_offset, 0),
                          child: SelectableText(
                            widget.text,
                            key: ValueKey<String>(widget.keyName),
                            style: widget.style,
                            maxLines: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _arrow(
                    forward: true,
                    enabled: maxOffset > 0 && _offset < maxOffset,
                    maxOffset: maxOffset,
                  ),
                ],
              ),
            ),
            if (widget.onCopy case final VoidCallback onCopy)
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  key: ValueKey<String>(widget.copyKeyName ?? '${widget.keyName}-copy'),
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                  tooltip: context.t('复制'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
