import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/avatar.dart';
import '../../app/empty_state.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../contacts/add_friend_dialog.dart';
import '../contacts/contact.dart';
import '../contacts/contact_service.dart';
import '../group/group_service.dart';
import '../search/message_search.dart';
import '../search/search_page.dart';
import 'conversation.dart';
import 'conversation_store.dart';
import 'start_chat_sheet.dart';
import '../../app/app_dialog.dart';

/// 会话列表（P1-18）：头像 / 昵称 / 摘要 / 时间 / 未读，置顶优先。
class ChatsPage extends StatefulWidget {
  const ChatsPage({
    super.key,
    this.store,
    this.onOpen,
    this.search = const UnavailableMessageSearchService(),
    this.onOpenHit,
    this.contacts,
    this.groups,
    this.onStartChat,
    this.onGroupCreated,
    this.onContactAdded,
    this.onMarkRead,
    this.onDelete,
    this.onSetPinned,
    this.onSetMuted,
    this.loading = false,
    this.offline = false,
    this.selectedId,
  });

  /// 由上层注入的数据源；为空时使用页面私有实例（P1-16 接通后改由内核事件驱动）。
  final ConversationStore? store;
  final ValueChanged<ConversationItem>? onOpen;

  /// 消息检索服务（P6-07）；点击搜索框进入搜索页。
  final MessageSearchService search;

  /// 搜索命中后的跳转回调，由上层打开对应会话。
  final ValueChanged<SearchHit>? onOpenHit;

  /// 联系人与群聊服务（P4-09）；为空时 `+` 菜单不可用。
  final ContactService? contacts;
  final GroupService? groups;

  /// `+` → 发起单聊：由上层打开与选中联系人的会话。
  final ValueChanged<Contact>? onStartChat;

  /// `+` → 创建群聊成功后回调，由上层落库会话并打开。
  final void Function(String groupId, String title)? onGroupCreated;

  /// `+` → 添加好友成功后回调，由上层刷新通讯录列表（P6-19）。
  final VoidCallback? onContactAdded;

  /// 左滑 / 右键「标记已读」后回调，由上层把已读水位推给内核。
  final ValueChanged<ConversationItem>? onMarkRead;

  /// 左滑 / 右键「删除」确认后回调，由上层删除内核侧会话条目。
  final ValueChanged<ConversationItem>? onDelete;

  /// 右键「置顶 / 取消置顶」回调（P6-17）；为空时菜单不展示该动作。
  final Future<void> Function(ConversationItem item, bool pinned)? onSetPinned;

  /// 右键「免打扰 / 取消免打扰」回调（P6-17）；为空时菜单不展示该动作。
  final Future<void> Function(ConversationItem item, bool muted)? onSetMuted;

  /// 首屏加载中：列表为空时展示 6 行骨架屏（ui-spec.md §8）。
  final bool loading;

  /// 链路断开：列表顶部提示「网络已断开，正在重连」（ui-spec.md §8）。
  final bool offline;

  /// 当前打开的会话 ID；用于桌面列表高亮选中项（QQ 式观感）。
  final String? selectedId;

  @override
  State<ChatsPage> createState() => ChatsPageState();
}

class ChatsPageState extends State<ChatsPage> {
  late final ConversationStore _store = widget.store ?? ConversationStore();
  bool _creatingGroup = false;

  @override
  void dispose() {
    if (widget.store == null) {
      _store.dispose();
    }
    super.dispose();
  }

  /// 打开搜索页（搜索框点击与桌面 `Ctrl/Cmd + F` 共用，ui-spec.md §9）。
  Future<void> openSearch() async {
    final SearchHit? hit = await Navigator.of(context).push<SearchHit>(
      MaterialPageRoute<SearchHit>(
        builder: (BuildContext context) => SearchPage(
          service: widget.search,
          titleOf: (String id) => _store.byId(id)?.title ?? id,
          conversationIds:
              _store.sorted.map((ConversationItem item) => item.id).toList(),
          onOpen: (SearchHit hit) => Navigator.of(context).pop(hit),
        ),
      ),
    );
    if (hit == null || !mounted) {
      return;
    }
    widget.onOpenHit?.call(hit);
  }

