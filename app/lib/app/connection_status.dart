import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 连接状态，对应 ui-spec.md §7 顶部细状态条。
enum LinkStatus {
  connecting('连接中', NexmemColors.warning),
  online('在线', NexmemColors.success),
  relay('经中继', NexmemColors.warning),
  offline('离线', NexmemColors.lightTextSecondary);

  const LinkStatus(this.label, this.color);

  final String label;
  final Color color;
}

/// 顶部细状态条：连接中 / 在线 / 经中继 / 离线。
/// `connecting` 对应内核状态机的 init/starting（A-05），避免启动过程静默无展示。
class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({super.key, required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 24,
      width: double.infinity,
      color: scheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space12),
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: status.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: NexmemMetrics.space8),
          Text(
            status.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.7),
                ),
          ),
        ],
      ),
    );
  }
}
