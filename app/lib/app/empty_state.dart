import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 空态占位，统一字号与留白（ui-spec.md §8）。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  NexmemColors.railTop,
                  NexmemColors.railBottom,
                ],
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: NexmemColors.primary.withValues(alpha: 0.25),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(icon, size: 44, color: Colors.white),
          ),
          const SizedBox(height: NexmemMetrics.space16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(height: NexmemMetrics.space16),
            action!,
          ],
        ],
      ),
    );
  }
}