  /// `+` 菜单：发起单聊或创建群聊（ui-spec.md §2）；
  /// 桌面 `Ctrl/Cmd + N` 复用同一入口（ui-spec.md §9）。
  Future<void> startChat() async {
    final StartChatAction? action = await showStartChatSheet(context);
    if (action == null || !mounted) {
      return;
    }
    final ContactService? contacts = widget.contacts;
    final GroupService? groups = widget.groups;
    switch (action) {
      case StartChatAction.direct:
        if (contacts == null) {
          _toast(context.t('内核未接入，暂时无法发起聊天'));
          return;
        }
        final Contact? contact = await showContactPicker(context, contacts);
        if (contact == null || !mounted) {
          return;
        }
        widget.onStartChat?.call(contact);
        break;
      case StartChatAction.group:
        if (contacts == null || groups == null) {
          _toast(context.t('内核未接入，暂时无法创建群聊'));
          return;
        }
        final NewGroupRequest? request = await showCreateGroupDialog(
          context,
          contacts,
        );
        if (request == null || !mounted) {
          return;
        }
        await _createGroup(groups, request);
        break;
      case StartChatAction.addFriend:
        if (contacts == null) {
          _toast(context.t('内核未接入，暂时无法添加好友'));
          return;
        }
        final bool? added = await showAddFriendDialog(context, contacts);
        if (added == true && mounted) {
          _toast(context.t('已添加好友'));
          widget.onContactAdded?.call();
        }
        break;
    }
  }

