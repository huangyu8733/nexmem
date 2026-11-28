import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/avatar.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../settings/settings_pane.dart';
import '../social/social_hub_page.dart';
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
import '../../app/app_dialog.dart';

/// 通讯录（P1-18 / P2-06 / P4-13）：好友 / 群聊 / 我的设备分组。
///
/// 「好友」按 QQ 式交互：点击展开下方好友分组，分组可再展开/收起，
/// 点击好友通过 [onOpenContactChat] 在右侧打开聊天；分组支持新建、
/// 重命名、删除与移动好友，底层走内核 `contact.setGroup`。
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
    this.onOpenContactChat,
    this.onOpenGroup,
    this.session,
    this.presence,
    this.onOpenPane,
    this.onContactsChanged,
    this.onToggleFriends,
  });

  final List<Contact> friends;

  /// 内核通讯录服务；为空时仅展示 [friends]。
  final ContactService? service;

  /// 内核群聊服务；为空时「群聊」分组不可点击。
  final GroupService? groups;

  /// 点击好友资料页「发消息」时回调，由壳层打开单聊会话。
  final ValueChanged<Contact>? onSendMessage;

  /// 点击好友条目直接打开聊天（桌面在右栏内联，移动端进聊天页）。
  final ValueChanged<Contact>? onOpenContactChat;

  /// 点击群聊列表中的群时回调，由壳层打开群会话。
  final void Function(String groupId, String title)? onOpenGroup;

  /// 内核会话（P6-39 二维码加好友）；为空时不展示二维码入口。
  final CoreSession? session;

  /// 好友在线状态（十六进制账号 → 是否在线）；为空时不显示状态点。
  final ValueListenable<Map<String, bool>>? presence;

  /// 统一的内容展示回调：由壳层决定桌面在右栏展示、手机进全屏页。
  /// pane 取值：好友 / 群聊 / 我的设备 / 好友资料 / 设备列表。
  final void Function(String pane, {Object? data})? onOpenPane;

  /// 好友列表加载完成后通知外层刷新右栏内容。
  final VoidCallback? onContactsChanged;

  /// 点击「好友」展开/收起左栏分组时通知壳层：非聊天状态下右栏回到好友面板。
  final VoidCallback? onToggleFriends;

  @override
  State<ContactsPage> createState() => ContactsPageState();
}

class ContactsPageState extends State<ContactsPage> {
  final TextEditingController _search = TextEditingController();
  late List<Contact> _friends = List<Contact>.of(widget.friends);
  bool _loading = false;
  String? _error;

  /// QQ 式：点「好友」才在下方展开分组列表。
  bool _friendsExpanded = false;

  /// 收起的分组名（含本地化后的默认分组名）。
  final Set<String> _collapsedGroups = <String>{};

  /// QQ 式：点「群聊」才在下方展开群列表。
  bool _groupsExpanded = false;
  List<GroupSummary> _groupItems = const <GroupSummary>[];
  bool _groupsLoading = false;
  String? _groupsError;

