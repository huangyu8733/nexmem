import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/empty_state.dart';
import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../chats/conversation.dart';
import 'message_search.dart';

/// 本地消息搜索页（P6-07）：输入即搜（250ms 防抖），命中按时间倒序，
/// 关键词高亮，点击结果回到对应会话。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.service,
    this.onOpen,
    this.titleOf,
    this.conversationIds = const <String>[],
    this.debounce = const Duration(milliseconds: 250),
  });

  final MessageSearchService service;

  /// 点击命中后的跳转回调；由列表页负责关闭本页并打开会话。
  final ValueChanged<SearchHit>? onOpen;

  /// 会话 ID → 展示标题；缺省直接展示会话 ID。
  final String Function(String conversationId)? titleOf;

  /// 可筛选的会话 ID 列表（P6-33）；非空时在搜索框下方展示「全部 + 各会话」
  /// 筛选条，选中后只在该会话内检索。为空时不展示筛选条（向后兼容）。
  final List<String> conversationIds;

  /// 输入停止多久后发起检索，便于测试注入更短的时间。
  final Duration debounce;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// 请求代次：只接受最新一次检索的结果，避免慢请求覆盖新关键词。
  int _generation = 0;

  String _query = '';
  String _conversationId = '';
  bool _loading = false;
  String? _error;
  List<SearchHit> _hits = const <SearchHit>[];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final String query = value.trim();
    setState(() {
      _query = query;
      _error = null;
      if (query.isEmpty) {
        _hits = const <SearchHit>[];
        _loading = false;
      }
    });
    if (query.isEmpty) {
      return;
    }
    _debounce = Timer(widget.debounce, () => _run(query));
  }

  Future<void> _run(String query) async {
    if (query.isEmpty) {
      return;
    }
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<SearchHit> hits = await widget.service.search(
        query,
        conversationId: _conversationId,
      );
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } on NexmemException catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _hits = const <SearchHit>[];
        _loading = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _hits = const <SearchHit>[];
        _loading = false;
        _error = context.t('搜索失败：{0}', [error]);
      });
    }
  }

  void _onFilterChanged(String conversationId) {
    if (conversationId == _conversationId) {
      return;
    }
    setState(() {
      _conversationId = conversationId;
    });
    if (_query.isNotEmpty) {
      _run(_query);
    }
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _query = '';
      _conversationId = '';
      _hits = const <SearchHit>[];
      _loading = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // `Esc` 返回会话列表（ui-spec.md §9）。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
      appBar: AppBar(
        leading: Navigator.of(context).canPop()
            ? IconButton(
                tooltip: context.t('返回'),
                icon: const Icon(Icons.arrow_back, size: 22),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        titleSpacing: 0,
        title: SizedBox(
          height: 36,
          child: TextField(
            key: const Key('search-field'),
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (String value) {
              _debounce?.cancel();
              _run(value.trim());
            },
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: context.t('搜索聊天记录'),
              hintStyle: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.4),
                fontSize: 14,
              ),
              prefixIcon: Icon(
                Icons.search,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.t('清除'),
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: _clear,
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                vertical: NexmemMetrics.space8,
              ),
              filled: true,
              fillColor: scheme.onSurface.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(NexmemMetrics.radiusListItem),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        actions: const <Widget>[SizedBox(width: NexmemMetrics.space8)],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (widget.conversationIds.isNotEmpty) _buildFilterBar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      ),
    );
  }

  /// 「全部 + 各会话」横向筛选条（P6-33）。
  Widget _buildFilterBar() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        key: const Key('search-filter-bar'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space16),
        itemCount: widget.conversationIds.length + 1,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: NexmemMetrics.space8),
        itemBuilder: (BuildContext context, int index) {
          final bool all = index == 0;
          final String id = all ? '' : widget.conversationIds[index - 1];
          final bool selected = id == _conversationId;
          final String label = all
              ? context.t('全部')
              : (widget.titleOf?.call(id) ?? id);
          return Center(
            child: ChoiceChip(
              key: ValueKey<String>('search-filter-$id'),
              label: Text(label),
              selected: selected,
              showCheckmark: false,
              onSelected: (_) => _onFilterChanged(id),
              visualDensity: VisualDensity.compact,
              selectedColor: scheme.primary.withValues(alpha: 0.16),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_query.isEmpty) {
      return EmptyState(
        icon: Icons.search,
        message: context.t('输入关键词搜索聊天记录'),
      );
    }
    if (_loading) {
      return const Center(child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ));
    }
    final String? error = _error;
    if (error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        message: error,
        action: TextButton(
          onPressed: () => _run(_query),
          child: Text(context.t('重试')),
        ),
      );
    }
    if (_hits.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        message: context.t('没有找到相关消息'),
      );
    }
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1, indent: NexmemMetrics.space16),
      itemBuilder: (BuildContext context, int index) {
        final SearchHit hit = _hits[index];
        return SearchHitTile(
          key: ValueKey<String>('search-hit-${hit.msgUuid}'),
          hit: hit,
          title: widget.titleOf?.call(hit.conversationId) ?? hit.conversationId,
          onTap: widget.onOpen == null ? null : () => widget.onOpen!(hit),
        );
      },
    );
  }
}

/// 单条搜索结果：会话标题 + 时间 + 高亮片段。
class SearchHitTile extends StatelessWidget {
  const SearchHitTile({
    super.key,
    required this.hit,
    required this.title,
    this.onTap,
  });

  final SearchHit hit;
  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? secondary = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 12,
          color: scheme.onSurface.withValues(alpha: 0.5),
        );
    final TextStyle base = Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              color: scheme.onSurface.withValues(alpha: 0.75),
            ) ??
        const TextStyle(fontSize: 14);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NexmemMetrics.space16,
          vertical: NexmemMetrics.space12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                const SizedBox(width: NexmemMetrics.space8),
                Text(formatConversationTime(hit.sentAtTime), style: secondary),
              ],
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  for (final SnippetSegment segment in hit.snippetSegments)
                    TextSpan(
                      text: segment.text,
                      style: segment.highlight
                          ? base.copyWith(
                              color: NexmemColors.primary,
                              fontWeight: FontWeight.w600,
                            )
                          : base,
                    ),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