  Future<void> _createGroup(
    GroupService groups,
    NewGroupRequest request,
  ) async {
    setState(() => _creatingGroup = true);
    try {
      final List<String> members = <String>[
        for (final Contact contact in request.members)
          contact.peer.isEmpty ? contact.id : contact.peer,
      ];
      final String groupId = await groups.create(
        title: request.title,
        members: members,
      );
      if (!mounted) {
        return;
      }
      widget.onGroupCreated?.call(groupId, request.title);
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      _toast(
        error.message.isEmpty
            ? context.t('创建群聊失败（{0}）', [error.code])
            : error.message,
      );
    } finally {
      if (mounted) {
        setState(() => _creatingGroup = false);
      }
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// 标记已读：先清本地未读，再通知上层把已读水位推给内核。
  void _markRead(ConversationItem item) {
    _store.markRead(item.id);
    widget.onMarkRead?.call(item);
  }

  /// 删除会话：确认后移除本地条目并交由上层同步内核；
  /// 历史消息保留，收到新消息时会话会重新出现。
  Future<void> _delete(ConversationItem item) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('删除会话')),
        content: Text(
          context.t('删除「{0}」后聊天记录仍保留，收到新消息时会重新出现。', [item.title]),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    _store.remove(item.id);
    widget.onDelete?.call(item);
  }

  /// 桌面右键菜单：与左滑动作保持一致，并补充置顶 / 免打扰（P6-17）。
  Future<void> _showContextMenu(ConversationItem item, Offset position) async {
    final List<PopupMenuEntry<String>> items = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(value: 'read', child: Text(context.t('标记已读'))),
      if (widget.onSetPinned != null)
        PopupMenuItem<String>(
          value: 'pin',
          child: Text(context.t(item.pinned ? '取消置顶' : '置顶')),
        ),
      if (widget.onSetMuted != null)
        PopupMenuItem<String>(
          value: 'mute',
          child: Text(context.t(item.muted ? '取消免打扰' : '免打扰')),
        ),
      PopupMenuItem<String>(value: 'delete', child: Text(context.t('删除'))),
    ];
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: items,
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'read':
        _markRead(item);
      case 'pin':
        _store.setPinned(item.id, !item.pinned);
        await widget.onSetPinned?.call(item, !item.pinned);
      case 'mute':
        _store.setMuted(item.id, !item.muted);
        await widget.onSetMuted?.call(item, !item.muted);
      case 'delete':
        await _delete(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        PaneHeader(
          title: context.t('消息'),
          actions: <Widget>[
            IconButton(
              key: const ValueKey<String>('chats-add'),
              tooltip: context.t('发起聊天'),
              icon: const Icon(Icons.add, size: 22),
              onPressed:
                  _creatingGroup ||
                      (widget.contacts == null && widget.groups == null)
                  ? null
                  : startChat,
            ),
          ],
        ),
        SearchBox(onTap: openSearch),
        const SizedBox(height: NexmemMetrics.space8),
        if (widget.offline) const _OfflineBanner(),
        const Divider(height: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: _store,
            builder: (BuildContext context, Widget? _) {
              final List<ConversationItem> items = _store.sorted;
              if (items.isEmpty) {
                return widget.loading
                    ? const ConversationSkeleton()
                    : EmptyState(
                        icon: Icons.chat_bubble_outline,
                        message: context.t('暂无会话，点击 + 发起聊天'),
                      );
              }
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (BuildContext context, int index) {
                  final ConversationItem item = items[index];
                  return Dismissible(
                    key: ValueKey<String>('conversation-swipe-${item.id}'),
                    direction: DismissDirection.horizontal,
                    background: _SwipeBackground(
                      alignment: AlignmentDirectional.centerStart,
                      color: NexmemColors.primary,
                      icon: Icons.mark_chat_read_outlined,
                      label: context.t('标记已读'),
                    ),
                    secondaryBackground: _SwipeBackground(
                      alignment: AlignmentDirectional.centerEnd,
                      color: NexmemColors.danger,
                      icon: Icons.delete_outline,
                      label: context.t('删除'),
                    ),
                    confirmDismiss: (DismissDirection direction) async {
                      if (direction == DismissDirection.startToEnd) {
                        _markRead(item);
                      } else {
                        await _delete(item);
                      }
                      // 动作由 store 与内核完成，这里只借用滑动手势，不真正移除。
                      return false;
                    },
                    child: GestureDetector(
                      onSecondaryTapDown: (TapDownDetails details) =>
                          unawaited(_showContextMenu(item, details.globalPosition)),
                      child: ConversationTile(
                        key: ValueKey<String>('conversation-${item.id}'),
                        item: item,
                        selected: widget.selectedId == item.id,
                        onTap: widget.onOpen == null
                            ? null
                            : () => widget.onOpen!(item),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 断网提示条：置于会话列表顶部（ui-spec.md §8）。
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('chats-offline-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: NexmemMetrics.space16,
        vertical: NexmemMetrics.space8,
      ),
      color: scheme.onSurface.withValues(alpha: 0.06),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.cloud_off_outlined,
            size: 16,
            color: scheme.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: NexmemMetrics.space8),
          Text(
            context.t('网络已断开，正在重连'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 13,
              color: scheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}

/// 会话列表骨架屏：6 行占位，不使用整页转圈（ui-spec.md §8）。
class ConversationSkeleton extends StatelessWidget {
  const ConversationSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = scheme.onSurface.withValues(alpha: 0.08);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
    return ListView.builder(
      key: const ValueKey<String>('conversation-skeleton'),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows,
      itemBuilder: (BuildContext context, int index) {
        return SizedBox(
          height: NexmemMetrics.listItemHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NexmemMetrics.space12,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: NexmemMetrics.avatarSize,
                  height: NexmemMetrics.avatarSize,
                  decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                ),
                const SizedBox(width: NexmemMetrics.space12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      bar(120, 12),
                      const SizedBox(height: NexmemMetrics.space8),
                      bar(180, 10),
                    ],
                  ),
                ),
                const SizedBox(width: NexmemMetrics.space8),
                bar(36, 10),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 左滑动作背景：右侧滑出「标记已读」，左侧滑出「删除」。
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final AlignmentGeometry alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 20, color: Colors.white),
          const SizedBox(width: NexmemMetrics.space8),
          Text(
            context.t(label),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个会话项，高度与内边距见 ui-spec.md §2。
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.item,
    this.onTap,
    this.selected = false,
  });

  final ConversationItem item;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? secondary = Theme.of(context).textTheme.bodySmall
        ?.copyWith(
          fontSize: 12,
          color: scheme.onSurface.withValues(alpha: 0.5),
        );
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: Material(
        color: selected
            ? NexmemColors.primary.withValues(alpha: 0.12)
            : item.pinned
                ? scheme.onSurface.withValues(alpha: 0.03)
                : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NexmemMetrics.space12,
            ),
            child: Row(
              children: <Widget>[
                _Avatar(item: item, colors: NexmemColors.avatarPalette),
                const SizedBox(width: NexmemMetrics.space12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontSize: 16,
                                    fontWeight: item.unread > 0
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                            ),
                          ),
                          if (item.muted) ...<Widget>[
                            const SizedBox(width: NexmemMetrics.space4),
                            Icon(
                              Icons.notifications_off_outlined,
                              size: 14,
                              color: scheme.onSurface.withValues(alpha: 0.45),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: NexmemMetrics.space8),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      item.lastMessageAt == null
                          ? ''
                          : formatConversationTime(item.lastMessageAt!),
                      style: secondary,
                    ),
                    const SizedBox(height: NexmemMetrics.space4),
                    if (item.failed)
                      const Icon(
                        Icons.error_outline,
                        size: 16,
                        color: NexmemColors.danger,
                      )
                    else
                      _UnreadBadge(count: item.unread, muted: item.muted),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.item, required this.colors});

  final ConversationItem item;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return AppAvatar(
      seed: item.id,
      label: item.title,
      icon: item.isGroup ? Icons.groups_outlined : null,
      size: NexmemMetrics.avatarSize,
      showPresence: !item.isGroup,
      presence: switch (item.presence) {
        PresenceStatus.online => AvatarPresence.online,
        PresenceStatus.relay => AvatarPresence.relay,
        PresenceStatus.offline => AvatarPresence.offline,
      },
    );
  }
}

/// 未读角标：超过 99 显示 `99+`；免打扰会话只显示灰点。
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.muted});

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
      return const SizedBox(height: 18);
    }
    if (muted) {
      return Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: const BoxDecoration(
          color: NexmemColors.unreadMuted,
          shape: BoxShape.circle,
        ),
      );
    }
    final String label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: NexmemColors.unread,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}
