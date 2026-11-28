// 远程控制设置：被控开关、授权能力、空闲超时、平台权限体检与审计。
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import 'input/desktop_input_injector.dart';
import 'remote_audit.dart';
import 'remote_control_service.dart';
import 'remote_password.dart';
import 'remote_password_dialog.dart';
import 'remote_prefs.dart';
import 'remote_session.dart';
import 'remote_storage.dart';

class RemoteSettingsPage extends StatefulWidget {
  const RemoteSettingsPage({
    super.key,
    this.embedded = true,
    this.injectorFactory,
    this.storageFactory,
  });

  final bool embedded;

  /// 测试可注入假的注入器；生产环境为 null，按平台创建真实实现。
  final DesktopInputInjector Function()? injectorFactory;

  /// 测试可注入内存存储；生产环境为 null，按平台创建真实存储。
  final RemoteStorage Function()? storageFactory;

  @override
  State<RemoteSettingsPage> createState() => _RemoteSettingsPageState();
}

class _RemoteSettingsPageState extends State<RemoteSettingsPage> {
  final RemotePrefs _prefs = RemotePrefs.instance;
  late final RemoteStorage _storage =
      (widget.storageFactory ?? createRemoteStorage)();
  late final RemoteAudit _audit = RemoteAudit(_storage);
  late final DesktopInputInjector _injector =
      (widget.injectorFactory ?? createDesktopInputInjector)();
  InputPermissionStatus _status = InputPermissionStatus.unknown;
  bool _ready = false;
  bool _checking = false;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _prefs.load(_storage);
    await _audit.load();
    final InputPermissionStatus status = await _injector.checkPermissions();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = status;
      _ready = true;
    });
  }

  Future<void> _save() async {
    await _prefs.save(_storage);
    if (mounted) {
      setState(() {});
    }
  }

  /// 开启被控前必须先有密码；已有密码则需要重新输入才能开启。
  Future<void> _toggleEnabled(bool value) async {
    if (!value) {
      _prefs.enabled = false;
      await _save();
      // 关闭只影响静默远控：立即断开进行中的静默会话，
      // 聊天框发起、需同意的远控不受影响。
      _prefs.onSilentRemoteDisabled?.call();
      return;
    }
    final bool firstTime = _prefs.passwordCredential.isEmpty;
    final String title = context.t(firstTime ? '设置远程控制密码' : '输入远程控制密码');
    final String label = context.t('开启远程控制');
    final String message = context.t(
      firstTime
          ? '开启被远程控制前必须设置密码；只保存校验值，不保存明文。'
          : '请输入已设置的远程控制密码以确认开启。',
    );
    final String? password = await showRemotePasswordDialog(
      context: context,
      title: title,
      confirmLabel: label,
      message: message,
      expectedCredential: firstTime ? null : _prefs.passwordCredential,
    );
    if (password == null || !mounted) {
      return;
    }
    if (firstTime) {
      _prefs.passwordCredential = remotePasswordCredential(password);
    }
    _prefs.enabled = true;
    await _save();
  }

  Future<void> _changePassword() async {
    final bool hasPassword = _prefs.passwordCredential.isNotEmpty;
    if (hasPassword) {
      final String? verified = await showRemotePasswordDialog(
        context: context,
        title: context.t('输入当前远程控制密码'),
        confirmLabel: context.t('下一步'),
        expectedCredential: _prefs.passwordCredential,
      );
      if (verified == null || !mounted) {
        return;
      }
    }
    final String title = context.t(
      hasPassword ? '设置新的远程控制密码' : '设置远程控制密码',
    );
    final String confirmLabel = context.t('保存');
    final String message = context.t(
      '只保存校验值，不保存明文；已有台账密码需要同步修改。',
    );
    final String updatedLabel = context.t('远程控制密码已更新');
    final String? next = await showRemotePasswordDialog(
      context: context,
      title: title,
      confirmLabel: confirmLabel,
      message: message,
    );
    if (next == null || !mounted) {
      return;
    }
    _prefs.passwordCredential = remotePasswordCredential(next);
    await _save();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(updatedLabel)),
    );
  }

  /// 权限文案在 await 前取好，避免跨异步间隔使用 BuildContext。
  Map<InputPermissionStatus, String> _statusLabels() =>
      <InputPermissionStatus, String>{
        for (final InputPermissionStatus status in InputPermissionStatus.values)
          status: context.t(status.label),
      };

  /// 点击「检查权限」：即使状态没变也要给出 SnackBar 反馈，
  /// 否则不支持注入的平台上按钮看起来像「点了没反应」。
  Future<void> _checkPermissions() async {
    if (_checking) {
      return;
    }
    final String donePrefix = context.t('权限检查完成');
    final Map<InputPermissionStatus, String> labels = _statusLabels();
    setState(() => _checking = true);
    final InputPermissionStatus status = await _injector.checkPermissions();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = status;
      _checking = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$donePrefix：${labels[status]}')),
    );
  }

  /// 点击「前往授权」：同样给出明确结果反馈。
  Future<void> _requestPermissions() async {
    if (_requesting) {
      return;
    }
    final String donePrefix = context.t('授权请求已处理');
    final Map<InputPermissionStatus, String> labels = _statusLabels();
    setState(() => _requesting = true);
    final InputPermissionStatus status = await _injector.requestPermissions();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = status;
      _requesting = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$donePrefix：${labels[status]}')),
    );
  }

  @override
  void dispose() {
    unawaited(_injector.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      // 不写死宽度：本页在手机端以全屏设置页打开，固定 440 会横向溢出。
      return const Center(child: CircularProgressIndicator());
    }
    final ThemeData theme = Theme.of(context);
    final bool hostSupported = RemoteControlService.hostSupported;
    final Widget content = ListView(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      children: <Widget>[
          Text(
            context.t('聊天发起的远控需要你确认；已保存的远程设备凭密码可静默控制。'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          if (!hostSupported)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.t('当前平台仅支持作为控制端；被控端请使用桌面版或 Android 手机/平板。'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey<String>('remote-enabled'),
            contentPadding: EdgeInsets.zero,
            value: _prefs.enabled,
            onChanged: hostSupported
                ? (bool value) => unawaited(_toggleEnabled(value))
                : null,
            title: Text(context.t('允许被远程控制')),
            subtitle: Text(context.t('开启前必须设置密码；关闭只断开密码静默远控，聊天里发起的远控不受影响')),
          ),
          ListTile(
            key: const ValueKey<String>('remote-password-change'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_outline),
            title: Text(context.t('远程控制密码')),
            subtitle: Text(
              context.t(_prefs.passwordCredential.isEmpty
                  ? '未设置，无法开启被远程控制'
                  : '已设置（仅保存校验值）'),
            ),
            trailing: TextButton(
              onPressed: hostSupported ? () => unawaited(_changePassword()) : null,
              child: Text(context.t(_prefs.passwordCredential.isEmpty
                  ? '设置'
                  : '修改')),
            ),
          ),
          const Divider(),
          Text(
            context.t('默认授权能力'),
            style: theme.textTheme.titleSmall,
          ),
          SwitchListTile(
            key: const ValueKey<String>('remote-allow-input'),
            contentPadding: EdgeInsets.zero,
            value: _prefs.allowInput,
            onChanged: (bool value) {
              _prefs.allowInput = value;
              _save();
            },
            title: Text(context.t(RemotePermission.input.label)),
          ),
          SwitchListTile(
            key: const ValueKey<String>('remote-allow-clipboard'),
            contentPadding: EdgeInsets.zero,
            value: _prefs.allowClipboard,
            onChanged: (bool value) {
              _prefs.allowClipboard = value;
              _save();
            },
            title: Text(context.t(RemotePermission.clipboard.label)),
          ),
          SwitchListTile(
            key: const ValueKey<String>('remote-allow-file'),
            contentPadding: EdgeInsets.zero,
            value: _prefs.allowFile,
            onChanged: (bool value) {
              _prefs.allowFile = value;
              _save();
            },
            title: Text(context.t(RemotePermission.file.label)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.t('空闲自动断开')),
            trailing: DropdownButton<int>(
              value: _prefs.idleMinutes,
              items: <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 5, child: Text(context.t('5 分钟'))),
                DropdownMenuItem<int>(value: 15, child: Text(context.t('15 分钟'))),
                DropdownMenuItem<int>(value: 30, child: Text(context.t('30 分钟'))),
                DropdownMenuItem<int>(value: 60, child: Text(context.t('60 分钟'))),
              ],
              onChanged: (int? value) {
                if (value == null) {
                  return;
                }
                _prefs.idleMinutes = value;
                _save();
              },
            ),
          ),
          const Divider(),
          Text(
            context.t('本机权限'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '${context.t('状态')}：${context.t(_status.label)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            context.t(_injector.permissionHint),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              OutlinedButton(
                key: const ValueKey<String>('remote-check-permission'),
                onPressed: _checking ? null : _checkPermissions,
                child: _checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.t('检查权限')),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const ValueKey<String>('remote-request-permission'),
                onPressed: _requesting ? null : _requestPermissions,
                child: _requesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.t('前往授权')),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.t('macOS 需授予屏幕录制与辅助功能权限；Android 需开启无障碍服务；Linux Wayland 仅支持查看。'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const Divider(),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  context.t('最近会话'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              TextButton(
                key: const ValueKey<String>('remote-audit-clear'),
                onPressed: () async {
                  await _audit.clear();
                  if (mounted) {
                    setState(() {});
                  }
                },
                child: Text(context.t('清空')),
              ),
            ],
          ),
          if (_audit.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.t('暂无记录'),
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            for (final RemoteAuditEntry entry
                in _audit.entries.reversed.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  entry.direction == 'host'
                      ? Icons.download
                      : Icons.upload,
                  size: 18,
                ),
                title: Text(
                  '${entry.direction == 'host' ? context.t('被控') : context.t('控制')}'
                  ' · ${entry.action}'
                  ' · ${entry.permissions.set.map((RemotePermission p) => p.label).join('/')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                subtitle: Text(
                  '${_formatTime(entry.timeMs)}'
                  '${entry.durationMs > 0 ? ' · ${(entry.durationMs / 1000).round()}s' : ''}'
                  '${entry.reason.isEmpty ? '' : ' · ${entry.reason}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
          const SizedBox(height: 12),
          Text(
            context.t('提示：macOS 关闭 App Sandbox 后才能控制其他应用；应用最小化时顶部提示不可见。'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
      ],
    );
    if (widget.embedded) {
      // 与设备列表、文件共享等页面一致：顶部标题栏 + 带内边距的列表。
      // 外层 EmbeddedSettingsPane 是透明、铺满的 Dialog，这里用不透明
      // 底色收住，避免底层列表透出；标题改由 PaneHeader 提供。
      return Material(
        color: theme.colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PaneHeader(title: context.t('远程控制')),
            Expanded(child: content),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460, maxHeight: 540),
      child: content,
    );
  }

  static String _formatTime(int ms) {
    if (ms <= 0) {
      return '-';
    }
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}
