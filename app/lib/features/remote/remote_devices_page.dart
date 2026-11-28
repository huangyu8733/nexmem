// 我的 → 远程设备：设备台账管理 + 群控。
//
// 页面只负责展示与用户交互；目录持久化交给 RemoteDeviceDirectory，
// 连接/断开与广播交给壳层回调。这样在无内核的 Widget 测试里也能验证排版与交互。

import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import 'device_distance.dart';
import 'ip_location.dart';
import 'local_location_controller.dart';
import 'remote_device_directory.dart';
import 'remote_geo_controller.dart';
import 'remote_password.dart';
import 'remote_group_controller.dart';
import 'remote_session.dart';
import '../../app/app_dialog.dart';

/// 由壳层提供的实时远控会话能力。
///
/// 只负责台账管理与群控；扫描发现、地图、自动归属地与本机位置都在独立的
/// 「账号发现」栏目，见 [DeviceDiscoverySheet]。
class RemoteDevicesActions {
  const RemoteDevicesActions({
    required this.sessions,
    this.onConnect,
    this.onDisconnect,
    this.groupController,
    this.onGroupChanged,
  });

  /// peer → 当前会话快照（仅控制端 But including all roles for display）。
  final Map<String, RemoteInfo> sessions;

  final void Function(String peer, String name)? onConnect;
  final void Function(String peer)? onDisconnect;
  final RemoteGroupController? groupController;
  final VoidCallback? onGroupChanged;
}

class RemoteDevicesPage extends StatefulWidget {
  const RemoteDevicesPage({
    super.key,
    required this.directory,
    required this.actions,
    this.embedded = true,
  });

  final RemoteDeviceDirectory directory;
  final RemoteDevicesActions actions;
  final bool embedded;

  @override
  State<RemoteDevicesPage> createState() => _RemoteDevicesPageState();
}

class _RemoteDevicesPageState extends State<RemoteDevicesPage> {
  RemoteDeviceType _filter = RemoteDeviceType.all;
  bool _groupEnabled = false;
  bool _onlineOnly = false;
  final Set<String> _selected = <String>{};

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchTimer;
  String _query = '';
  static const int _pageSize = 50;
  int _visibleCount = _pageSize;

