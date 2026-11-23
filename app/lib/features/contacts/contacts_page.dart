import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../app/core_session.dart';
import '../../transport/transport.dart';
import 'add_friend_dialog.dart';
import 'qr_share.dart';
import 'contact.dart';
import 'contact_detail_page.dart';
import 'contact_service.dart';
import 'device_list_page.dart';
import '../group/group_list_page.dart';
import '../group/group_service.dart';

/// 通讯录（P1-18 / P2-06 / P4-13）：好友 / 群聊 / 我的设备分组，
/// 好友按 A–Z 分组并带字母索引，「群聊」进入本机群列表。
///
/// 传入 [service] 时从内核 `contact.list` 加载好友，并支持添加好友、备注与拉黑；
/// 传入 [groups] 时「群聊」分组可进入 `group.list` 群列表；
/// 未接入内核（Widget 测试、离线部署）时退化为 [friends] 静态列表。
class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    this.friends = const <Contact>[],
    this.service,
    this.groups,
    this.onSendMessage,
    this.onOpenGroup,
    this.session,
  });

  final List<Contact> friends;

  /// 内核通讯录服务；为空时仅展示 [friends]。
  final ContactService? service;

  /// 内核群聊服务；为空时「群聊」分组不可点击。
  final GroupService? groups;

  /// 点击好友资料页「发消息」时回调，由壳层打开单聊会话。
  final ValueChanged<Contact>? onSendMessage;

  /// 点击群聊列表中的群时回调，由壳层打开群会话。
  final void Function(String groupId, String title)? onOpenGroup;

  /// 内核会话（P6-39 二维码加好友）；为空时不展示二维码入口。
  final CoreSession? session;

  @override
  State<ContactsPage> createState() => ContactsPageState();
}

