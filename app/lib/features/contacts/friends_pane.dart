import 'package:material_ui/material_ui.dart';

import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import 'contact.dart';

/// 右栏 / 全屏页复用的好友列表面板：按 A–Z 分组展示好友。
///
/// 与 [ContactsPage] 共用同一份好友数据，但去掉分组入口与字母索引，
/// 只保留好友列表本身，作为右侧内容区展示。
class FriendsPane extends StatelessWidget {
  const FriendsPane({
    super.key,
    required this.friends,
    this.onOpenContact,
    this.onAdd,
  });

  final List<Contact> friends;
  final ValueChanged<Contact>? onOpenContact;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final List<(String, List<Contact>)> groups = groupContacts(friends);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(
          title: context.t('好友'),
          actions: onAdd == null
              ? const <Widget>[]
              : <Widget>[
                  IconButton(
                    key: const ValueKey<String>('pane-add-friend'),
                    tooltip: context.t('添加好友'),
                    icon: const Icon(Icons.person_add_alt_1, size: 20),
                    onPressed: onAdd,
                  ),
                ],
        ),
        Expanded(
          child: groups.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(NexmemMetrics.space24),
                    child: Text(
                      context.t('还没有好友，点右上角添加对方账号即可开始聊天'),
                      key: const ValueKey<String>('pane-friends-empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                )
              : ListView(
                  children: <Widget>[
                    for (final (String letter, List<Contact> members) in groups) ...<Widget>[
                      _SectionHeader(letter: letter),
                      for (final Contact contact in members)
                        _FriendTile(
                          contact: contact,
                          onTap: onOpenContact == null
                              ? null
                              : () => onOpenContact!(contact),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.letter});

  final String letter;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 28,
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space12),
      color: scheme.onSurface.withValues(alpha: 0.04),
      child: Text(
        letter,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
      ),
    );
  }
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({required this.contact, this.onTap});

  final Contact contact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color base = NexmemColors
        .avatarPalette[contact.id.hashCode.abs() % NexmemColors.avatarPalette.length];
    final String initial =
        contact.name.isEmpty ? '?' : contact.name.substring(0, 1);
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: InkWell(
        key: ValueKey<String>('pane-friend-${contact.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space12),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 20,
                backgroundColor: base.withValues(alpha: 0.16),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: base,
                  ),
                ),
              ),
              const SizedBox(width: NexmemMetrics.space12),
              Expanded(
                child: Text(
                  contact.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontSize: 15),
                ),
              ),
              if (contact.note.isNotEmpty && contact.note != contact.name)
                Text(
                  contact.note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                ),
              const SizedBox(width: NexmemMetrics.space4),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
