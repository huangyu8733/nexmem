import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/avatar.dart';
import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../chat/chat_page.dart' show MentionCandidate;
import '../chats/conversation.dart';
import '../contacts/contact_service.dart';
import '../group/group_service.dart';
import '../group/group_storage.dart';

/// 桌面 / Web 聊天区右侧可折叠资料面板（ui-spec.md §1 三级导航）。
///
/// 单聊展示对端账号与端到端加密说明；群聊展示成员表、群盘状态与群设置入口。
/// 数据源为 `group.members`，未接入内核时保持错误提示与重试入口。
class ChatProfilePanel extends StatefulWidget {
  const ChatProfilePanel({
    super.key,
    required this.conversation,
    required this.groups,
    this.selfAccount = '',
    this.onClose,
    this.onOpenGroupInfo,
    this.onMentionMember,
    this.onAddFriend,
    this.allowFriendAddRevision,
    this.displayName,
    this.remark = '',
    this.onSetRemark,
  });

  final ConversationItem conversation;

  /// 群资料数据源；单聊不会调用。
  final GroupService groups;

  /// 当前登录账号，用于在成员表中标记「我」。
  final String selfAccount;

  final VoidCallback? onClose;
  final VoidCallback? onOpenGroupInfo;

  /// 点击群成员时在聊天输入框插入 @；单聊或不需要此能力时为 null。
  final ValueChanged<MentionCandidate>? onMentionMember;

  /// 群设置允许加好友时，点击成员行的加好友按钮回调成员账号。
  final ValueChanged<String>? onAddFriend;

  /// 群加好友开关变更版本号；内核事件或管理员本机切换后递增，面板重新拉取成员表。
  final ValueListenable<int>? allowFriendAddRevision;

  /// 单聊显示名（备注 > 昵称 > 账号）；为空时回退到会话 title。
  final String? displayName;

  /// 单聊当前备注，供资料面板直接编辑。
  final String remark;

  /// 单聊设置备注回调，参数为新备注文本；群聊或不适用时为 null。
  final ValueChanged<String>? onSetRemark;

  @override
  State<ChatProfilePanel> createState() => _ChatProfilePanelState();
}

class _ChatProfilePanelState extends State<ChatProfilePanel> {
  GroupInfo? _info;
  bool _loading = false;
  String? _error;
  late final int _initialAllowFriendRevision;

  @override
  void initState() {
    super.initState();
    _initialAllowFriendRevision = widget.allowFriendAddRevision?.value ?? 0;
    widget.allowFriendAddRevision?.addListener(_onAllowFriendAddChanged);
    if (widget.conversation.isGroup) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    widget.allowFriendAddRevision?.removeListener(_onAllowFriendAddChanged);
    super.dispose();
  }

