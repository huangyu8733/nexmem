import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../contacts/contact.dart';
import '../contacts/contact_service.dart';
import 'group_service.dart';
import 'group_storage.dart';

/// 群资料页（ui-spec.md §4）：群名、成员表与群盘状态。
///
/// 数据源为 `group.members`；未配置群盘时常驻「离线消息不可补」提示。
/// 管理员可在此邀请联系人或移除成员（P4-10）。
class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({
    super.key,
    required this.groupId,
    required this.title,
    required this.service,
    this.selfAccount = '',
    this.contacts,
    this.onAliasChanged,
    this.announcementRevision,
  });

  /// base64url 群 ID（会话 ID 去掉 `group:` 前缀）。
  final String groupId;

  /// 打开时的群名，回包到达前作为标题占位。
  final String title;

  final GroupService service;

  /// 当前登录账号（十六进制或 base64url），用于判断管理员身份。
  final String selfAccount;

  /// 邀请成员用的通讯录数据源；为空时隐藏邀请入口。
  final ContactService? contacts;

  /// 本机群备注保存成功后的回调（P6-27），用于刷新会话列表标题。
  final ValueChanged<String>? onAliasChanged;

  /// 群公告变更版本号（A-03）：内核收到其他成员的 `group.announcement` 事件时
  /// 由壳层递增，本页监听后重新拉取 `group.members` 刷新公告展示。
  /// 可选参数——未接入内核事件的场景（如 widget 测试）不监听，行为不变。
  final ValueListenable<int>? announcementRevision;

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  GroupInfo? _info;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  late final int _initialRevision;

  @override
  void initState() {
    super.initState();
    _initialRevision = widget.announcementRevision?.value ?? 0;
    widget.announcementRevision?.addListener(_onAnnouncementChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.announcementRevision?.removeListener(_onAnnouncementChanged);
    super.dispose();
  }

  /// 其他成员更新群公告时内核会推送 `group.announcement`，壳层递增版本号；
  /// 仅在版本号相对打开时发生变化时 reload，避免 initState 的初始通知重复拉取。
  void _onAnnouncementChanged() {
    final int? revision = widget.announcementRevision?.value;
    if (revision == null || revision == _initialRevision || !mounted) {
      return;
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final GroupInfo info = await widget.service.members(widget.groupId);
      if (!mounted) {
        return;
      }
      setState(() {
        _info = info;
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

  String get _selfHex => normalizeAccountHex(widget.selfAccount);

  bool _isAdmin(GroupInfo info) {
    final String self = _selfHex;
    if (self.isEmpty) {
      return false;
    }
    return info.members.any(
      (GroupMember m) => m.isAdmin && normalizeAccountHex(m.account) == self,
    );
  }

  bool _isSelf(GroupMember member) {
    final String self = _selfHex;
    return self.isNotEmpty && normalizeAccountHex(member.account) == self;
  }

  /// 邀请通讯录中的非成员入群（仅管理员）。
  Future<void> _invite() async {
    final ContactService? contacts = widget.contacts;
    final GroupInfo? info = _info;
    if (contacts == null || info == null || _busy) {
      return;
    }
    final Set<String> existing = <String>{
      for (final GroupMember m in info.members) normalizeAccountHex(m.account),
    };
    List<Contact> candidates;
    try {
      candidates = (await contacts.list())
          .where(
            (Contact c) =>
                !existing.contains(normalizeAccountHex(c.id)) &&
                !existing.contains(normalizeAccountHex(c.peer)),
          )
          .toList();
    } on NexmemException catch (error) {
      _toast(error.message.isEmpty ? error.code : error.message);
      return;
    }
    if (!mounted) {
      return;
    }
    if (candidates.isEmpty) {
      _toast('通讯录里没有可邀请的联系人');
      return;
    }
    final Contact? picked = await showDialog<Contact>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        key: const ValueKey<String>('group-invite-dialog'),
        title: const Text('邀请成员'),
        children: <Widget>[
          for (final Contact contact in candidates)
            SimpleDialogOption(
              key: ValueKey<String>('group-invite-contact-${contact.id}'),
              onPressed: () => Navigator.of(context).pop(contact),
              child: Text(contact.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    final String account =
        picked.peer.isNotEmpty ? picked.peer : picked.id;
    setState(() => _busy = true);
    try {
      final int version = await widget.service.invite(widget.groupId, account);
      _toast('已邀请 ${picked.name}，密钥版本 v$version');
      await _load();
    } on NexmemException catch (error) {
      _toast(error.message.isEmpty ? error.code : error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 把成员移出群并轮换密钥（仅管理员）。
  Future<void> _removeMember(GroupMember member) async {
    if (_busy) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        key: const ValueKey<String>('group-remove-dialog'),
        title: const Text('移出群聊'),
        content: Text('把 ${member.label} 移出群？对方将无法解密之后的消息。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('group-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final int version =
          await widget.service.remove(widget.groupId, member.account);
      _toast('已移出 ${member.label}，密钥版本 v$version');
      await _load();
    } on NexmemException catch (error) {
      _toast(error.message.isEmpty ? error.code : error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 退出或解散群聊（P4-12）：管理员解散并通知成员，普通成员本地退群。
  Future<void> _leaveOrDissolve() async {
    final GroupInfo? info = _info;
    if (info == null || _busy) {
      return;
    }
    final bool isAdmin = _isAdmin(info);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        key: const ValueKey<String>('group-leave-dialog'),
        title: Text(isAdmin ? '解散群聊' : '退出群聊'),
        content: Text(
          isAdmin
              ? '解散后所有成员将无法继续收发消息，且不可恢复。'
              : '退出后将不再接收该群消息，本机历史消息保留。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey<String>('group-leave-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isAdmin ? '解散' : '退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      if (isAdmin) {
        await widget.service.dissolve(widget.groupId);
      } else {
        await widget.service.leave(widget.groupId);
      }
    } on NexmemException catch (error) {
      _toast(error.message.isEmpty ? error.code : error.message);
      if (mounted) {
        setState(() => _busy = false);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  /// 管理员配置或覆盖群盘（P4-11）。
  Future<void> _configureStorage() async {
    if (_busy) {
      return;
    }
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => GroupStorageConfigDialog(
        groupId: widget.groupId,
        service: widget.service,
      ),
    );
    if (saved != true || !mounted) {
      return;
    }
    _toast('群盘已配置，成员将自动同步');
    await _load();
  }

  /// 管理员设置或清除群公告（P6-26）；成功后只替换本地字段，不整页重建。
  Future<void> _editAnnouncement() async {
    final GroupInfo? info = _info;
    if (info == null || _busy) {
      return;
    }
    final String? input = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _AnnouncementDialog(initial: info.announcement),
    );
    if (input == null || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String saved =
          await widget.service.setAnnouncement(widget.groupId, input);
      if (!mounted) {
        return;
      }
      setState(() {
        _info = GroupInfo(
          groupId: info.groupId,
          title: info.title,
          keyVersion: info.keyVersion,
          storageConfigured: info.storageConfigured,
          announcement: saved,
          alias: info.alias,
          members: info.members,
        );
      });
      _toast(saved.isEmpty ? '群公告已清除' : '群公告已更新');
    } on NexmemException catch (error) {
      _toast(error.message.isEmpty ? error.code : error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 设置或清除本机群备注（P6-27）；任意成员可用，修改只影响本机展示。
  Future<void> _editAlias() async {
    final GroupInfo? info = _info;
    if (info == null || _busy) {
      return;
    }
    final String? input = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _AliasDialog(initial: info.alias),
    );
    if (input == null || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String saved = await widget.service.setAlias(widget.groupId, input);
      if (!mounted) {
        return;
      }
      setState(() {
        _info = GroupInfo(
          groupId: info.groupId,
          title: info.title,
          keyVersion: info.keyVersion,
          storageConfigured: info.storageConfigured,
          announcement: info.announcement,
          alias: saved,
          members: info.members,
        );
      });
      widget.onAliasChanged?.call(saved);
      _toast(saved.isEmpty ? '群备注已清除' : '群备注已更新');
    } on NexmemException catch (error) {
      _toast(error.message.isEmpty ? error.code : error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final GroupInfo? info = _info;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          info != null ? info.displayTitle : widget.title,
        ),
        actions: <Widget>[
          if (info != null && widget.contacts != null && _isAdmin(info))
            IconButton(
              key: const ValueKey<String>('group-invite-button'),
              tooltip: '邀请成员',
              onPressed: _busy ? null : _invite,
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
        ],
      ),
      body: _buildBody(info),
    );
  }

  Widget _buildBody(GroupInfo? info) {
    if (_loading && info == null) {
      return const Center(
        key: ValueKey<String>('group-info-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final String? error = _error;
    if (error != null && info == null) {
      return Center(
        key: const ValueKey<String>('group-info-error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.error_outline,
              size: 36,
              color: NexmemColors.danger,
            ),
            const SizedBox(height: NexmemMetrics.space12),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NexmemMetrics.space24,
              ),
              child: Text(error, textAlign: TextAlign.center),
            ),
            const SizedBox(height: NexmemMetrics.space12),
            FilledButton(
              key: const ValueKey<String>('group-info-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (info == null) {
      return const SizedBox.shrink();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isAdmin = _isAdmin(info);
    return ListView(
      children: <Widget>[
        if (!info.storageConfigured) const GroupStorageNotice(),
        ListTile(
          key: const ValueKey<String>('group-storage-tile'),
          leading: Icon(
            info.storageConfigured
                ? Icons.cloud_done_outlined
                : Icons.cloud_off_outlined,
            color: info.storageConfigured
                ? NexmemColors.success
                : NexmemColors.warning,
          ),
          title: const Text('群盘（离线消息存储）'),
          subtitle: Text(
            info.storageConfigured
                ? '已配置，成员离线时可从群盘补齐'
                : '未配置，成员离线消息不可补',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: isAdmin
              ? TextButton(
                  key: const ValueKey<String>('group-storage-config'),
                  onPressed: _busy ? null : _configureStorage,
                  child: Text(info.storageConfigured ? '重新配置' : '配置'),
                )
              : null,
        ),
        const Divider(height: 1),
        ListTile(
          key: const ValueKey<String>('group-alias-tile'),
          leading: const Icon(Icons.drive_file_rename_outline),
          title: const Text('群备注'),
          subtitle: Text(
            info.alias.isEmpty
                ? '仅本机可见，清空后显示群名'
                : info.alias,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: TextButton(
            key: const ValueKey<String>('group-alias-edit'),
            onPressed: _busy ? null : _editAlias,
            child: Text(info.alias.isEmpty ? '设置' : '编辑'),
          ),
        ),
        const Divider(height: 1),
        Padding(
          key: const ValueKey<String>('group-announcement-section'),
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
                      '群公告',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (isAdmin)
                    TextButton(
                      key: const ValueKey<String>('group-announcement-edit'),
                      onPressed: _busy ? null : _editAnnouncement,
                      child: Text(info.announcement.isEmpty ? '设置' : '编辑'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              if (info.announcement.isEmpty)
                Text(
                  '暂无群公告',
                  key: const ValueKey<String>('group-announcement-empty'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    color: scheme.onSurface.withValues(alpha: 0.45),
                  ),
                )
              else
                Text(
                  info.announcement,
                  key: const ValueKey<String>('group-announcement-text'),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontSize: 14, height: 1.4),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
            vertical: NexmemMetrics.space12,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '群成员（${info.members.length}）',
                  key: const ValueKey<String>('group-member-count'),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '密钥版本 v${info.keyVersion}',
                key: const ValueKey<String>('group-key-version'),
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
          _MemberTile(
            key: ValueKey<String>('group-member-${member.account}'),
            member: member,
            canRemove: isAdmin && !member.isAdmin && !_isSelf(member),
            onRemove: _busy ? null : () => _removeMember(member),
          ),
        if (info.members.isEmpty)
          Padding(
            padding: const EdgeInsets.all(NexmemMetrics.space24),
            child: Text(
              '暂无成员信息',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.45)),
            ),
          ),
        const SizedBox(height: NexmemMetrics.space24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space16),
          child: OutlinedButton.icon(
            key: ValueKey<String>(
              isAdmin ? 'group-dissolve-button' : 'group-leave-button',
            ),
            onPressed: _busy ? null : _leaveOrDissolve,
            icon: Icon(
              isAdmin ? Icons.delete_forever_outlined : Icons.logout,
              size: 18,
            ),
            label: Text(isAdmin ? '解散群聊' : '退出群聊'),
            style: OutlinedButton.styleFrom(
              foregroundColor: NexmemColors.danger,
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ),
        const SizedBox(height: NexmemMetrics.space24),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    super.key,
    required this.member,
    this.canRemove = false,
    this.onRemove,
  });

  final GroupMember member;

  /// 当前账号是管理员且该成员可被移出时为 true。
  final bool canRemove;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final Color base =
        NexmemColors.avatarPalette[member.account.hashCode.abs() %
            NexmemColors.avatarPalette.length];
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space16),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 20,
              backgroundColor: base.withValues(alpha: 0.16),
              child: Text(
                member.label.isEmpty ? '?' : member.label.substring(0, 1),
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
                member.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontSize: 15),
              ),
            ),
            if (member.isAdmin)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: NexmemColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '群主',
                  style: TextStyle(fontSize: 11, color: NexmemColors.primary),
                ),
              ),
            if (canRemove) ...<Widget>[
              const SizedBox(width: NexmemMetrics.space8),
              TextButton(
                key: ValueKey<String>('group-remove-${member.account}'),
                onPressed: onRemove,
                child: const Text('移除'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 群备注编辑弹窗（P6-27）：单行输入，按 Unicode 码点计数，超过 32 禁止保存。
class _AliasDialog extends StatefulWidget {
  const _AliasDialog({required this.initial});

  final String initial;

  @override
  State<_AliasDialog> createState() => _AliasDialogState();
}

class _AliasDialogState extends State<_AliasDialog> {
  static const int _limit = 32;

  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _count => _controller.text.runes.length;

  @override
  Widget build(BuildContext context) {
    final bool overLimit = _count > _limit;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey<String>('group-alias-dialog'),
      title: const Text('群备注'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('group-alias-input'),
            controller: _controller,
            autofocus: true,
            maxLines: 1,
            decoration: const InputDecoration(
              hintText: '仅本机可见，清空后保存即恢复群名',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Text(
            '$_count/$_limit',
            key: const ValueKey<String>('group-alias-counter'),
            style: TextStyle(
              fontSize: 12,
              color: overLimit ? NexmemColors.danger : scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('group-alias-save'),
          onPressed: overLimit
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 群公告编辑弹窗（P6-26）：多行输入，按 Unicode 码点计数，超过 512 禁止保存。
class _AnnouncementDialog extends StatefulWidget {
  const _AnnouncementDialog({required this.initial});

  final String initial;

  @override
  State<_AnnouncementDialog> createState() => _AnnouncementDialogState();
}

class _AnnouncementDialogState extends State<_AnnouncementDialog> {
  static const int _limit = 512;

  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _count => _controller.text.runes.length;

  @override
  Widget build(BuildContext context) {
    final bool overLimit = _count > _limit;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey<String>('group-announcement-dialog'),
      title: const Text('群公告'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('group-announcement-input'),
            controller: _controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: '输入群公告，清空后保存即清除',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Text(
            '$_count/$_limit',
            key: const ValueKey<String>('group-announcement-counter'),
            style: TextStyle(
              fontSize: 12,
              color: overLimit ? NexmemColors.danger : scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('group-announcement-save'),
          onPressed: overLimit
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

