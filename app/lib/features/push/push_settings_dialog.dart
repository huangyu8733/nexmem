// 消息通知设置面板：开关、权限状态、平台能力与凭证说明。
//
// 凭证由二次开发者在原生宿主 / 部署环境提供；界面只显示当前能力状态，
// 不要求用户填写任何密钥。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import 'push_controller.dart';
import 'push_platform.dart';

/// 消息通知设置面板，可在右栏内嵌或作为对话框打开。
class PushSettingsPane extends StatefulWidget {
  const PushSettingsPane({
    super.key,
    required this.controller,
    this.showHeader = true,
  });

  final PushController controller;
  final bool showHeader;

  @override
  State<PushSettingsPane> createState() => _PushSettingsPaneState();
}

class _PushSettingsPaneState extends State<PushSettingsPane> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final PushController push = widget.controller;
    final ThemeData theme = Theme.of(context);
    final String capabilityLabel = switch (push.capability) {
      PushCapability.system => context.t('系统推送'),
      PushCapability.browser => context.t('浏览器通知'),
      _ => context.t('当前平台不支持'),
    };
    return ListView(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      children: <Widget>[
        if (widget.showHeader)
          Padding(
            padding: const EdgeInsets.only(bottom: NexmemMetrics.space12),
            child: Text(
              context.t('消息通知'),
              style: theme.textTheme.titleLarge,
            ),
          ),
        Card(
          child: Column(
            children: <Widget>[
              SwitchListTile(
                key: const ValueKey<String>('push-enabled'),
                title: Text(context.t('系统消息通知')),
                subtitle: Text(
                  '${context.t('通知通道')}：$capabilityLabel',
                ),
                value: push.enabled,
                onChanged: push.canEnable
                    ? (bool value) => unawaited(push.setEnabled(value))
                    : null,
              ),
              const Divider(height: 1),
              ListTile(
                title: Text(context.t('权限状态')),
                subtitle: Text(_permissionLabel(context, push.permission.raw)),
                trailing: push.supported && !push.permission.granted
                    ? TextButton(
                        key: const ValueKey<String>('push-permission'),
                        onPressed: () => unawaited(push.refresh()),
                        child: Text(context.t('重新申请')),
                      )
                    : null,
              ),
              if (push.initializing)
                const LinearProgressIndicator(minHeight: 2),
            ],
          ),
        ),
        const SizedBox(height: NexmemMetrics.space12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(NexmemMetrics.space16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(context.t('通知说明'), style: theme.textTheme.titleMedium),
                const SizedBox(height: NexmemMetrics.space8),
                Text(
                  context.t(
                    '开启后，离线消息会唤醒设备并在通知栏显示；通知只包含「有新消息」提示，'
                    '不携带正文、发送者或会话内容，收到后由设备自行拉取密文。'
                    '桌面端没有系统通知通道，请保持应用开启。',
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: NexmemMetrics.space8),
                Text(
                  context.t(
                    'Android / iOS 需要在宿主工程中配置 FCM / APNs 凭证；'
                    'Web 端浏览器通知无需凭证，后台唤醒需部署者提供 VAPID 公钥。',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (push.error != null)
          Padding(
            padding: const EdgeInsets.only(top: NexmemMetrics.space12),
            child: Text(
              context.t('通知设置失败：{0}', [context.t(push.error!)]),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  String _permissionLabel(BuildContext context, String raw) => switch (raw) {
        'granted' => context.t('已授权'),
        'denied' => context.t('通知权限已拒绝'),
        'unsupported' => context.t('当前平台不支持'),
        _ => context.t('待授权'),
      };
}
