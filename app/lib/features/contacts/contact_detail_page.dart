import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../transport/transport.dart';
import 'contact.dart';
import 'contact_service.dart';
import 'device_list_page.dart';

/// 好友资料页（P2-06 / P6-30，ui-spec.md §4）：备注、分组、拉黑与发消息入口。
///
/// 备注与分组只写入本机数据库，不会随任何报文上行；接入 [service] 后分别经
/// 内核 `contact.remark` / `contact.setGroup` / `contact.block` 落库，失败回滚界面状态。
class ContactDetailPage extends StatefulWidget {
  const ContactDetailPage({
    super.key,
    required this.contact,
    this.service,
    this.onChanged,
    this.onSendMessage,
    this.onStartRemote,
    this.onOpenDevices,
    this.onDeleted,
    this.embedded = false,
  });

  final Contact contact;

  /// 内核通讯录服务；为空时只更新本地内存（Widget 测试与离线部署）。
  final ContactService? service;

  /// 备注或拉黑状态变化时回调，由列表页回写本地记录。
  final ValueChanged<Contact>? onChanged;

  /// 点击「发消息」；为空表示当前还没有可用的内核通道。
  final VoidCallback? onSendMessage;

  /// 点击「远程控制」；为空或已拉黑时不展示。
  final VoidCallback? onStartRemote;

  /// 点击「设备」行：传 `(peerId, title)` 由调用方展示设备列表。
  final void Function(String peer, String title)? onOpenDevices;

  /// 删除好友成功后回调，参数为被删除的账号；由调用方刷新列表/关闭面板。
  final ValueChanged<Contact>? onDeleted;

  /// 为 true 时以面板形式渲染（桌面右栏 / 手机全屏页复用），不套 Scaffold。
  final bool embedded;

  @override
  State<ContactDetailPage> createState() => _ContactDetailPageState();
}

class _ContactDetailPageState extends State<ContactDetailPage> {
  /// 与内核 MaxContactGroupRunes 对齐：分组名最多 32 个 Unicode 码点。
  static const int _maxGroupRunes = 32;

  /// 当前分组输入是否超限（按 Unicode 码点计）。
  bool get _groupOverLimit => _group.text.runes.length > _maxGroupRunes;