  @override
  void initState() {
    super.initState();
    _groupEnabled = widget.actions.groupController?.enabled ?? false;
    _selected.addAll(widget.actions.groupController?.selected ?? const <String>{});
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant RemoteDevicesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 会话异步掉线时壳层重建本页，State 复用不会重跑 initState。
    // 控制器可能因目标不足两台自动退出群控，本地开关/勾选需跟随其权威状态，
    // 避免 UI 仍显示「群控中」但输入已退化为单控。
    _syncFromGroup();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
        _visibleCount = _pageSize;
      });
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _visibleCount >= _views.length) {
      return;
    }
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 240) {
      setState(() {
        _visibleCount = (_visibleCount + _pageSize).clamp(_pageSize, _views.length);
      });
    }
  }

  List<RemoteDeviceView> get _views {
    final Map<String, RemoteInfo> sessions = widget.actions.sessions;
    final List<RemoteDeviceView> views = <RemoteDeviceView>[
      for (final RemoteDevice device in widget.directory.devices)
        RemoteDeviceView(device: device, info: sessions[device.peer]),
    ];
    return views.where((RemoteDeviceView view) {
      if (_filter != RemoteDeviceType.all && view.device.type != _filter) {
        return false;
      }
      if (_onlineOnly && !view.connected) {
        return false;
      }
      if (_query.isEmpty) {
        return true;
      }
      final String haystack = <String>[
        view.device.name,
        view.device.peer,
        view.device.note,
        view.device.region,
        view.device.type.label,
        view.info?.state.label ?? '',
      ].join(' ').toLowerCase();
      return haystack.contains(_query);
    }).toList();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
    widget.actions.onGroupChanged?.call();
  }

  /// 控制器可能因会话结束自动退出群控，本地勾选/开关需跟随。
  void _syncFromGroup() {
    final RemoteGroupController? group = widget.actions.groupController;
    if (group == null) {
      return;
    }
    _groupEnabled = group.enabled;
    _selected
      ..clear()
      ..addAll(group.selected);
  }

  Future<void> _showEditor({RemoteDevice? device}) async {
    final String? result = await showAppDialog<String>(
      context: context,
      builder: (BuildContext context) => _DeviceEditorDialog(device: device),
    );
    if (result == null) {
      return;
    }
    // 备注允许用户换行，绝不能用换行拼接字段，否则 credential 会被污染。
    final Object? decoded;
    try {
      decoded = jsonDecode(result);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    final String peer = (decoded['peer'] as String? ?? '').trim();
    final String name = (decoded['name'] as String? ?? '').trim();
    final RemoteDeviceType type =
        RemoteDeviceType.fromWire(decoded['type'] as String? ?? '') ??
            RemoteDeviceType.other;
    final String note = (decoded['note'] as String? ?? '').trim();
    final String credential = (decoded['credential'] as String? ?? '').trim();
    final RemoteGroupController? group = widget.actions.groupController;
    if (device == null) {
      await widget.directory.add(
        peer: peer,
        name: name,
        type: type,
        note: note,
        credential: credential,
      );
    } else {
      // 编辑只改远控所需字段；地区与坐标由账号发现页独立维护，不在这里暴露。
      await widget.directory.update(
        device.peer,
        name: name,
        type: type,
        note: note,
        credential: credential.isEmpty ? null : credential,
      );
    }
    // 类型变化后群控目标随之失效，重置为当前筛选或「其他」。
    if (group != null && device != null && device.type != type) {
      group.setGroupType(type);
      _syncFromGroup();
    } else {
      group?.sync();
      _syncFromGroup();
    }
    _changed();
  }

  Future<void> _remove(RemoteDevice device) async {
    final bool? confirm = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('删除设备')),
        content: Text(
          context.t('确定删除「{0}」吗？不会断开正在进行的会话。', [device.name]),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('remote-device-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirm != true) {
      return;
    }
    await widget.directory.remove(device.peer);
    _selected.remove(device.peer);
    widget.actions.groupController?.sync();
    _syncFromGroup();
    _changed();
  }

  void _connect(RemoteDevice device) {
    widget.actions.onConnect?.call(device.peer, device.name);
  }

  void _disconnect(RemoteDevice device) {
    widget.actions.onDisconnect?.call(device.peer);
  }

  void _selectFilter(RemoteDeviceType type) {
    setState(() {
      _filter = type;
      _visibleCount = _pageSize;
    });
    final RemoteGroupController? group = widget.actions.groupController;
    if (group == null || type == RemoteDeviceType.all) {
      return;
    }
    group.setGroupType(type);
    _syncFromGroup();
    widget.actions.onGroupChanged?.call();
  }

  void _toggleGroup() {
    final RemoteGroupController? group = widget.actions.groupController;
    if (group == null) {
      return;
    }
    group.setEnabled(!group.enabled);
    _syncFromGroup();
    _changed();
  }

  /// 打开完整的群控选择面板：选设备类型、逐台勾选、开关群控、批量断开。
  void _openGroupSheet() {
    final RemoteGroupController? group = widget.actions.groupController;
    if (group == null) {
      return;
    }
    group.sync();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext _) => RemoteGroupSheet(
        controller: group,
        onChanged: () {
          _syncFromGroup();
          _changed();
        },
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

  /// 勾选的设备名，按台账顺序展示，最多 4 个。
  List<String> get _selectedNames {
    final List<String> names = <String>[];
    for (final RemoteDevice device in widget.directory.devices) {
      if (_selected.contains(device.peer)) {
        names.add(device.name);
      }
    }
    return names.length > 4 ? names.sublist(0, 4) : names;
  }

  void _toggleDevice(RemoteDevice device) {
    final RemoteGroupController? group = widget.actions.groupController;
    if (group == null) {
      return;
    }
    group.toggle(device.peer);
    _syncFromGroup();
    _changed();
  }

  Future<void> _endSelected() async {
    final RemoteGroupController? group = widget.actions.groupController;
    if (group == null) {
      return;
    }
    await group.endSelected();
    _syncFromGroup();
    _changed();
  }

  Widget _buildBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<RemoteDeviceView> views = _views;
    final bool empty = widget.directory.devices.isEmpty;
    final int shownCount = views.length < _visibleCount ? views.length : _visibleCount;
    final bool hasMore = shownCount < views.length;
    final int itemCount = empty ? 2 : 2 + shownCount + (hasMore ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return _buildSearchHeader(theme);
        }
        if (index == 1) {
          if (empty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Column(
                  children: <Widget>[
                    Icon(
                      Icons.devices_other_outlined,
                      size: 48,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.t('暂无远程设备，点击右上角添加'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            );
          }
          return _buildGroupCard(theme);
        }
        if (index == 2 + shownCount) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: TextButton.icon(
                key: const ValueKey<String>('remote-devices-load-more'),
                onPressed: () {
                  setState(() {
                    _visibleCount = (_visibleCount + _pageSize)
                        .clamp(_pageSize, views.length);
                  });
                },
                icon: const Icon(Icons.expand_more, size: 16),
                label: Text(context.t('加载更多（{0}/{1}）', [shownCount, views.length])),
              ),
            ),
          );
        }
        return _buildDeviceCard(views[index - 2], theme);
      },
    );
  }

  Widget _buildSearchHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('remote-devices-search'),
            controller: _searchController,
            decoration: InputDecoration(
              hintText: context.t('搜索设备名称 / 账号 / IP / 备注'),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => _searchController.clear(),
                    ),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                FilterChip(
                  key: const ValueKey<String>('remote-devices-online-only'),
                  avatar: const Icon(Icons.wifi, size: 16),
                  label: Text(context.t('仅在线')),
                  selected: _onlineOnly,
                  onSelected: (bool selected) {
                    setState(() {
                      _onlineOnly = selected;
                      _visibleCount = _pageSize;
                    });
                  },
                ),
                const SizedBox(width: 8),
                for (final RemoteDeviceType type in RemoteDeviceType.values)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ChoiceChip(
                      key: ValueKey<String>('remote-devices-filter-${type.name}'),
                      avatar: Icon(type.icon, size: 16),
                      label: Text(context.t(type.label)),
                      selected: _filter == type,
                      onSelected: (_) => _selectFilter(type),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(ThemeData theme) {
    final RemoteGroupController? group = widget.actions.groupController;
    // 群控目标由控制器按「当前设备类型」过滤；连接数也按同类型统计，
    // 避免把别的平台设备算进来导致开关误可用。
    final int connectedCount = group?.availableTargets.length ??
        <RemoteDeviceView>[
          for (final RemoteDevice device in widget.directory.devices)
            RemoteDeviceView(
              device: device,
              info: widget.actions.sessions[device.peer],
            ),
        ].where((RemoteDeviceView view) => view.connected).length;
    final RemoteDeviceType groupType = group?.groupType ?? RemoteDeviceType.other;
    // 默认类型「其他」下若只有别的类型在线，提示用户去选类型，而不是只显示
    // 「至少需要两台同类型设备在线」让人误以为没有可用设备。
    final int otherOnline = connectedCount == 0 && group != null
        ? widget.directory.devices.where((RemoteDevice device) =>
            widget.actions.sessions[device.peer]?.isActive == true &&
            group.typeOf(device.peer) != groupType).length
        : 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SwitchListTile(
              key: const ValueKey<String>('remote-devices-group-enabled'),
              contentPadding: EdgeInsets.zero,
              value: _groupEnabled,
              onChanged: connectedCount > 1 ? (_) => _toggleGroup() : null,
              title: Text(context.t('群控模式')),
              subtitle: Text(
                connectedCount > 1
                    ? context.t('{0} · 已选择 {1} 台', [
                        context.t(groupType.label),
                        _selected.length,
                      ])
                    : otherOnline > 0
                        ? context.t('请点「选择设备」指定在线设备的类型')
                        : context.t('至少需要两台同类型设备在线才能群控'),
              ),
              secondary: Icon(groupType.icon, color: theme.colorScheme.primary),
            ),
            if (_selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final String name in _selectedNames)
                      Chip(
                        key: ValueKey<String>('remote-devices-selected-$name'),
                        label: Text(name),
                        visualDensity: VisualDensity.compact,
                      ),
                    if (_selected.length > 4)
                      Chip(label: Text('+${_selected.length - 4}')),
                  ],
                ),
              ),
            Row(
              children: <Widget>[
                TextButton.icon(
                  key: const ValueKey<String>('remote-devices-select-device'),
                  onPressed: group == null ? null : _openGroupSheet,
                  icon: const Icon(Icons.devices_other, size: 16),
                  label: Text(context.t('选择设备')),
                ),
                TextButton(
                  key: const ValueKey<String>('remote-devices-select-all'),
                  onPressed: connectedCount == 0
                      ? null
                      : () {
                          group?.selectAll();
                          _selected
                            ..clear()
                            ..addAll(group?.selected ?? const <String>{});
                          _changed();
                        },
                  child: Text(context.t('全选')),
                ),
                TextButton(
                  key: const ValueKey<String>('remote-devices-clear'),
                  onPressed: () {
                    group?.clearSelection();
                    _selected.clear();
                    _changed();
                  },
                  child: Text(context.t('清空')),
                ),
                const Spacer(),
                FilledButton.tonal(
                  key: const ValueKey<String>('remote-devices-end-selected'),
                  onPressed:
                      _selected.isEmpty ? null : () => unawaited(_endSelected()),
                  child: Text(context.t('断开所选')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(RemoteDeviceView view, ThemeData theme) {
    final RemoteGroupController? group = widget.actions.groupController;
    return Card(
      key: ValueKey<String>('remote-device-card-${view.device.peer}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: view.connected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            view.connected ? Icons.link : Icons.devices_outlined,
            size: 20,
          ),
        ),
        title: Text(
          view.device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${context.t(view.statusLabel)} · ${context.t(view.device.type.label)}'
          '${view.device.note.isEmpty ? '' : ' · ${view.device.note}'}'
          '${view.device.hasLocation ? ' · ${context.t('已标注位置')}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 同为在线、同类型的设备可直接勾选，不必再进菜单找「加入群控」。
            if (group != null &&
                view.connected &&
                group.typeOf(view.device.peer) == group.groupType)
              Checkbox(
                key: ValueKey<String>(
                  'remote-devices-select-${view.device.peer}',
                ),
                value: _selected.contains(view.device.peer),
                onChanged: (_) => _toggleDevice(view.device),
              ),
            PopupMenuButton<String>(
              key: ValueKey<String>('remote-device-menu-${view.device.peer}'),
              onSelected: (String action) {
                switch (action) {
                  case 'connect':
                    _connect(view.device);
                  case 'disconnect':
                    _disconnect(view.device);
                  case 'edit':
                    unawaited(_showEditor(device: view.device));
                  case 'delete':
                    unawaited(_remove(view.device));
                  case 'select':
                    _toggleDevice(view.device);
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                if (!view.connected)
                  PopupMenuItem<String>(
                    value: 'connect',
                    child: Text(context.t('连接')),
                  ),
                if (view.connected)
                  PopupMenuItem<String>(
                    value: 'disconnect',
                    child: Text(context.t('断开')),
                  ),
                if (group != null &&
                    view.connected &&
                    group.typeOf(view.device.peer) == group.groupType)
                  PopupMenuItem<String>(
                    value: 'select',
                    child: Text(
                      _selected.contains(view.device.peer)
                          ? context.t('取消群控选中')
                          : context.t('加入群控'),
                    ),
                  ),
                PopupMenuItem<String>(
                  value: 'edit',
                  child: Text(context.t('编辑')),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Text(context.t('删除')),
                ),
              ],
            ),
          ],
        ),
        onTap: () =>
            view.connected ? _disconnect(view.device) : _connect(view.device),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = _buildBody(context);
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: Text(context.t('远程设备')),
          actions: <Widget>[
            IconButton(
              key: const ValueKey<String>('remote-devices-add'),
              tooltip: context.t('添加设备'),
              icon: const Icon(Icons.add),
              onPressed: () => unawaited(_showEditor()),
            ),
          ],
        ),
        body: body,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(
          title: context.t('远程设备'),
          actions: <Widget>[
            IconButton(
              key: const ValueKey<String>('remote-devices-add'),
              tooltip: context.t('添加设备'),
              icon: const Icon(Icons.add),
              onPressed: () => unawaited(_showEditor()),
            ),
          ],
        ),
        Expanded(child: body),
      ],
    );
  }
}

