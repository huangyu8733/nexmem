// P6-28：音视频通话界面（来电 / 呼叫中 / 通话中）。
//
// 全屏页面，由壳层在收到 rtc.signal 或用户点击通话入口时压入。
// UI 只依赖 CallInfo 快照与回调，媒体渲染视图由工厂注入，便于无插件 widget 测试。
// 群聊时按 participants 渲染成员网格；视频视图由 videoViewBuilder 提供。

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
    this.videoViewBuilder,
    this.onToggleCamera,
    this.onSwitchCamera,
    this.cameraEnabled = true,
  });

  final CallInfo info;
  final String peerName;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onHangup;
  final VoidCallback onToggleMute;

  /// 远端视频视图构造器（旧 API，保留兼容）；为空时用占位图标。
  final WidgetBuilder? remoteViewBuilder;

  /// 按成员构造视频视图；[local] 为 true 时构造本地预览。
  final Widget Function(String peer, {bool local})? videoViewBuilder;

  /// 摄像头开关与前后摄切换（仅视频通话显示）。
  final VoidCallback? onToggleCamera;
  final VoidCallback? onSwitchCamera;
  final bool cameraEnabled;

  bool get _incoming => info.state == CallState.incoming;
  bool get _active =>
      info.state == CallState.connected || info.state == CallState.outgoing;

  bool get _groupGrid => info.isGroup && info.participants.length > 1;

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
                  if (info.isGroup) ...<Widget>[
                    const SizedBox(width: 12),
                    Text(
                      context.t('${info.participants.length} 人'),
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _groupGrid
                  ? _buildGroupGrid(context, scheme)
                  : _buildSingle(context, scheme),
            ),
            if (info.video && videoViewBuilder != null && _active)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: 120,
                  height: 90,
                  child: videoViewBuilder!(
                    info.peer,
                    local: true,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 28,
                runSpacing: 16,
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
                    if (info.video && onToggleCamera != null)
                      _RoundAction(
                        key: const ValueKey<String>('call-camera'),
                        icon: cameraEnabled
                            ? Icons.videocam
                            : Icons.videocam_off,
                        color: cameraEnabled ? scheme.primary : Colors.grey,
                        label: context.t(cameraEnabled ? '关闭摄像头' : '开启摄像头'),
                        onPressed: onToggleCamera!,
                      ),
                    if (info.video && onSwitchCamera != null)
                      _RoundAction(
                        key: const ValueKey<String>('call-switch-camera'),
                        icon: Icons.switch_camera,
                        color: scheme.primary,
                        label: context.t('切换摄像头'),
                        onPressed: onSwitchCamera!,
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

  Widget _buildGroupGrid(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
        children: <Widget>[
          for (final CallParticipant participant in info.participants)
            _ParticipantTile(
              participant: participant,
              view: info.video && videoViewBuilder != null
                  ? videoViewBuilder!(participant.peer, local: false)
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _buildSingle(BuildContext context, ColorScheme scheme) {
    final Widget? remoteView = info.video
        ? videoViewBuilder?.call(info.peer, local: false) ??
            (remoteViewBuilder != null ? remoteViewBuilder!(context) : null)
        : null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (remoteView != null)
            SizedBox(
              width: 260,
              height: 200,
              child: remoteView,
            )
          else
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
        ],
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

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, required this.view});

  final CallParticipant participant;
  final Widget? view;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.bottomLeft,
        children: <Widget>[
          Positioned.fill(
            child: view ??
                Center(
                  child: Icon(Icons.person, color: Colors.white54, size: 40),
                ),
          ),
          Container(
            width: double.infinity,
            color: const Color(0x99000000),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: <Widget>[
                Icon(
                  participant.muted ? Icons.mic_off : Icons.mic,
                  color: participant.muted ? Colors.red : Colors.white70,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    participant.peer.length > 10
                        ? '${participant.peer.substring(0, 10)}…'
                        : participant.peer,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
                if (participant.connected)
                  const Icon(Icons.check, color: Colors.green, size: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