  @override
  void initState() {
    super.initState();
    if (widget.service != null) {
      unawaited(_reload());
    }
    if (widget.groups != null) {
      unawaited(_reloadGroups());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
    if (oldWidget.groups != widget.groups) {
      unawaited(_reloadGroups());
    }
  }

  /// 当前好友列表；供壳层右栏的好友面板共享同一份数据。
  List<Contact> get friends => List<Contact>.unmodifiable(_friends);

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
      widget.onContactsChanged?.call();
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

  /// 供壳层在建群/退群后刷新左栏群列表。
  Future<void> reloadGroups() => _reloadGroups();

  Future<void> _reloadGroups() async {
    final GroupService? service = widget.groups;
    if (service == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _groupsLoading = true;
      _groupsError = null;
    });
    try {
      final List<GroupSummary> items = await service.list();
      if (!mounted) {
        return;
      }
      setState(() {
        _groupItems = items;
        _groupsLoading = false;
      });
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _groupsLoading = false;
        _groupsError = error.message.isEmpty ? error.code : error.message;
      });
    }
  }

  /// 供右栏好友资料页回写备注/分组等变更。
  void apply(Contact next) => _apply(next);

  void _apply(Contact next) {
    setState(() {
      _friends = <Contact>[
        for (final Contact c in _friends) c.id == next.id ? next : c,
      ];
    });
    widget.onContactsChanged?.call();
  }

  void _fail(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _error = message);
  }

  /// 分组名与 groupFriends 的归类规则保持一致。
  String _groupOf(Contact contact) {
    final String name = contact.groupName.trim();
    return name.isEmpty ? context.t('我的好友') : name;
  }

  /// 本地乐观更新，再逐条写内核；失败时回滚并展示错误。
  Future<void> _setGroupFor(Iterable<Contact> targets, String group) async {
    final List<Contact> list = targets.toList();
    if (list.isEmpty) {
      return;
    }
    final Map<String, String> changes = <String, String>{
      for (final Contact contact in list) contact.id: group,
    };
    if (!mounted) {
      return;
    }
    setState(() {
      _friends = <Contact>[
        for (final Contact contact in _friends)
          changes.containsKey(contact.id)
              ? contact.copyWith(groupName: group)
              : contact,
      ];
      _error = null;
    });
    widget.onContactsChanged?.call();
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    try {
      for (final Contact contact in list) {
        await service.setGroup(contact.id, group);
      }
    } on NexmemException catch (error) {
      _fail(error.message.isEmpty ? error.code : error.message);
      await reload();
    }
  }

  Future<void> _createGroup() async {
    final String defaultGroup = context.t('我的好友');
    final String tooLong = context.t('好友分组名最多 32 字');
    final String emptyName = context.t('分组名不能为空');
    final TextEditingController name = TextEditingController();
    final Set<String> selected = <String>{};
    final String? result = await showPaneDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.t('新建分组')),
        content: StatefulBuilder(
          builder: (BuildContext dialogCtx, StateSetter setDialogState) =>
              ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    key: const ValueKey<String>('new-group-name-field'),
                    controller: name,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: context.t('分组名称'),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: NexmemMetrics.space12),
                  Text(context.t('选择要加入的好友')),
                  const SizedBox(height: NexmemMetrics.space4),
                  for (final Contact contact in _friends)
                    CheckboxListTile(
                      key: ValueKey<String>('new-group-contact-${contact.id}'),
                      dense: true,
                      title: Text(contact.name),
                      value: selected.contains(contact.id),
                      onChanged: (bool? checked) => setDialogState(() {
                        if (checked == true) {
                          selected.add(contact.id);
                        } else {
                          selected.remove(contact.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.t('取消')),
          ),
          TextButton(
            key: const ValueKey<String>('new-group-submit'),
            onPressed: () => Navigator.of(ctx).pop(name.text.trim()),
            child: Text(context.t('新建分组')),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) {
      return;
    }
    if (result.runes.length > 32) {
      _fail(tooLong);
      return;
    }
    if (result == defaultGroup) {
      _fail(emptyName);
      return;
    }
    await _setGroupFor(
      _friends.where((Contact contact) => selected.contains(contact.id)),
      result,
    );
  }

  Future<void> _renameGroup(String oldName) async {
    final String tooLong = context.t('好友分组名最多 32 字');
    final TextEditingController name =
        TextEditingController(text: oldName);
    final String? result = await showPaneDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.t('重命名分组')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: TextField(
            key: const ValueKey<String>('rename-group-name-field'),
            controller: name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.t('分组名称'),
              isDense: true,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.t('取消')),
          ),
          TextButton(
            key: const ValueKey<String>('rename-group-submit'),
            onPressed: () => Navigator.of(ctx).pop(name.text.trim()),
            child: Text(context.t('保存')),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == oldName) {
      return;
    }
    if (result.runes.length > 32) {
      _fail(tooLong);
      return;
    }
    await _setGroupFor(
      _friends.where((Contact contact) => _groupOf(contact) == oldName),
      result,
    );
  }

  Future<void> _deleteGroup(String name) async {
    final bool? confirmed = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.t('删除分组')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            context.t('删除分组会将成员移回默认分组，不会删除好友'),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t('取消')),
          ),
          TextButton(
            key: const ValueKey<String>('delete-group-submit'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _setGroupFor(
      _friends.where((Contact contact) => _groupOf(contact) == name),
      '',
    );
    if (mounted) {
      _collapsedGroups.remove(name);
    }
  }

  Future<void> _moveFriend(Contact contact) async {
    final String defaultGroup = context.t('我的好友');
    final List<String> names = <String>{
      defaultGroup,
      for (final Contact item in _friends)
        if (item.groupName.trim().isNotEmpty) item.groupName.trim(),
    }.toList()
      ..sort((String a, String b) {
        if (a == defaultGroup) {
          return -1;
        }
        if (b == defaultGroup) {
          return 1;
        }
        return a.compareTo(b);
      });
    final String? target = await showPaneDialog<String>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(context.t('移动好友')),
        children: <Widget>[
          for (final String group in names)
            SimpleDialogOption(
              key: ValueKey<String>('move-to-$group'),
              onPressed: () => Navigator.of(ctx).pop(group),
              child: Text(group),
            ),
        ],
      ),
    );
    if (target == null) {
      return;
    }
    await _setGroupFor(
      <Contact>[contact],
      target == defaultGroup ? '' : target,
    );
  }

  /// 好友条目默认直接发起聊天；详情页仍可通过条目上的 info 按钮进入。
  void _openChat(Contact contact) {
    final ValueChanged<Contact>? onChat = widget.onOpenContactChat;
    if (onChat != null) {
      onChat(contact);
      return;
    }
    widget.onSendMessage?.call(contact);
  }

  void _openDetail(Contact contact) {
    final void Function(String, {Object? data})? onOpenPane = widget.onOpenPane;
    if (onOpenPane != null) {
      onOpenPane('好友资料', data: contact);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => ContactDetailPage(
          contact: contact,
          service: widget.service,
          onChanged: _apply,
          onDeleted: (_) => unawaited(reload()),
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
    final void Function(String, {Object? data})? onOpenPane = widget.onOpenPane;
    if (onOpenPane != null) {
      onOpenPane('我的设备', data: <String, String>{'peer': '', 'title': '我的设备'});
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
    setState(() => _groupsExpanded = !_groupsExpanded);
    unawaited(reloadGroups());
    final void Function(String, {Object? data})? onOpenPane = widget.onOpenPane;
    if (onOpenPane != null) {
      onOpenPane('群聊');
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

  /// 供右栏好友面板复用添加好友入口。
  Future<void> addFriend() => _addFriend();

  Future<void> _addFriend() async {
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    final bool? added = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          AddFriendDialog(service: service, session: widget.session),
    );
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

  Future<void> _openSocialHub() async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    await showPaneDialog<void>(
      context: context,
      builder: (BuildContext context) => SocialHubPage(session: session),
    );
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
    IconButton(
      key: const ValueKey<String>('contact-new-group-button'),
      tooltip: context.t('新建分组'),
      icon: const Icon(Icons.create_new_folder_outlined, size: 20),
      onPressed: _createGroup,
    ),
    if (widget.session != null)
      IconButton(
        key: const ValueKey<String>('contact-social-hub-button'),
        tooltip: context.t('社交中心'),
        icon: const Icon(Icons.notifications_none, size: 20),
        onPressed: _openSocialHub,
      ),
    if (widget.service != null)
      IconButton(
        key: const ValueKey<String>('contact-add-button'),
        tooltip: context.t('添加好友'),
        icon: const Icon(Icons.person_add_alt_1, size: 20),
        onPressed: _addFriend,
      ),
    if (widget.session != null && widget.service != null)
      IconButton(
        key: const ValueKey<String>('contact-qr-import-button'),
        tooltip: context.t('扫码加好友'),
        icon: const Icon(Icons.qr_code_scanner, size: 20),
        onPressed: _importQr,
      ),
    if (widget.session != null)
      IconButton(
        key: const ValueKey<String>('contact-my-qr-button'),
        tooltip: context.t('我的二维码'),
        icon: const Icon(Icons.qr_code, size: 20),
        onPressed: _showMyQr,
      ),
  ];

  /// 本地通讯录筛选：匹配备注名、分组与账号短串/完整账号。
  List<Contact> _filteredFriends() {
    final String query = _search.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _friends;
    }
    return _friends.where((Contact c) {
      return c.name.toLowerCase().contains(query) ||
          c.groupName.toLowerCase().contains(query) ||
          c.id.toLowerCase().contains(query) ||
          c.peer.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final String defaultGroup = context.t('我的好友');
    final String query = _search.text.trim();
    final List<(String, List<Contact>)> groups = groupFriends(
      _filteredFriends(),
      defaultGroup: defaultGroup,
    );
    final bool showFriends = _friendsExpanded || query.isNotEmpty;
    final bool showGroups = _groupsExpanded || query.isNotEmpty;
    final List<GroupSummary> visibleGroups = query.isEmpty
        ? _groupItems
        : _groupItems
            .where(
              (GroupSummary group) => group.displayTitle.toLowerCase().contains(
                query.toLowerCase(),
              ),
            )
            .toList();
    return Column(
      children: <Widget>[
        PaneHeader(title: context.t('联系人'), actions: _actions),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NexmemMetrics.space12,
            NexmemMetrics.space8,
            NexmemMetrics.space12,
            0,
          ),
          child: TextField(
            key: const ValueKey<String>('contacts-search-field'),
            controller: _search,
            decoration: InputDecoration(
              hintText: context.t('搜索联系人'),
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.t('清除'),
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _search.clear()),
                    ),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: NexmemMetrics.space8),
        const Divider(height: 1),
        if (_error != null) _ErrorBar(message: _error!, onRetry: _reload),
        if (_loading && _friends.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: NexmemMetrics.space16),
              children: <Widget>[
                _GroupEntry(
                  key: const ValueKey<String>('contact-friends-entry'),
                  icon: Icons.person_outline,
                  title: context.t('好友'),
                  expanded: showFriends,
                  onTap: () {
                    setState(
                      () => _friendsExpanded = !_friendsExpanded,
                    );
                    widget.onToggleFriends?.call();
                  },
                ),
                if (showFriends) ...<Widget>[
                  if (groups.isEmpty)
                    const _EmptyFriends()
                  else
                    for (final (String name, List<Contact> members)
                        in groups) ...<Widget>[
                      _FriendGroupHeader(
                        key: ValueKey<String>('contact-group-$name'),
                        name: name,
                        count: members.length,
                        expanded:
                            query.isNotEmpty || !_collapsedGroups.contains(name),
                        canManage: name != defaultGroup,
                        onToggle: () => setState(() {
                          if (_collapsedGroups.contains(name)) {
                            _collapsedGroups.remove(name);
                          } else {
                            _collapsedGroups.add(name);
                          }
                        }),
                        onRename: () => unawaited(_renameGroup(name)),
                        onDelete: () => unawaited(_deleteGroup(name)),
                      ),
                      if (query.isNotEmpty || !_collapsedGroups.contains(name))
                        for (final Contact contact in members)
                          _PresenceContactTile(
                            contact: contact,
                            presence: widget.presence,
                            onTap: () => _openChat(contact),
                            onInfo: () => _openDetail(contact),
                            onMove: () => unawaited(_moveFriend(contact)),
                          ),
                    ],
                ],
                const Divider(height: 1),
                _GroupEntry(
                  key: const ValueKey<String>('contact-groups-entry'),
                  icon: Icons.groups_outlined,
                  title: context.t('群聊'),
                  expanded: widget.groups == null ? null : showGroups,
                  onTap: widget.groups == null ? null : _openGroups,
                ),
                if (showGroups) ...<Widget>[
                  if (_groupsError != null)
                    _ErrorBar(message: _groupsError!, onRetry: _reloadGroups)
                  else if (_groupsLoading && _groupItems.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(NexmemMetrics.space16),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (visibleGroups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NexmemMetrics.space24,
                        vertical: NexmemMetrics.space16,
                      ),
                      child: Text(
                        context.t('还没有群聊，点右上角创建'),
                        key: const ValueKey<String>('contact-group-empty'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.45),
                        ),
                      ),
                    )
                  else
                    for (final GroupSummary group in visibleGroups)
                      _GroupChatTile(
                        key: ValueKey<String>(
                          'contact-group-chat-${group.groupId}',
                        ),
                        group: group,
                        onTap: () => widget.onOpenGroup?.call(
                          group.groupId,
                          group.displayTitle,
                        ),
                      ),
                ],
                const Divider(height: 1),
                _GroupEntry(
                  key: const ValueKey<String>('contact-devices-entry'),
                  icon: Icons.devices_outlined,
                  title: context.t('我的设备'),
                  onTap: widget.service == null ? null : _openMyDevices,
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
            child: Text(context.t('重试')),
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
        context.t('还没有好友，点右上角添加对方账号即可开始聊天'),
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

/// 左栏群聊列表项：点条目直接打开右栏群会话。
class _GroupChatTile extends StatelessWidget {
  const _GroupChatTile({super.key, required this.group, this.onTap});

  final GroupSummary group;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String title = group.displayTitle;
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space12,
          ),
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
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupEntry extends StatelessWidget {
  const _GroupEntry({
    super.key,
    required this.icon,
    required this.title,
    this.onTap,
    this.expanded,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  /// 非空时显示可展开箭头（好友入口）；为空时保持原来的右箭头。
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: ListTile(
        // 外层 SizedBox 只固定高度；不设置 minTileHeight 时 ListTile 内部仍按
        // 56 布局，多出的 4px 留在底部，图标/文字看起来偏上。
        minTileHeight: NexmemMetrics.listItemHeight,
        leading: Icon(icon, size: 22),
        title: Text(title),
        trailing: Icon(
          expanded == null
              ? Icons.chevron_right
              : (expanded! ? Icons.expand_more : Icons.chevron_right),
          size: 18,
        ),
        onTap: onTap,
      ),
    );
  }
}

/// QQ 式好友分组头：点击展开/收起，右侧菜单管理分组。
class _FriendGroupHeader extends StatelessWidget {
  const _FriendGroupHeader({
    super.key,
    required this.name,
    required this.count,
    required this.expanded,
    required this.canManage,
    required this.onToggle,
    this.onRename,
    this.onDelete,
  });

  final String name;
  final int count;
  final bool expanded;
  final bool canManage;
  final VoidCallback onToggle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NexmemMetrics.space12,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: NexmemMetrics.space8),
                    Expanded(
                      child: Text(
                        '$name（$count）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (canManage)
            PopupMenuButton<String>(
              key: ValueKey<String>('contact-group-menu-$name'),
              tooltip: context.t('分组名称'),
              icon: Icon(
                Icons.more_horiz,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
              onSelected: (String value) {
                if (value == 'rename') {
                  onRename?.call();
                } else if (value == 'delete') {
                  onDelete?.call();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'rename',
                  child: Text(context.t('重命名分组')),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Text(context.t('删除分组')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 按在线状态变化重建的联系人条目；无状态源时退化为基础条目。
class _PresenceContactTile extends StatelessWidget {
  const _PresenceContactTile({
    required this.contact,
    this.presence,
    this.onTap,
    this.onInfo,
    this.onMove,
  });

  final Contact contact;
  final ValueListenable<Map<String, bool>>? presence;
  final VoidCallback? onTap;
  final VoidCallback? onInfo;
  final VoidCallback? onMove;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<Map<String, bool>>? listenable = presence;
    if (listenable == null) {
      return _ContactTile(
        contact: contact,
        onTap: onTap,
        onInfo: onInfo,
        onMove: onMove,
      );
    }
    return ValueListenableBuilder<Map<String, bool>>(
      valueListenable: listenable,
      builder: (BuildContext context, Map<String, bool> presence, Widget? _) {
        return _ContactTile(
          contact: contact,
          online: presence[contact.id],
          onTap: onTap,
          onInfo: onInfo,
          onMove: onMove,
        );
      },
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.contact,
    this.onTap,
    this.onInfo,
    this.onMove,
    this.online,
  });

  final Contact contact;
  final VoidCallback? onTap;
  final VoidCallback? onInfo;
  final VoidCallback? onMove;

  /// 在线状态；null 表示未知，不显示状态点。
  final bool? online;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: NexmemMetrics.listItemHeight,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space12,
          ),
          child: Row(
            children: <Widget>[
              AppAvatar(
                seed: contact.id,
                label: contact.name,
                size: 40,
                showPresence: online != null,
                presence: online == true
                    ? AvatarPresence.online
                    : AvatarPresence.offline,
              ),
              const SizedBox(width: NexmemMetrics.space12),
              Expanded(
                child: Text(
                  contact.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontSize: 15),
                ),
              ),
              if (contact.note.isNotEmpty && contact.note != contact.name)
                Flexible(
                  child: Text(
                    contact.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              if (onMove != null)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    key: ValueKey<String>('contact-move-${contact.id}'),
                    tooltip: context.t('移动好友'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.drive_file_move_outline, size: 16),
                    onPressed: onMove,
                  ),
                ),
              if (onInfo != null)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    key: ValueKey<String>('contact-info-${contact.id}'),
                    tooltip: context.t('查看资料'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.info_outline, size: 16),
                    onPressed: onInfo,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