/// 新增 / 编辑设备对话框。用换行分隔的纯字符串回传，避免引入额外模型依赖。
class _DeviceEditorDialog extends StatefulWidget {
  const _DeviceEditorDialog({this.device});

  final RemoteDevice? device;

  @override
  State<_DeviceEditorDialog> createState() => _DeviceEditorDialogState();
}

class _DeviceEditorDialogState extends State<_DeviceEditorDialog> {
  late final TextEditingController _peer =
      TextEditingController(text: widget.device?.peer ?? '');
  late final TextEditingController _name =
      TextEditingController(text: widget.device?.name ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.device?.note ?? '');
  late final TextEditingController _password = TextEditingController();
  late final TextEditingController _passwordConfirm = TextEditingController();
  bool _obscurePassword = true;
  String? _error;
  late RemoteDeviceType _type =
      widget.device?.type ?? RemoteDeviceType.other;

  @override
  void dispose() {
    _peer.dispose();
    _name.dispose();
    _note.dispose();
    _password.dispose();
    _passwordConfirm.dispose();
    super.dispose();
  }

  void _submit() {
    final String peer = _peer.text.trim();
    if (peer.isEmpty) {
      setState(() => _error = '设备账号不能为空');
      return;
    }
    final String password = _password.text;
    String credential = '';
    if (widget.device == null || password.isNotEmpty) {
      final String? problem = validateRemotePassword(password);
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
      if (password != _passwordConfirm.text) {
        setState(() => _error = '两次密码不一致');
        return;
      }
      credential = remotePasswordCredential(password);
    }
    Navigator.pop(
      context,
      jsonEncode(<String, String>{
        'peer': peer,
        'name': _name.text.trim(),
        'type': _type.name,
        'note': _note.text.trim(),
        'credential': credential,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        context.t(widget.device == null ? '添加设备' : '编辑设备'),
      ),
      content: responsiveDialogContent(
        context: context,
        maxWidth: 420,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('remote-device-peer'),
              controller: _peer,
              decoration: InputDecoration(
                labelText: context.t('设备账号 / Peer ID'),
              ),
              enabled: widget.device == null,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('remote-device-name'),
              controller: _name,
              decoration: InputDecoration(labelText: context.t('设备名称')),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<RemoteDeviceType>(
              key: const ValueKey<String>('remote-device-type'),
              initialValue: _type,
              decoration: InputDecoration(labelText: context.t('设备类型')),
              items: <DropdownMenuItem<RemoteDeviceType>>[
                for (final RemoteDeviceType type
                    in RemoteDeviceType.assignable)
                  DropdownMenuItem<RemoteDeviceType>(
                    value: type,
                    child: Text(context.t(type.label)),
                  ),
              ],
              onChanged: (RemoteDeviceType? value) {
                if (value != null) {
                  setState(() => _type = value);
                }
              },
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('remote-device-note'),
              controller: _note,
              decoration: InputDecoration(labelText: context.t('备注')),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('remote-device-password'),
              controller: _password,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: context.t('远程控制密码'),
                hintText: context.t(widget.device == null
                    ? '至少 6 位，保存后用于连接该设备'
                    : '留空表示不修改'),
                suffixIcon: IconButton(
                  tooltip: context.t(_obscurePassword ? '显示密码' : '隐藏密码'),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('remote-device-password-confirm'),
              controller: _passwordConfirm,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: context.t('确认远程控制密码'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  context.t(_error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('remote-device-save'),
          onPressed: _submit,
          child: Text(context.t('保存')),
        ),
      ],
    );
  }
}

/// 账号发现页：展示内核汇总的地址簿/mDNS/已连接/peerstore 节点。
///
/// 独立的「我的 → 账号发现」栏目；[embedded] 为 true 时铺满右栏，false 时
/// 作为移动端全屏页。这里用于发现账号并添加好友，不涉及远控密码或台账。
class DeviceDiscoverySheet extends StatefulWidget {
  const DeviceDiscoverySheet({
    super.key,
    required this.discover,
    required this.directory,
    required this.onAddFriend,
    this.localLocation,
    this.geo,
    this.onOpenMap,
    this.onAdded,
    this.embedded = false,
  });

  final Future<DeviceDiscoverPage> Function({
    required int limit,
    required int offset,
  }) discover;
  /// 台账只用于读取手动标注的坐标估算距离，添加好友不写入台账。
  final RemoteDeviceDirectory directory;

  /// 由壳层打开「添加好友」弹窗并发送好友申请；返回 true 表示已发送。
  final Future<bool?> Function(DiscoveredDevice device) onAddFriend;

  final LocalLocationController? localLocation;
  final RemoteGeoController? geo;
  final VoidCallback? onOpenMap;
  final VoidCallback? onAdded;
  final bool embedded;

  @override
  State<DeviceDiscoverySheet> createState() => _DeviceDiscoverySheetState();
}

class _DeviceDiscoverySheetState extends State<DeviceDiscoverySheet> {
  static const int _pageSize = 50;

  final TextEditingController _search = TextEditingController();
  final List<DiscoveredDevice> _items = <DiscoveredDevice>[];
  int _total = 0;
  int _offset = 0;
  bool _loading = false;
  bool _initialLoaded = false;
  String? _error;
  DiscoveryDiagnostics _diag = const DiscoveryDiagnostics();

  @override
  void initState() {
    super.initState();
    widget.localLocation?.addListener(_onLocationChanged);
    widget.geo?.addListener(_onLocationChanged);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    widget.localLocation?.removeListener(_onLocationChanged);
    widget.geo?.removeListener(_onLocationChanged);
    _search.dispose();
    super.dispose();
  }

  void _onLocationChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// IP 库已随程序内置，启用前只需说明本机推断的隐私边界。
  Future<void> _toggleAutoGeo(bool value) async {
    final RemoteGeoController? geo = widget.geo;
    if (geo == null || !value) {
      await geo?.setEnabled(false);
      return;
    }
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('启用自动归属地')),
        content: SingleChildScrollView(
          child: Text(
            context.t(
              '程序已内置离线 IP 库，启用后依据 P2P 连接中的 IP 在本机推断省市与地图中心点。'
              '不会上传你的 IP 或位置，也不会把归属地发送给对端；已手动填写的地区和坐标不会被覆盖。',
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('device-discovery-geo-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.t('同意并启用')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await geo.setEnabled(true);
      if (geo.enabled) {
        unawaited(geo.enrichAll());
      }
    }
  }

  Widget _buildAutoGeoChip(RemoteGeoController geo) {
    final String label = geo.loading
        ? context.t('正在加载内置 IP 库')
        : context.t('自动归属地');
    return FilterChip(
      key: const ValueKey<String>('device-discovery-auto-geo'),
      avatar: geo.loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.public, size: 16),
      label: Text(label),
      selected: geo.enabled,
      onSelected: geo.loading ? null : (bool value) => unawaited(_toggleAutoGeo(value)),
      tooltip: context.t('本机离线推断，默认关闭；不会上传 IP 或位置'),
    );
  }

  /// 远端坐标优先取台账中手动标注的值；未标注时，若用户已同意自动归属地，
  /// 用公网 IP 临时推断城市中心点（不写回台账）。私网 IP 不会推断。
  double? _distanceTo(DiscoveredDevice device) {
    final LocalLocationController? local = widget.localLocation;
    if (local == null || !local.hasLocation) {
      return null;
    }
    final RemoteDevice? saved = widget.directory.find(device.directoryKey);
    double? latitude = saved?.latitude;
    double? longitude = saved?.longitude;
    final RemoteGeoController? geo = widget.geo;
    if ((latitude == null || longitude == null) &&
        geo != null &&
        geo.enabled &&
        geo.service.loaded &&
        device.ip.isNotEmpty) {
      final IpRegion? region = geo.service.lookup(device.ip);
      latitude = region?.latitude;
      longitude = region?.longitude;
    }
    return distanceMeters(
      fromLatitude: local.latitude,
      fromLongitude: local.longitude,
      toLatitude: latitude,
      toLongitude: longitude,
    );
  }

  Future<void> _load({required bool reset}) async {
    if (_loading) {
      return;
    }
    if (reset) {
      _offset = 0;
      _items.clear();
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final DeviceDiscoverPage page =
          await widget.discover(limit: _pageSize, offset: _offset);
      if (!mounted) {
        return;
      }
      setState(() {
        _items.addAll(page.items);
        _offset = page.offset + page.items.length;
        _total = page.total;
        _diag = page.diagnostics;
        // 诊断日志：真机排查 mDNS/局域网发现为空时可直接从 logcat 读取。
        debugPrint(
          'NEXMEM_DISCOVERY_DIAG mdns=${page.diagnostics.mdnsEnabled} '
          'mdnsRaw=${page.diagnostics.mdnsRaw} '
          'peerbook=${page.diagnostics.peerbookRaw} '
          'connected=${page.diagnostics.connectedRaw} '
          'peerstore=${page.diagnostics.peerstoreRaw} '
          'filteredInfra=${page.diagnostics.filteredInfra} '
          'filteredProto=${page.diagnostics.filteredNoProtocol} '
          'hasLan=${page.diagnostics.hasLanAddr} '
          'lanBeacon=${page.diagnostics.lanBeaconActive} '
          'lanRaw=${page.diagnostics.lanRaw} '
          'lanBcastErr=${page.diagnostics.lanBroadcastError} '
          'lanBcastAddr=${page.diagnostics.lanBroadcastAddr} '
          'lanBcastSent=${page.diagnostics.lanBroadcastSent} '
          'injected=${page.diagnostics.injectedLan} '
          'selfAddrs=${page.diagnostics.selfAddrs} '
          'netIfaces=${page.diagnostics.netIfaces}',
        );
        _initialLoaded = true;
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _initialLoaded = true;
        _error = '$e';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 根据内核诊断生成空态原因，帮助用户区分"没权限/没地址/没节点/被过滤"。
  List<({String key, List<Object> args})> _diagnosticHints() {
    final DiscoveryDiagnostics d = _diag;
    final List<({String key, List<Object> args})> hints =
        <({String key, List<Object> args})>[];
    // LAN Beacon（UDP 广播签名名片）是同网段发现的可靠通道，不依赖
    // net.Interfaces()/mDNS。只要它已启动，本机就能被同网段设备发现，
    // 不能再报「未获取到局域网地址」或「局域网发现启动失败」误导用户。
    if (!d.hasLanAddr && !d.lanBeaconActive) {
      hints.add((
        key: '本机未获取到局域网地址，无法被同网段设备发现',
        args: <Object>[],
      ));
    }
    if (!d.mdnsEnabled) {
      if (d.lanBeaconActive) {
        // mDNS 被系统拦截但原生 UDP 广播已接管，降级提示而非报错。
        hints.add((
          key: '系统 mDNS 不可用，已启用原生局域网广播发现（等待同网段设备）',
          args: <Object>[],
        ));
      } else if (d.mdnsError.isNotEmpty) {
        // 既无 mDNS 也无 LAN Beacon：才是真正的全局启动失败。
        hints.add((
          key: '局域网发现启动失败：{0}',
          args: <Object>[d.mdnsError],
        ));
      } else {
        hints.add((
          key: '局域网发现未开启，请在设置中打开',
          args: <Object>[],
        ));
      }
    } else if (d.mdnsRaw == 0 && d.connectedRaw == 0 && d.lanRaw == 0) {
      hints.add((
        key: 'mDNS 已开启，但局域网内没有发现其他节点',
        args: <Object>[],
      ));
    }
    if (d.lanBeaconActive && d.lanBroadcastError.isNotEmpty) {
      // 广播发不出去：本机可被发现但别人发现不了自己（iOS 权限/路由常见）。
      hints.add((
        key: '局域网广播失败：{0}',
        args: <Object>[d.lanBroadcastError],
      ));
    }
    if (d.lanBeaconActive &&
        d.lanBroadcastError.isEmpty &&
        d.lanBroadcastSent == 0) {
      // 发送 socket 未成功写出任何包：常见于 iOS 把 255.255.255.255
      // 从蜂窝默认路由发出，或系统未授予本地网络权限。源地址可直接看出
      // 是否绑定到了注入的 WiFi IP。
      hints.add((
        key: '局域网广播尚未发出，源地址：{0}',
        args: <Object>[
          d.lanBroadcastAddr.isEmpty ? '默认路由' : d.lanBroadcastAddr,
        ],
      ));
    }
    if (d.filteredNoProtocol > 0) {
      hints.add((
        key: '已发现 {0} 个节点，但不是可添加的账号',
        args: <Object>[d.filteredNoProtocol],
      ));
    }
    if (d.netIfaces.isNotEmpty || d.injectedLan.isNotEmpty) {
      hints.add((
        key: '诊断网卡：{0}',
        args: <Object>[
          '${d.netIfaces.join('、')} | 注入=${d.injectedLan.join('、')}',
        ],
      ));
    }
    if (d.selfAddrs.isNotEmpty || d.listenAddrs.isNotEmpty) {
      hints.add((
        key: '诊断监听地址：{0}',
        args: <Object>[[...d.selfAddrs, ...d.listenAddrs].join('、')],
      ));
    }
    hints.add((
      key: '同一 WiFi 下双方都要打开账号发现，iOS 还需在系统设置允许本地网络权限',
      args: <Object>[],
    ));
    return hints;
  }

  List<DiscoveredDevice> get _filtered {
    final String query = _search.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _items;
    }
    return _items.where((DiscoveredDevice device) {
      return <String>[
        device.displayName,
        device.peerId,
        device.accountId,
        device.ip,
        device.source,
      ].join(' ').toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _add(DiscoveredDevice device) async {
    // 账号发现只用于添加好友：不再要求远控密码，也不写入远控台账。
    final bool? added = await widget.onAddFriend(device);
    if (!mounted || added != true) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t('已发送好友申请'))),
    );
    widget.onAdded?.call();
  }

  List<Widget> _buildHeaderActions(BuildContext context) {
    return <Widget>[
      IconButton(
        key: const ValueKey<String>('device-discovery-map'),
        tooltip: context.t('设备地图'),
        icon: const Icon(Icons.map_outlined),
        onPressed: widget.onOpenMap,
      ),
      IconButton(
        key: const ValueKey<String>('device-discovery-refresh'),
        tooltip: context.t('重新扫描'),
        icon: const Icon(Icons.refresh),
        onPressed: _loading ? null : () => unawaited(_load(reset: true)),
      ),
    ];
  }

  Widget _buildContent(ThemeData theme) {
    final List<DiscoveredDevice> devices = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.localLocation != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.my_location,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.localLocation!.hasLocation
                        ? context.t('本机位置已设置')
                        : context.t('未设置本机位置，无法计算距离'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  key: const ValueKey<String>(
                    'device-discovery-local-location',
                  ),
                  onPressed: () => unawaited(
                    showLocalLocationDialog(
                      context: context,
                      controller: widget.localLocation!,
                    ),
                  ),
                  child: Text(context.t('设置本机位置')),
                ),
              ],
            ),
          ),
        if (widget.geo != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildAutoGeoChip(widget.geo!),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: TextField(
            key: const ValueKey<String>('device-discovery-search'),
            controller: _search,
            decoration: InputDecoration(
              hintText: context.t('搜索发现结果'),
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              context.t('发现失败：{0}', [_error!]),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Expanded(
          child: !_initialLoaded && _loading
              ? const Center(child: CircularProgressIndicator())
              : devices.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            Text(
                              context.t('没有发现可添加的账号；可检查 mDNS 与地址簿设置'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 12),
                            ..._diagnosticHints().map(
                              (h) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Text(
                                  '• ${context.t(h.key, h.args)}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey<String>('device-discovery-list'),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: devices.length + (_offset < _total ? 1 : 0),
                      itemBuilder: (BuildContext context, int index) {
                        if (index == devices.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: OutlinedButton.icon(
                                key: const ValueKey<String>(
                                  'device-discovery-load-more',
                                ),
                                onPressed: _loading
                                    ? null
                                    : () => unawaited(_load(reset: false)),
                                icon: const Icon(Icons.expand_more, size: 16),
                                label: Text(context.t('加载更多')),
                              ),
                            ),
                          );
                        }
                        final DiscoveredDevice device = devices[index];
                        final double? distance = _distanceTo(device);
                        return Card(
                          key: ValueKey<String>(
                            'device-discovery-${device.peerId}',
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Icon(
                                device.connected
                                    ? Icons.link
                                    : Icons.devices_outlined,
                                size: 18,
                              ),
                            ),
                            title: Text(
                              device.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              <String>[
                                device.peerId,
                                if (device.ip.isNotEmpty) device.ip,
                                if (device.source.isNotEmpty) device.source,
                                if (device.connected)
                                  context.t(device.direct ? '直连' : '中继'),
                                if (distance != null)
                                  context.t('距离约 {0}', [
                                    formatDistance(distance),
                                  ]),
                              ].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: FilledButton.tonal(
                              key: ValueKey<String>(
                                'device-discovery-add-${device.peerId}',
                              ),
                              onPressed: () => unawaited(_add(device)),
                              child: Text(context.t('加好友')),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = SafeArea(child: _buildContent(Theme.of(context)));
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader(
            title: context.t('账号发现'),
            actions: _buildHeaderActions(context),
          ),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('账号发现')),
        actions: _buildHeaderActions(context),
      ),
      body: body,
    );
  }
}
