import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/avatar.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../chats/start_chat_sheet.dart';
import 'group_service.dart';

/// 群聊列表页（P4-13，ui-spec.md §4 通讯录「群聊」分组）。
///
/// 数据源为 `group.list`：展示群名、成员数与本人角色，点击回调由壳层打开群会话；
/// 群盘未配置的群给出明确标识，与聊天页「离线消息不可补」提示保持一致。
class GroupListPage extends StatefulWidget {
  const GroupListPage({
    super.key,
    required this.service,
    this.onOpenGroup,
    this.onGroupCreated,
    this.embedded = false,
  });

  final GroupService service;

  /// 点击群聊时回调 `(groupId, title)`，由调用方打开群会话。
  final void Function(String groupId, String title)? onOpenGroup;

  /// 创建空群成功后回调 `(groupId, title)`，由调用方打开新群会话。
  final void Function(String groupId, String title)? onGroupCreated;

  /// 为 true 时以面板形式渲染（供桌面右栏 / 手机全屏页复用），
  /// 不套 Scaffold、不在打开群聊时 pop 外层路由。
  final bool embedded;

  @override
  State<GroupListPage> createState() => _GroupListPageState();
}

class _GroupListPageState extends State<GroupListPage> {
  List<GroupSummary> _items = const <GroupSummary>[];
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<GroupSummary> items = await widget.service.list();
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _loading = false;
      });
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.isEmpty ? error.code : error.message;
      });
    }
  }

  void _open(GroupSummary group) {
    if (!widget.embedded) {
      Navigator.of(context).pop();
    }
    widget.onOpenGroup?.call(group.groupId, group.displayTitle);
  }

  /// 右上角「创建群聊」：只需群名即可建空群，无需先选人。
  /// 成功后刷新列表并让调用方打开新群，随后可在群资料页邀请/分享拉人。
  Future<void> _createGroup() async {
    if (_creating) {
      return;
    }
    final String? title = await showCreateGroupByNameDialog(context);
    if (title == null || !mounted) {
      return;
    }
    setState(() => _creating = true);
    try {
      final String groupId = await widget.service.create(
        title: title,
        members: const <String>[],
      );
      await _load();
      if (!mounted) {
        return;
      }
      if (!widget.embedded) {
        Navigator.of(context).pop();
      }
      widget.onGroupCreated?.call(groupId, title);
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            error.message.isEmpty ? error.code : error.message,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  Widget _createButton() => IconButton(
        key: const ValueKey<String>('group-list-create'),
        tooltip: context.t('创建群聊'),
        onPressed: _creating ? null : _createGroup,
        icon: const Icon(Icons.group_add_outlined),
      );

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader(
            title: context.t('群聊'),
            actions: <Widget>[_createButton()],
          ),
          Expanded(child: _body()),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('群聊')),
        actions: <Widget>[_createButton()],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListView(
      children: <Widget>[
        if (_error != null) _ErrorBar(message: _error!, onRetry: _load),
        if (_items.isEmpty && _error == null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NexmemMetrics.space24,
              vertical: NexmemMetrics.space24,
            ),
            child: Text(
              context.t('还没有群聊，点右上角创建'),
              key: const ValueKey<String>('group-list-empty'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
        for (final GroupSummary group in _items)
          _GroupTile(
            key: ValueKey<String>('group-list-${group.groupId}'),
            group: group,
            onTap: () => _open(group),
          ),
      ],
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({super.key, required this.group, required this.onTap});

  final GroupSummary group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String title = group.displayTitle;
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space12),
          child: Row(
            children: <Widget>[
              AppAvatar(
                seed: group.groupId,
                label: title,
                icon: Icons.groups_outlined,
                size: 40,
              ),
              const SizedBox(width: NexmemMetrics.space12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontSize: 15),
                    ),
                    Text(
                      context.t('{0} 人 · {1}', [
                        group.memberCount,
                        group.isAdmin ? context.t('管理员') : context.t('成员'),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.5),
                          ),
                    ),
                  ],
                ),
              ),
              if (!group.storageConfigured)
                Tooltip(
                  message: context.t('未配置群盘，离线消息不可补'),
                  child: Icon(
                    Icons.cloud_off_outlined,
                    size: 18,
                    color: scheme.onSurface.withValues(alpha: 0.35),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NexmemMetrics.space12,
        vertical: NexmemMetrics.space8,
      ),
      color: NexmemColors.danger.withValues(alpha: 0.08),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, size: 16, color: NexmemColors.danger),
          const SizedBox(width: NexmemMetrics.space8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: NexmemColors.danger),
            ),
          ),
          TextButton(
            key: const ValueKey<String>('group-list-retry'),
            onPressed: onRetry,
            child: Text(context.t('重试')),
          ),
        ],
      ),
    );
  }
}
