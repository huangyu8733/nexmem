import 'package:material_ui/material_ui.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

/// 连接状态，对应 ui-spec.md §7 顶部细状态条。
///
/// 统一使用品牌蓝呈现，仅以透明度区分状态强弱，避免灰/绿/橙混色显得杂乱。
enum LinkStatus {
  connecting('连接中', 0.55),
  online('在线', 1),
  relay('经中继', 0.8),
  offline('离线', 0.45);

  const LinkStatus(this.label, this.opacity);

  final String label;
  final double opacity;
}

/// 顶部细状态条：连接中 / 在线 / 经中继 / 离线。
/// `connecting` 对应内核状态机的 init/starting（A-05），避免启动过程静默无展示。
class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({super.key, required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color wash = isDark
        ? NexmemColors.primary.withValues(alpha: 0.18)
        : NexmemColors.primaryWash;
    final Color accent = NexmemColors.primary.withValues(alpha: status.opacity);
    // 文字保持可读：透明度设下限，浅色主题用加深蓝提升对比度。
    final Color textColor =
        (isDark ? NexmemColors.primary : NexmemColors.primaryDeep)
            .withValues(alpha: status.opacity < 0.72 ? 0.72 : status.opacity);
    return Container(
      height: 26,
      width: double.infinity,
      color: wash,
      padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space16),
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: accent.withValues(alpha: 0.45),
                  blurRadius: 5,
                ),
              ],
            ),
          ),
          const SizedBox(width: NexmemMetrics.space8),
          Text(
            context.t(status.label),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
          ),
        ],
      ),
    );
  }
}
