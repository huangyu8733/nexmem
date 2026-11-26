// 远程控制设置：被控开关、授权能力、空闲超时、平台权限体检与审计。
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 'input/desktop_input_injector.dart';
import 'remote_audit.dart';
import 'remote_control_service.dart';
import 'remote_prefs.dart';
import 'remote_session.dart';
import 'remote_storage.dart';

class RemoteSettingsPage extends StatefulWidget {
  const RemoteSettingsPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<RemoteSettingsPage> createState() => _RemoteSettingsPageState();
}

class _RemoteSettingsPageState extends State<RemoteSettingsPage> {
  final RemotePrefs _prefs = RemotePrefs.instance;
  late final RemoteStorage _storage = createRemoteStorage();
  late final RemoteAudit _audit = RemoteAudit(_storage);
  late final DesktopInputInjector _injector = createDesktopInputInjector();
  InputPermissionStatus _status = InputPermissionStatus.unknown;
  bool _ready = false;

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

  @override
  void dispose() {
    unawaited(_injector.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox(
        width: 440,
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final ThemeData theme = Theme.of(context);
    final bool hostSupported = RemoteControlService.hostSupported;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460, maxHeight: 540),
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          Text(
            context.t('远程控制'),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.t('允许联系人查看并操作本机屏幕；所有会话都需要你确认。'),
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
                ? (bool value) {
                    _prefs.enabled = value;
                    _save();
                  }
                : null,
            title: Text(context.t('允许被远程控制')),
            subtitle: Text(context.t('关闭后拒绝所有远控请求')),
          ),
          SwitchListTile(
            key: const ValueKey<String>('remote-confirm'),
            contentPadding: EdgeInsets.zero,
            value: _prefs.requireConfirm,
            onChanged: _prefs.enabled
                ? (bool value) {
                    _prefs.requireConfirm = value;
                    _save();
                  }
                : null,
            title: Text(context.t('每次请求都需要确认')),
            subtitle: Text(context.t('关闭后按下方授权能力自动接受')),
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
              items: const <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 5, child: Text('5 分钟')),
                DropdownMenuItem<int>(value: 15, child: Text('15 分钟')),
                DropdownMenuItem<int>(value: 30, child: Text('30 分钟')),
                DropdownMenuItem<int>(value: 60, child: Text('60 分钟')),
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
            _injector.permissionHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              OutlinedButton(
                key: const ValueKey<String>('remote-check-permission'),
                onPressed: () async {
                  final InputPermissionStatus status =
                      await _injector.checkPermissions();
                  if (mounted) {
                    setState(() => _status = status);
                  }
                },
                child: Text(context.t('检查权限')),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const ValueKey<String>('remote-request-permission'),
                onPressed: () async {
                  final InputPermissionStatus status =
                      await _injector.requestPermissions();
                  if (mounted) {
                    setState(() => _status = status);
                  }
                },
                child: Text(context.t('前往授权')),
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
      ),
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
