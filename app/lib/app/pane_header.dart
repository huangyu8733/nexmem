import 'package:material_ui/material_ui.dart';

import '../l10n/l10n.dart';
import 'theme.dart';

/// 列表区顶部栏：标题 + 右侧操作（ui-spec.md §2）。
class PaneHeader extends StatelessWidget {
  const PaneHeader({super.key, required this.title, this.actions = const <Widget>[]});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: <Widget>[
          const SizedBox(width: NexmemMetrics.space16),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          ...actions,
          const SizedBox(width: NexmemMetrics.space4),
        ],
      ),
    );
  }
}

/// 顶部搜索框：会话与联系人均复用；[onTap] 非空时可进入搜索页。
class SearchBox extends StatelessWidget {
  const SearchBox({super.key, this.hint = '搜索', this.onTap});

  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget box = Container(
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space12),
      padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space8),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 16, color: scheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(width: NexmemMetrics.space4),
          Text(
            context.t(hint),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return box;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
      child: box,
    );
  }
}
