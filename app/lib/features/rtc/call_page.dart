// P6-28：音视频通话界面（来电 / 呼叫中 / 通话中）。
//
// 全屏页面，由壳层在收到 rtc.signal 或用户点击通话入口时压入。
// UI 只依赖 CallInfo 快照与回调，媒体渲染视图由工厂注入，便于无插件 widget 测试。

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import 'call_service.dart';

/// 通话页。
class CallPage extends StatelessWidget {
  const CallPage({
    super.key,
    required this.info,
    required this.peerName,
    required this.onAccept,
    required this.onReject,
    required this.onHangup,
    required this.onToggleMute,
    this.remoteViewBuilder,
  });

  final CallInfo info;
  final String peerName;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onHangup;
  final VoidCallback onToggleMute;

  /// 远端视频视图构造器；为空时用占位图标（纯测试/语音通话）。
  final WidgetBuilder? remoteViewBuilder;

  bool get _incoming => info.state == CallState.incoming;
  bool get _active =>
      info.state == CallState.connected || info.state == CallState.outgoing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF101114),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: <Widget>[
                  Icon(Icons.call, color: scheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    context.t(info.video ? '视频通话' : '语音通话'),
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: scheme.primary.withValues(alpha: 0.25),
                      child: Icon(Icons.person, size: 48, color: scheme.primary),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      peerName.isEmpty ? info.peer : peerName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _statusLabel(context, info.state),
                      key: const ValueKey<String>('call-status'),
                      style: const TextStyle(color: Colors.white60, fontSize: 14),
                    ),
                    if (info.video && remoteViewBuilder != null)
                      SizedBox(
                        height: 160,
                        child: remoteViewBuilder!(context),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  if (_incoming) ...<Widget>[
                    _RoundAction(
                      key: const ValueKey<String>('call-reject'),
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: context.t('拒绝'),
                      onPressed: onReject,
                    ),
                    _RoundAction(
                      key: const ValueKey<String>('call-accept'),
                      icon: Icons.call,
                      color: const Color(0xFF2BB673),
                      label: context.t('接听'),
                      onPressed: onAccept,
                    ),
                  ],
                  if (_active) ...<Widget>[
                    _RoundAction(
                      key: const ValueKey<String>('call-mute'),
                      icon: info.muted ? Icons.mic_off : Icons.mic,
                      color: info.muted ? Colors.grey : scheme.primary,
                      label: context.t(info.muted ? '取消静音' : '静音'),
                      onPressed: onToggleMute,
                    ),
                    _RoundAction(
                      key: const ValueKey<String>('call-hangup'),
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: context.t('挂断'),
                      onPressed: onHangup,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(BuildContext context, CallState state) =>
      switch (state) {
        CallState.incoming => context.t('来电，是否接听？'),
        CallState.outgoing => context.t('正在呼叫…'),
        CallState.connected => context.t('通话中'),
        CallState.ended => context.t('已结束'),
        CallState.idle => '',
      };
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        CircleAvatar(
          radius: 30,
          backgroundColor: color,
          child: IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