  /// 管理员本机切换或成员收到控制帧后壳层递增版本号，重新拉取群资料以刷新
  /// 成员行的加好友入口。单调计数不区分群，成本可忽略且避免漏刷。
  void _onAllowFriendAddChanged() {
    final int? revision = widget.allowFriendAddRevision?.value;
    if (revision == null ||
        revision == _initialAllowFriendRevision ||
        !mounted ||
        !widget.conversation.isGroup) {
      return;
    }
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ChatProfilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id == widget.conversation.id) {
      return;
    }
    _info = null;
    _error = null;
    if (widget.conversation.isGroup) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final String conversationId = widget.conversation.id;
      final String groupId = conversationId.startsWith('group:')
          ? conversationId.substring('group:'.length)
          : conversationId;
      final GroupInfo info = await widget.groups.members(groupId);
      if (!mounted) {
        return;
      }
      setState(() {
        _info = info;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error is NexmemException
            ? (error.message.isEmpty ? error.code : error.message)
            : '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('chat-profile-panel'),
      color: scheme.surface,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 52,
            child: Row(
              children: <Widget>[
                const SizedBox(width: NexmemMetrics.space16),
                Expanded(
                  child: Text(
                    context.t('聊天信息'),
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('chat-profile-close'),
                  tooltip: context.t('收起'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.conversation.isGroup
                ? _buildGroup(context)
                : _buildDirect(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDirect(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ConversationItem conversation = widget.conversation;
    final String account = conversation.peer;
    final String name = widget.displayName?.trim().isNotEmpty ?? false
        ? widget.displayName!.trim()
        : (conversation.title.trim().isNotEmpty
            ? conversation.title.trim()
            : shortAccountLabel(account.isEmpty ? conversation.id : account));
    return ListView(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      children: <Widget>[
        Center(
          child: AppAvatar(
            seed: conversation.id,
            label: name,
            size: 64,
            showPresence: true,
            presence: switch (conversation.presence) {
              PresenceStatus.online => AvatarPresence.online,
              PresenceStatus.relay => AvatarPresence.relay,
              PresenceStatus.offline => AvatarPresence.offline,
            },
          ),
        ),
        const SizedBox(height: NexmemMetrics.space12),
        Center(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: NexmemMetrics.space4),
        Center(
          child: Text(
            context.t('单聊 · {0}', [_presenceLabel(context, conversation.presence)]),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
        const SizedBox(height: NexmemMetrics.space24),
        _InfoRow(
          label: context.t('账号'),
          value: account.isEmpty ? context.t('未知') : shortAccountLabel(account),
          monospace: true,
          onCopy: account.isEmpty
              ? null
              : () => _copyAccount(context, account),
        ),
        const SizedBox(height: NexmemMetrics.space12),
        _InfoRow(
          label: context.t('在线状态'),
          value: _presenceLabel(context, conversation.presence),
        ),
        if (widget.onSetRemark != null) ...<Widget>[
          const SizedBox(height: NexmemMetrics.space12),
          _InfoRow(
            label: context.t('备注'),
            value: widget.remark.isEmpty
                ? context.t('未设置')
                : widget.remark,
            onEdit: () => _openRemark(context),
          ),
        ],
        const SizedBox(height: NexmemMetrics.space24),
        Container(
          padding: const EdgeInsets.all(NexmemMetrics.space12),
          decoration: BoxDecoration(
            color: NexmemColors.success.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
          ),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.lock_outline,
                size: 16,
                color: NexmemColors.success,
              ),
              const SizedBox(width: NexmemMetrics.space8),
              Expanded(
                child: Text(
                  context.t('消息端到端加密，仅你与对方可读'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: NexmemColors.success,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGroup(BuildContext context) {
    final GroupInfo? info = _info;
    if (_loading && info == null) {
      return const Center(
        key: ValueKey<String>('chat-profile-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final String? error = _error;
    if (error != null && info == null) {
      return Center(
        key: const ValueKey<String>('chat-profile-error'),
        child: Padding(
          padding: const EdgeInsets.all(NexmemMetrics.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.error_outline,
                size: 32,
                color: NexmemColors.danger,
              ),
              const SizedBox(height: NexmemMetrics.space12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: NexmemMetrics.space12),
              FilledButton(
                key: const ValueKey<String>('chat-profile-retry'),
                onPressed: _load,
                child: Text(context.t('重试')),
              ),
            ],
          ),
        ),
      );
    }
    if (info == null) {
      return const SizedBox.shrink();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String title =
        info.title.isEmpty ? widget.conversation.title : info.title;
    final String selfHex = normalizeAccountHex(widget.selfAccount);
    return ListView(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(NexmemMetrics.space16),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 24,
                backgroundColor: NexmemColors.primary.withValues(alpha: 0.12),
                child: const Icon(
                  Icons.groups_outlined,
                  size: 24,
                  color: NexmemColors.primary,
                ),
              ),
              const SizedBox(width: NexmemMetrics.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    Text(
                      context.t('群聊 · {0} 位成员', [info.members.length]),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!info.storageConfigured) const GroupStorageNotice(),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
            vertical: NexmemMetrics.space12,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  context.t('群成员（{0}）', [info.members.length]),
                  key: const ValueKey<String>('chat-profile-member-count'),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                context.t('密钥版本 v{0}', [info.keyVersion]),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        for (final GroupMember member in info.members)
          _MemberRow(
            key: ValueKey<String>('chat-profile-member-${member.account}'),
            member: member,
            isSelf: selfHex.isNotEmpty &&
                normalizeAccountHex(member.account) == selfHex,
            onMention: widget.onMentionMember == null ||
                    (selfHex.isNotEmpty &&
                        normalizeAccountHex(member.account) == selfHex)
                ? null
                : () => widget.onMentionMember!(
                      MentionCandidate(
                        account: member.account,
                        name: member.label,
                      ),
                    ),
            onAddFriend: !info.allowFriendAdd ||
                    widget.onAddFriend == null ||
                    (selfHex.isNotEmpty &&
                        normalizeAccountHex(member.account) == selfHex)
                ? null
                : () => widget.onAddFriend!(member.account),
          ),
        if (info.members.isEmpty)
          Padding(
            padding: const EdgeInsets.all(NexmemMetrics.space24),
            child: Text(
              context.t('暂无成员信息'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.45)),
            ),
          ),
        const SizedBox(height: NexmemMetrics.space12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space16),
          child: OutlinedButton.icon(
            key: const ValueKey<String>('chat-profile-open-group'),
            onPressed: widget.onOpenGroupInfo,
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: Text(context.t('群设置')),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
            ),
          ),
        ),
        const SizedBox(height: NexmemMetrics.space16),
      ],
    );
  }

  Future<void> _copyAccount(BuildContext context, String account) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String copied = context.t('账号已复制');
    await Clipboard.setData(ClipboardData(text: account));
    messenger.showSnackBar(SnackBar(content: Text(copied)));
  }

  /// 打开备注编辑弹窗，保存后由壳层落库并回填会话标题。
  Future<void> _openRemark(BuildContext context) async {
    final TextEditingController controller =
        TextEditingController(text: widget.remark);
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('设置备注')),
        content: TextField(
          key: const ValueKey<String>('chat-profile-remark-field'),
          controller: controller,
          autofocus: true,
          maxLines: 1,
          decoration: InputDecoration(
            labelText: context.t('备注'),
            helperText: context.t('仅本机可见，不会发送给对方'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(context.t('保存')),
          ),
        ],
      ),
    );
    if (next == null) {
      return;
    }
    widget.onSetRemark?.call(next);
  }

  static String _presenceLabel(BuildContext context, PresenceStatus status) {
    switch (status) {
      case PresenceStatus.online:
        return context.t('在线');
      case PresenceStatus.relay:
        return context.t('经中继');
      case PresenceStatus.offline:
        return context.t('离线');
    }
  }
}

/// 键值信息行，长文本单行省略并可复制。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.monospace = false,
    this.onCopy,
    this.onEdit,
  });

  final String label;
  final String value;
  final bool monospace;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
        ),
        if (onCopy != null)
          IconButton(
            tooltip: context.t('复制'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 16),
            onPressed: onCopy,
          ),
        if (onEdit != null)
          IconButton(
            tooltip: context.t('编辑'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: onEdit,
          ),
      ],
    );
  }
}

/// 群成员行：头像首字母、账号短串与群主标识。
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.member,
    this.isSelf = false,
    this.onMention,
    this.onAddFriend,
  });

  final GroupMember member;
  final bool isSelf;

  /// 非空时成员资料区可点：在聊天输入框插入 `@成员`。
  final VoidCallback? onMention;

  /// 非空时显示加好友按钮（仅群设置开启后由面板传入）。
  final VoidCallback? onAddFriend;

  @override
  Widget build(BuildContext context) {
    final Widget profile = Row(
      children: <Widget>[
        AppAvatar(
          seed: member.account,
          label: member.label,
          size: 32,
        ),
        const SizedBox(width: NexmemMetrics.space12),
        Expanded(
          child: Text(
            isSelf ? context.t('{0}（我）', [member.label]) : member.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontSize: 14),
          ),
        ),
        if (member.isAdmin)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: NexmemColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              context.t('群主'),
              style: const TextStyle(
                fontSize: 11,
                color: NexmemColors.primary,
              ),
            ),
          ),
        if (onMention != null) ...<Widget>[
          const SizedBox(width: NexmemMetrics.space8),
          Tooltip(
            message: context.t('在聊天中 @ 该成员'),
            child: Icon(
              Icons.alternate_email,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ],
    );
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: onMention == null
                  ? profile
                  : InkWell(
                      key: ValueKey<String>(
                        'chat-profile-mention-${member.account}',
                      ),
                      onTap: onMention,
                      child: profile,
                    ),
            ),
            if (onAddFriend != null)
              IconButton(
                key: ValueKey<String>(
                  'chat-profile-add-friend-${member.account}',
                ),
                tooltip: context.t('加为好友'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.person_add_alt_outlined, size: 18),
                onPressed: onAddFriend,
              ),
          ],
        ),
      ),
    );
  }
}