class ContactsPageState extends State<ContactsPage> {
  final Map<String, GlobalKey> _sectionKeys = <String, GlobalKey>{};
  late List<Contact> _friends = List<Contact>.of(widget.friends);
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.service != null) {
      unawaited(_reload());
    }
  }

  @override
  void didUpdateWidget(ContactsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.friends, widget.friends)) {
      _friends = List<Contact>.of(widget.friends);
      if (oldWidget.service != widget.service) {
        unawaited(_reload());
      }
    }
  }

  /// 重新拉取好友列表；供壳层在其它页面添加好友后刷新（P6-19）。
  Future<void> reload() => _reload();

  /// 拉取好友列表；失败时保留上次结果并展示重试入口。
  Future<void> _reload() async {
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Contact> items = await service.list();
      if (!mounted) {
        return;
      }
      setState(() {
        _friends = items;
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

  GlobalKey _keyFor(String letter) =>
      _sectionKeys.putIfAbsent(letter, () => GlobalKey(debugLabel: 'contact-$letter'));

  Future<void> _jumpTo(String letter) async {
    final BuildContext? target = _keyFor(letter).currentContext;
    if (target == null) {
      return;
    }
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 200),
      alignment: 0.05,
    );
  }

  void _apply(Contact next) {
    setState(() {
      _friends = <Contact>[
        for (final Contact c in _friends) c.id == next.id ? next : c,
      ];
    });
  }

  void _openDetail(Contact contact) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => ContactDetailPage(
          contact: contact,
          service: widget.service,
          onChanged: _apply,
          onSendMessage: () {
            Navigator.of(context).pop();
            widget.onSendMessage?.call(contact);
          },
        ),
      ),
    );
  }

  /// 「我的设备」：读取本机账号已发布的设备证书（P6-21）。
  void _openMyDevices() {
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => DeviceListPage(service: service),
      ),
    );
  }

  Future<void> _openGroups() async {
    final GroupService? groups = widget.groups;
    if (groups == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => GroupListPage(
          service: groups,
          onOpenGroup: (String groupId, String title) =>
              widget.onOpenGroup?.call(groupId, title),
        ),
      ),
    );
  }

  Future<void> _addFriend() async {
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    final bool? added = await showAddFriendDialog(context, service);
    if (added == true) {
      await _reload();
    }
  }

  Future<void> _showMyQr() async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    await showMyQrDialog(context, session);
  }

  Future<void> _importQr() async {
    final CoreSession? session = widget.session;
    final ContactService? service = widget.service;
    if (session == null || service == null) {
      return;
    }
    await showQrImportDialog(context, session, service);
    if (mounted) {
      await _reload();
    }
  }

  List<Widget> get _actions => <Widget>[
        if (widget.service != null)
          IconButton(
            key: const ValueKey<String>('contact-add-button'),
            tooltip: '添加好友',
            icon: const Icon(Icons.person_add_alt_1, size: 20),
            onPressed: _addFriend,
          ),
        if (widget.session != null && widget.service != null)
          IconButton(
            key: const ValueKey<String>('contact-qr-import-button'),
            tooltip: '扫码加好友',
            icon: const Icon(Icons.qr_code_scanner, size: 20),
            onPressed: _importQr,
          ),
        if (widget.session != null)
          IconButton(
            key: const ValueKey<String>('contact-my-qr-button'),
            tooltip: '我的二维码',
            icon: const Icon(Icons.qr_code, size: 20),
            onPressed: _showMyQr,
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final List<(String, List<Contact>)> groups = groupContacts(_friends);
    return Column(
      children: <Widget>[
        PaneHeader(title: '联系人', actions: _actions),
        const SearchBox(hint: '搜索联系人'),
        const SizedBox(height: NexmemMetrics.space8),
        const Divider(height: 1),
        if (_error != null) _ErrorBar(message: _error!, onRetry: _reload),
        if (_loading && _friends.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: Stack(
              children: <Widget>[
                ListView(
                  padding: EdgeInsets.only(
                    right: groups.isEmpty ? 0 : NexmemMetrics.space24,
                  ),
                  children: <Widget>[
                    const _GroupEntry(icon: Icons.person_outline, title: '好友'),
                    _GroupEntry(
                      icon: Icons.groups_outlined,
                      title: '群聊',
                      onTap: widget.groups == null ? null : _openGroups,
                    ),
                    _GroupEntry(
                      key: const ValueKey<String>('contact-devices-entry'),
                      icon: Icons.devices_outlined,
                      title: '我的设备',
                      onTap: widget.service == null ? null : _openMyDevices,
                    ),
                    if (groups.isNotEmpty) ...<Widget>[
                      const Divider(height: 1),
                      for (final (String letter, List<Contact> members) in groups) ...<Widget>[
                        _SectionHeader(key: _keyFor(letter), letter: letter),
                        for (final Contact contact in members)
                          _ContactTile(
                            contact: contact,
                            onTap: () => _openDetail(contact),
                          ),
                      ],
                      const SizedBox(height: NexmemMetrics.space16),
                    ] else if (widget.service != null && !_loading)
                      const _EmptyFriends(),
                  ],
                ),
                if (groups.isNotEmpty)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (final (String letter, List<Contact> _) in groups)
                            _IndexLetter(letter: letter, onTap: () => _jumpTo(letter)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
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
            key: const ValueKey<String>('contact-retry'),
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _EmptyFriends extends StatelessWidget {
  const _EmptyFriends();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NexmemMetrics.space24,
        vertical: NexmemMetrics.space24,
      ),
      child: Text(
        '还没有好友，点右上角添加对方账号即可开始聊天',
        key: const ValueKey<String>('contact-empty'),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: scheme.onSurface.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}

class _GroupEntry extends StatelessWidget {
  const _GroupEntry({super.key, required this.icon, required this.title, this.onTap});

  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: ListTile(
        leading: Icon(icon, size: 22),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: onTap,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.letter});

  final String letter;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 28,
      alignment: Alignment.centerLeft,
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

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, this.onTap});

  final Contact contact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color base = NexmemColors
        .avatarPalette[contact.id.hashCode.abs() % NexmemColors.avatarPalette.length];
    final String initial = contact.name.isEmpty ? '?' : contact.name.substring(0, 1);
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: InkWell(
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
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 15),
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
            ],
          ),
        ),
      ),
    );
  }
}

class _IndexLetter extends StatelessWidget {
  const _IndexLetter({required this.letter, required this.onTap});

  final String letter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          letter,
          style: const TextStyle(
            fontSize: 10,
            height: 1.1,
            fontWeight: FontWeight.w600,
            color: NexmemColors.primary,
          ),
        ),
      ),
    );
  }
}
