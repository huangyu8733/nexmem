import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import '../settings/settings_pane.dart' show showPaneDialog;
import 'social_service.dart';

/// 社交中心：好友申请、入群审批与系统通知的统一入口。
class SocialHubPage extends StatefulWidget {
  const SocialHubPage({
    super.key,
    required this.session,
    this.showHeader = true,
  });

  final CoreSession session;

  /// 作为设置项内嵌面板时由外层提供标题，避免重复标题栏。
  final bool showHeader;

  @override
  State<SocialHubPage> createState() => _SocialHubPageState();
}

class _SocialHubPageState extends State<SocialHubPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final SocialService _social;

  List<FriendRequest> _friendReqs = <FriendRequest>[];
  List<GroupJoinRequest> _joinReqs = <GroupJoinRequest>[];
  NotificationList _notifs = const NotificationList(items: <AppNotification>[], unread: 0);
  String? _error;
  bool _loading = true;
  StreamSubscription<CoreEvent>? _events;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _social = widget.session.social;
    // 监听社交事件实时刷新（好友申请、入群审批）。
    _events = widget.session.transport.events.listen((CoreEvent event) {
      if (const <String>{
        'friend.request.new',
        'friend.request.resolved',
        'group.joinRequested',
        'group.joinResolved',
      }.contains(event.type)) {
        unawaited(_reload());
      }
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    _events?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _social.listFriendRequests(),
        _social.listGroupJoinRequests(),
        _social.listNotifications(),
      ]);
      if (!mounted) return;
      setState(() {
        _friendReqs = results[0] as List<FriendRequest>;
        _joinReqs = results[1] as List<GroupJoinRequest>;
        _notifs = results[2] as NotificationList;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _respondFriend(FriendRequest r, bool accept) async {
    await _runAction(() async {
      await _social.respondFriendRequest(r.id, accept);
      await _reload();
    }, context.t('操作成功'));
  }

  Future<void> _respondJoin(GroupJoinRequest r, bool accept) async {
    await _runAction(() async {
      await _social.respondGroupJoin(r.id, accept);
      await _reload();
    }, context.t('操作成功'));
  }

  /// 所有删除入口共用的二次确认与统一反馈；[action] 返回实际删除条数。
  Future<void> _deleteWithConfirm({
    required String title,
    required String body,
    required Future<int> Function() action,
  }) async {
    final bool? confirmed = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('social-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      final int deleted = await action();
      if (!mounted) return;
      _showSuccess(deleted > 0
          ? context.t('已删除 {0} 条记录', ['$deleted'])
          : context.t('没有可删除的记录'));
      await _reload();
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _deleteFriend(FriendRequest r) => _deleteWithConfirm(
        title: context.t('删除好友申请'),
        body: context.t('删除后不可恢复，确定继续？'),
        action: () => _social.deleteFriendRequest(r.id),
      );

  Future<void> _deleteJoin(GroupJoinRequest r) => _deleteWithConfirm(
        title: context.t('删除入群申请'),
        body: context.t('删除后不可恢复，确定继续？'),
        action: () => _social.deleteGroupJoinRequest(r.id),
      );

  Future<void> _deleteNotif(AppNotification n) => _deleteWithConfirm(
        title: context.t('删除通知'),
        body: context.t('删除后不可恢复，确定继续？'),
        action: () => _social.deleteNotification(n.id),
      );

  Future<void> _clearFriends() => _deleteWithConfirm(
        title: context.t('确认清空记录'),
        body: context.t('删除后不可恢复，确定继续？'),
        action: _social.clearFriendRequests,
      );

  Future<void> _clearJoins() => _deleteWithConfirm(
        title: context.t('确认清空记录'),
        body: context.t('删除后不可恢复，确定继续？'),
        action: _social.clearGroupJoinRequests,
      );

  Future<void> _clearNotifs() => _deleteWithConfirm(
        title: context.t('确认清空记录'),
        body: context.t('删除后不可恢复，确定继续？'),
        action: _social.clearNotifications,
      );

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 统一执行社交写操作：失败给出明确提示，成功给出确认反馈。
  Future<bool> _runAction(Future<void> Function() action, String success) async {
    try {
      await action();
      _showSuccess(success);
      return true;
    } catch (e) {
      _showError('$e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        if (widget.showHeader)
          PaneHeader(
            title: context.t('社交中心'),
            actions: <Widget>[
              IconButton(
                key: const ValueKey<String>('social-refresh'),
                tooltip: context.t('刷新'),
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _reload,
              ),
            ],
          ),
        TabBar(
          controller: _tabs,
          tabs: <Widget>[
            Tab(text: context.t('好友申请')),
            Tab(text: context.t('入群申请')),
            Tab(text: context.t('通知')),
          ],
        ),
        if (_error != null)
          _ErrorBar(message: _error!, onRetry: _reload),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabs,
                  children: <Widget>[
                    _friendRequestsTab(),
                    _joinRequestsTab(),
                    _notificationsTab(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _friendRequestsTab() {
    final incoming = _friendReqs.where((r) => r.isIncoming && r.isPending).toList();
    final history = _friendReqs.where((r) => !r.isIncoming || !r.isPending).toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        _sectionTitle(
          context.t('待处理'),
          action: _friendReqs.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey<String>('friend-req-clear'),
                  tooltip: context.t('清空好友申请'),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  onPressed: _clearFriends,
                ),
        ),
        if (incoming.isEmpty) _empty(context.t('暂无新的好友申请')),
        ...incoming.map((r) => _friendRequestTile(r)),
        const SizedBox(height: 12),
        _sectionTitle(context.t('历史记录')),
        if (history.isEmpty) _empty(context.t('暂无记录')),
        ...history.map((r) => _friendRequestTile(r, readonly: true)),
      ],
    );
  }

  Widget _friendRequestTile(FriendRequest r, {bool readonly = false}) {
    final statusText = r.status == 1
        ? context.t('已同意')
        : r.status == 2
            ? context.t('已拒绝')
            : '';
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_add)),
        title: Text(r.isIncoming ? context.t('来自 {0}', [shortId(r.from)]) : context.t('发给 {0}', [shortId(r.to)])),
        subtitle: Text(r.message.isNotEmpty ? r.message : context.t('申请添加你为好友')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (readonly)
              Text(statusText,
                  style: TextStyle(color: Theme.of(context).colorScheme.outline))
            else ...<Widget>[
              IconButton(
                key: ValueKey<String>('friend-req-reject-${r.id}'),
                tooltip: context.t('拒绝'),
                icon: const Icon(Icons.close, color: NexmemColors.danger),
                onPressed: () => _respondFriend(r, false),
              ),
              IconButton(
                key: ValueKey<String>('friend-req-accept-${r.id}'),
                tooltip: context.t('同意'),
                icon: const Icon(Icons.check, color: NexmemColors.success),
                onPressed: () => _respondFriend(r, true),
              ),
            ],
            IconButton(
              key: ValueKey<String>('friend-req-delete-${r.id}'),
              tooltip: context.t('删除好友申请'),
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteFriend(r),
            ),
          ],
        ),
      ),
    );
  }

  Widget _joinRequestsTab() {
    final incoming = _joinReqs.where((r) => r.isIncoming && r.isPending).toList();
    final rest = _joinReqs.where((r) => !r.isIncoming || !r.isPending).toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        _sectionTitle(
          context.t('待审批'),
          action: _joinReqs.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey<String>('join-req-clear'),
                  tooltip: context.t('清空入群申请'),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  onPressed: _clearJoins,
                ),
        ),
        if (incoming.isEmpty) _empty(context.t('暂无入群申请')),
        ...incoming.map((r) => _joinRequestTile(r)),
        const SizedBox(height: 12),
        _sectionTitle(context.t('我的申请')),
        if (rest.isEmpty) _empty(context.t('暂无记录')),
        ...rest.map((r) => _joinRequestTile(r, readonly: true)),
      ],
    );
  }

  Widget _joinRequestTile(GroupJoinRequest r, {bool readonly = false}) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.group_add)),
        title: Text(r.groupTitle.isNotEmpty ? r.groupTitle : context.t('群聊 {0}', [r.groupId.substring(0, r.groupId.length.clamp(0, 8))])),
        subtitle: Text(r.message.isNotEmpty ? r.message : context.t('申请加入群聊')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (readonly)
              Text(r.status == 1
                  ? context.t('已通过')
                  : r.status == 2
                      ? context.t('已拒绝')
                      : context.t('待处理'))
            else ...<Widget>[
              IconButton(
                key: ValueKey<String>('join-req-reject-${r.id}'),
                tooltip: context.t('拒绝'),
                icon: const Icon(Icons.close, color: NexmemColors.danger),
                onPressed: () => _respondJoin(r, false),
              ),
              IconButton(
                key: ValueKey<String>('join-req-accept-${r.id}'),
                tooltip: context.t('同意'),
                icon: const Icon(Icons.check, color: NexmemColors.success),
                onPressed: () => _respondJoin(r, true),
              ),
            ],
            IconButton(
              key: ValueKey<String>('join-req-delete-${r.id}'),
              tooltip: context.t('删除入群申请'),
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteJoin(r),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notificationsTab() {
    return Column(
      children: <Widget>[
        if (_notifs.unread > 0 || _notifs.items.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              alignment: Directionality.of(context) == TextDirection.rtl
                  ? WrapAlignment.start
                  : WrapAlignment.end,
              children: <Widget>[
                if (_notifs.unread > 0)
                  TextButton(
                    onPressed: () => _runAction(() async {
                      await _social.markNotificationRead();
                      await _reload();
                    }, context.t('操作成功')),
                    child: Text(context.t('全部标为已读')),
                  ),
                if (_notifs.items.isNotEmpty)
                  TextButton.icon(
                    key: const ValueKey<String>('notif-clear'),
                    onPressed: _clearNotifs,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: Text(context.t('清空通知')),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _notifs.items.isEmpty
              ? _empty(context.t('暂无通知'))
              : ListView.separated(
                  itemCount: _notifs.items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final n = _notifs.items[i];
                    return ListTile(
                      leading: Icon(n.read ? Icons.notifications_none : Icons.notifications_active,
                          color: n.read ? null : Theme.of(context).colorScheme.primary),
                      title: Text(n.title.isEmpty ? n.kind : n.title,
                          style: TextStyle(fontWeight: n.read ? FontWeight.normal : FontWeight.bold)),
                      subtitle: Text(n.body),
                      trailing: IconButton(
                        key: ValueKey<String>('notification-delete-${n.id}'),
                        tooltip: context.t('删除通知'),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _deleteNotif(n),
                      ),
                      onTap: () {
                        if (!n.read) {
                          unawaited(_runAction(() async {
                            await _social.markNotificationRead(id: n.id);
                            await _reload();
                          }, context.t('操作成功')));
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text, {Widget? action}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: Row(
          children: <Widget>[
            Text(text, style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            if (action case final Widget a) a,
          ],
        ),
      );

  Widget _empty(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.outline))),
      );

  static String shortId(String id) => id.length > 8 ? '${id.substring(0, 8)}…' : id;
}

// 与 contacts_page.dart 内的错误条保持一致的最小实现。
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: <Widget>[
          Expanded(child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))),
          IconButton(
            tooltip: context.t('重试'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ]),
      );
}