  late Contact _contact = widget.contact;
  late final TextEditingController _note =
      TextEditingController(text: widget.contact.note);
  late final TextEditingController _group =
      TextEditingController(text: widget.contact.groupName);
  List<DeviceInfo> _devices = const <DeviceInfo>[];
  bool _devicesLoading = false;
  String? _devicesError;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _note.dispose();
    _group.dispose();
    super.dispose();
  }

  /// 拉取对方公开档案里的设备列表（P6-21）；失败只提示，不阻塞资料页其它操作。
  Future<void> _loadDevices() async {
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    setState(() {
      _devicesLoading = true;
      _devicesError = null;
    });
    try {
      final DeviceListResult result = await service.devices(peer: _contact.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = result.items;
        _devicesLoading = false;
      });
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _devicesLoading = false;
        _devicesError = error.message.isEmpty ? error.code : error.message;
      });
    }
  }

  /// 设备入口标题：读取成功后附带台数。
  String _devicesTitle() {
    if (_devicesLoading || _devicesError != null || _devices.isEmpty) {
      return context.t('设备');
    }
    return context.t('设备（{0} 台）', [_devices.length]);
  }

  /// 设备入口摘要：设备名与最近活跃时间，点击进入完整列表。
  String _devicesSummary() {
    if (_devicesError != null) {
      return context.t('设备列表读取失败：{0}', [_devicesError]);
    }
    if (_devicesLoading) {
      return context.t('正在读取设备…');
    }
    if (_devices.isEmpty) {
      return context.t('该账号尚未发布设备信息');
    }
    final String names =
        _devices.take(3).map((DeviceInfo d) => d.name).join('、');
    return '$names · ${deviceActiveLabel(_devices.first.issuedAt, context.l10n)}';
  }

  void _openDevices() {
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    final String peer = _contact.id;
    final String title = context.t('{0}的设备', [_contact.name]);
    if (widget.onOpenDevices != null) {
      widget.onOpenDevices!.call(peer, title);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => DeviceListPage(
          service: service,
          peer: peer,
          title: title,
          embedded: widget.embedded,
        ),
      ),
    );
  }

  void _apply(Contact next) {
    setState(() => _contact = next);
    widget.onChanged?.call(next);
  }

  void _fail(String fallback, NexmemException error) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.message.isEmpty ? fallback : error.message)),
    );
  }

  Future<void> _saveNote() async {
    final String fallback = context.t('备注保存失败');
    final Contact previous = _contact;
    final String remark = _note.text.trim();
    _apply(_contact.copyWith(note: remark));
    FocusScope.of(context).unfocus();
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    try {
      await service.setRemark(_contact.id, remark);
    } on NexmemException catch (error) {
      _apply(previous);
      _note.text = previous.note;
      _fail(fallback, error);
    }
  }

  Future<void> _saveGroup() async {
    final String fallback = context.t('分组保存失败');
    final String raw = _group.text.trim();
    if (raw.runes.length > _maxGroupRunes) {
      _fail(context.t('好友分组名最多 32 字'), const NexmemException('INVALID_ARG', '好友分组名最多 32 字'));
      return;
    }
    final Contact previous = _contact;
    _apply(_contact.copyWith(groupName: raw));
    FocusScope.of(context).unfocus();
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    try {
      await service.setGroup(_contact.id, raw);
    } on NexmemException catch (error) {
      _apply(previous);
      _group.text = previous.groupName;
      _fail(fallback, error);
    }
  }

  Future<void> _toggleBlocked(bool blocked) async {
    final String fallback = context.t('拉黑状态更新失败');
    final Contact previous = _contact;
    _apply(_contact.copyWith(blocked: blocked));
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    try {
      await service.setBlocked(_contact.id, blocked);
    } on NexmemException catch (error) {
      _apply(previous);
      _fail(fallback, error);
    }
  }

  /// 二次确认后删除本机联系人；对端与聊天记录不受影响。
  Future<void> _delete() async {
    final ContactService? service = widget.service;
    if (service == null) {
      return;
    }
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('删除好友')),
        content: Text(
          context.t('仅从本机通讯录移除 {0}，不会删除聊天记录，也不会通知对方。确定继续？', <String>[_contact.name]),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirm != true) {
      return;
    }
    try {
      await service.remove(_contact.id);
      if (!mounted) {
        return;
      }
      widget.onDeleted?.call(_contact);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('已删除好友 {0}', <String>[_contact.name]))),
      );
      if (!widget.embedded && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(error.message.isEmpty ? error.code : error.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = _buildBody(context);
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader(title: context.t('好友资料')),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.t('好友资料'))),
      body: body,
    );
  }

  Widget _buildBody(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color base = NexmemColors
        .avatarPalette[_contact.id.hashCode.abs() % NexmemColors.avatarPalette.length];
    final String initial =
        _contact.name.isEmpty ? '?' : _contact.name.substring(0, 1);
    final String title = _contact.note.isEmpty ? _contact.name : _contact.note;

    return ListView(
        padding: const EdgeInsets.all(NexmemMetrics.space16),
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 28,
                backgroundColor: base.withValues(alpha: 0.16),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: base,
                  ),
                ),
              ),
              const SizedBox(width: NexmemMetrics.space16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if (_contact.note.isNotEmpty)
                      Text(
                        _contact.name,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface.withValues(alpha: 0.5),
                            ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: NexmemMetrics.space24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.t('账号')),
            subtitle: Text(
              _contact.id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: context.t('复制账号'),
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _contact.id));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.t('账号已复制'))),
                );
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NexmemMetrics.space12),
            child: TextField(
              key: const ValueKey<String>('contact-remark-field'),
              controller: _note,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: context.t('备注'),
                helperText: context.t('仅本机可见，不会发送给对方'),
                border: const OutlineInputBorder(),
              suffixIcon: TextButton(
                key: const ValueKey<String>('contact-note-save'),
                onPressed: _saveNote,
                child: Text(context.t('保存')),
              ),
              ),
              onSubmitted: (_) => _saveNote(),
            ),
          ),
          TextField(
            key: const ValueKey<String>('contact-group-field'),
            controller: _group,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.t('分组'),
              helperText: context.t('仅本机可见，留空表示不分组'),
              border: const OutlineInputBorder(),
              suffixIcon: TextButton(
                key: const ValueKey<String>('contact-group-save'),
                onPressed: _groupOverLimit ? null : _saveGroup,
                child: Text(context.t('保存')),
              ),
            ),
            onSubmitted: (_) => _saveGroup(),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Text(
              '${_group.text.runes.length}/$_maxGroupRunes',
              key: const ValueKey<String>('contact-group-counter'),
              style: TextStyle(
                fontSize: 12,
                color: _groupOverLimit
                    ? NexmemColors.danger
                    : scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          SwitchListTile(
            key: const ValueKey<String>('contact-block-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(context.t('拉黑')),
            subtitle: Text(context.t('拉黑后双方均无法发送消息')),
            value: _contact.blocked,
            onChanged: _toggleBlocked,
          ),
          if (_contact.blocked)
            Container(
              margin: const EdgeInsets.only(top: NexmemMetrics.space8),
              padding: const EdgeInsets.all(NexmemMetrics.space12),
              decoration: BoxDecoration(
                color: NexmemColors.danger.withValues(alpha: 0.08),
                borderRadius:
                    BorderRadius.circular(NexmemMetrics.radiusListItem),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.block, size: 18, color: NexmemColors.danger),
                  const SizedBox(width: NexmemMetrics.space8),
                  Expanded(
                    child: Text(
                      context.t('已拉黑，双方无法互发消息'),
                      style: TextStyle(
                        fontSize: 13,
                        color: NexmemColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (widget.service != null) ...<Widget>[
            const Divider(),
            ListTile(
              key: const ValueKey<String>('contact-devices-tile'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices_outlined, size: 20),
              title: Text(_devicesTitle()),
              subtitle: Text(
                _devicesSummary(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
              ),
              trailing: _devicesLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right, size: 20),
              onTap: _openDevices,
            ),
          ],
          const SizedBox(height: NexmemMetrics.space24),
          FilledButton(
            key: const ValueKey<String>('contact-send-button'),
            onPressed: _contact.blocked ? null : widget.onSendMessage,
            child: Text(context.t('发消息')),
          ),
          if (widget.onStartRemote != null) ...<Widget>[
            const SizedBox(height: NexmemMetrics.space12),
            OutlinedButton.icon(
              key: const ValueKey<String>('contact-remote-button'),
              onPressed: _contact.blocked ? null : widget.onStartRemote,
              icon: const Icon(Icons.desktop_windows_outlined, size: 18),
              label: Text(context.t('远程控制')),
            ),
          ],
          if (widget.service != null) ...<Widget>[
            const SizedBox(height: NexmemMetrics.space12),
            Center(
              child: TextButton.icon(
                key: const ValueKey<String>('contact-delete-button'),
                onPressed: _delete,
                icon: const Icon(Icons.person_remove_outlined, size: 18),
                label: Text(context.t('删除好友')),
                style: TextButton.styleFrom(foregroundColor: NexmemColors.danger),
              ),
            ),
          ],
        ],
    );
  }
}
