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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(
            color: scheme.onSurface.withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: NexmemMetrics.space16),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
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
      height: 36,
      margin: const EdgeInsets.symmetric(
        horizontal: NexmemMetrics.space12,
        vertical: NexmemMetrics.space8,
      ),
      padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space12),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.04),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.search,
            size: 18,
            color: scheme.onSurface.withValues(alpha: 0.45),
          ),
          const SizedBox(width: NexmemMetrics.space8),
          Text(
            context.t(hint),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.45),
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
