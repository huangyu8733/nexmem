// 权限管理面板：查看摄像头 / 麦克风 / 通知权限状态，主动申请或跳系统设置。
//
// 不在这里读取系统定位、不申请存储权限：位置由用户手填，文件由系统选择器授权。
// 原生宿主未接线时显示「不支持」，不影响其余功能。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import 'app_permissions.dart';

class PermissionsPane extends StatefulWidget {
  const PermissionsPane({
    super.key,
    this.permissions,
    this.showHeader = true,
  });

  /// 可注入假实现用于测试；为空时按当前平台自动选择。
  final AppPermissions? permissions;
  final bool showHeader;

  @override
  State<PermissionsPane> createState() => _PermissionsPaneState();
}

class _PermissionsPaneState extends State<PermissionsPane> {
  late final AppPermissions _permissions =
      widget.permissions ?? makeAppPermissions();
  final Map<AppPermissionKind, AppPermissionState> _states =
      <AppPermissionKind, AppPermissionState>{
    for (final AppPermissionKind kind in AppPermissionKind.values)
      kind: AppPermissionState.prompt,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    for (final AppPermissionKind kind in AppPermissionKind.values) {
      final AppPermissionState state = await _permissions.status(kind);
      if (!mounted) {
        return;
      }
      setState(() => _states[kind] = state);
    }
  }

  String _stateLabel(BuildContext context, AppPermissionState state) => switch (state) {
        AppPermissionState.granted => context.t('已授权'),
        AppPermissionState.denied => context.t('已拒绝'),
        AppPermissionState.prompt => context.t('未申请'),
        AppPermissionState.permanentlyDenied => context.t('永久拒绝'),
        AppPermissionState.unsupported => context.t('该平台不支持申请权限'),
      };

  IconData _iconOf(AppPermissionKind kind) => switch (kind) {
        AppPermissionKind.camera => Icons.qr_code_scanner,
        AppPermissionKind.microphone => Icons.mic_none,
        AppPermissionKind.notifications => Icons.notifications_none,
      };

  String _titleOf(BuildContext context, AppPermissionKind kind) => switch (kind) {
        AppPermissionKind.camera => context.t('摄像头'),
        AppPermissionKind.microphone => context.t('麦克风'),
        AppPermissionKind.notifications => context.t('通知'),
      };

  String _descriptionOf(BuildContext context, AppPermissionKind kind) => switch (kind) {
        AppPermissionKind.camera => context.t('扫码与视频通话'),
        AppPermissionKind.microphone => context.t('语音与视频通话'),
        AppPermissionKind.notifications => context.t('离线消息提醒'),
      };

  Future<void> _request(AppPermissionKind kind) async {
    final AppPermissionState state = await _permissions.request(kind);
    if (!mounted) {
      return;
    }
    setState(() => _states[kind] = state);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('权限状态：{0}', [_stateLabel(context, state)]))),
      );
    }
  }

  Future<void> _openSettings(AppPermissionKind kind) async {
    final bool opened = await _permissions.openSettings(kind);
    if (!mounted || !context.mounted) {
      return;
    }
    if (!opened) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(context.t('无法打开系统设置，请到系统设置中手动开启')),
        ),
      );
    }
    unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      children: <Widget>[
        if (widget.showHeader)
          Padding(
            padding: const EdgeInsets.only(bottom: NexmemMetrics.space12),
            child: Text(
              context.t('权限管理'),
              style: theme.textTheme.titleLarge,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: NexmemMetrics.space12),
          child: Text(
            context.t('这些权限用于扫码、语音/视频通话、系统通知；本机位置仅在您主动设置时通过系统定位获取，文件由系统选择器授权。'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        Card(
          child: Column(
            children: <Widget>[
              for (final AppPermissionKind kind in AppPermissionKind.values)
                ListTile(
                  key: ValueKey<String>('permission-${kind.wire}'),
                  leading: Icon(_iconOf(kind), size: 22),
                  title: Text(_titleOf(context, kind)),
                  subtitle: Text(
                    '${_descriptionOf(context, kind)} · ${_stateLabel(context, _states[kind]!)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_states[kind]!.canRequest)
                        TextButton(
                          key: ValueKey<String>('permission-request-${kind.wire}'),
                          onPressed: () => unawaited(_request(kind)),
                          child: Text(context.t('申请权限')),
                        ),
                      if (_states[kind] == AppPermissionState.denied ||
                          _states[kind] == AppPermissionState.permanentlyDenied)
                        TextButton(
                          key: ValueKey<String>('permission-settings-${kind.wire}'),
                          onPressed: () => unawaited(_openSettings(kind)),
                          child: Text(context.t('打开系统设置')),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
