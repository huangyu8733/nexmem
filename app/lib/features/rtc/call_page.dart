// P6-28：音视频通话界面（来电 / 呼叫中 / 通话中）。
//
// 全屏页面，由壳层在收到 rtc.signal 或用户点击通话入口时压入。
// 交互对齐 QQ：来电全屏显示对方头像与「接听/拒绝」，视频来电接听按钮
// 明确标注「视频接听」；呼叫中可取消；接通后计时；结束展示结束原因。
// UI 只依赖 CallInfo 快照与回调，媒体渲染视图由工厂注入，便于无插件 widget 测试。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import 'call_service.dart';

/// 通话页。
class CallPage extends StatefulWidget {
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

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  /// 每秒刷新通话时长。
  Timer? _tick;

  /// 来电提示音/振动（每 2s 一次，最多 15 次≈30s）。
  Timer? _ring;
  int _ringCount = 0;

  CallInfo get _info => widget.info;

  bool get _incoming => _info.state == CallState.incoming;
  bool get _outgoing => _info.state == CallState.outgoing;
  bool get _connected => _info.state == CallState.connected;
  bool get _active => _connected || _outgoing;
  bool get _groupGrid => _info.isGroup && _info.participants.length > 1;

  @override
  void initState() {
    super.initState();
    _syncEffects();
  }

  @override
  void didUpdateWidget(CallPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info.state != widget.info.state) {
      _syncEffects();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ring?.cancel();
    super.dispose();
  }

  /// 依据当前状态启停计时器与响铃；不依赖 build，避免每帧重建计时器。
  void _syncEffects() {
    if (_connected) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
    if (_incoming) {
      _ring ??= Timer.periodic(const Duration(seconds: 2), (Timer timer) {
        if (!mounted || !_incoming) {
          timer.cancel();
          return;
        }
        if (_ringCount >= 15) {
          timer.cancel();
          return;
        }
        _ringCount++;
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.vibrate();
      });
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.vibrate();
    } else {
      _ring?.cancel();
      _ring = null;
      _ringCount = 0;
    }
  }

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
                    context.t(_info.video ? '视频通话' : '语音通话'),
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  if (_info.isGroup) ...<Widget>[
                    const SizedBox(width: 12),
                    Text(
                      context.t('${_info.participants.length} 人'),
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
            _buildActions(context, scheme),
          ],
        ),
      ),
    );
  }

  /// 底部操作区：固定贴底，独立于视频视图，保证任何尺寸下按钮可见可点。
  Widget _buildActions(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          if (_incoming) ...<Widget>[
            _RoundAction(
              key: const ValueKey<String>('call-reject'),
              icon: Icons.call_end,
              color: const Color(0xFFE5484D),
              label: context.t('拒绝'),
              size: 36,
              onPressed: widget.onReject,
            ),
            _RoundAction(
              key: const ValueKey<String>('call-accept'),
              icon: _info.video ? Icons.videocam : Icons.call,
              color: const Color(0xFF2BB673),
              label: context.t(_info.video ? '视频接听' : '接听'),
              size: 36,
              onPressed: widget.onAccept,
            ),
          ],
          if (_active) ...<Widget>[
            _RoundAction(
              key: const ValueKey<String>('call-mute'),
              icon: _info.muted ? Icons.mic_off : Icons.mic,
              color: _info.muted ? Colors.grey : scheme.primary,
              label: context.t(_info.muted ? '取消静音' : '静音'),
              onPressed: widget.onToggleMute,
            ),
            if (_info.video && _connected && widget.onToggleCamera != null)
              _RoundAction(
                key: const ValueKey<String>('call-camera'),
                icon: widget.cameraEnabled ? Icons.videocam : Icons.videocam_off,
                color: widget.cameraEnabled ? scheme.primary : Colors.grey,
                label: context.t(widget.cameraEnabled ? '关闭摄像头' : '开启摄像头'),
                onPressed: widget.onToggleCamera!,
              ),
            if (_info.video && _connected && widget.onSwitchCamera != null)
              _RoundAction(
                key: const ValueKey<String>('call-switch-camera'),
                icon: Icons.switch_camera,
                color: scheme.primary,
                label: context.t('切换摄像头'),
                onPressed: widget.onSwitchCamera!,
              ),
            _RoundAction(
              key: const ValueKey<String>('call-hangup'),
              icon: Icons.call_end,
              color: const Color(0xFFE5484D),
              label: context.t(_outgoing ? '取消' : '挂断'),
              onPressed: widget.onHangup,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGroupGrid(BuildContext context, ColorScheme scheme) {
    final Widget Function(String, {bool local})? builder =
        widget.videoViewBuilder;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
        children: <Widget>[
          for (final CallParticipant participant in _info.participants)
            _ParticipantTile(
              participant: participant,
              view: _info.video && builder != null
                  ? builder(participant.peer, local: false)
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _buildSingle(BuildContext context, ColorScheme scheme) {
    final bool showVideo = _info.video && widget.videoViewBuilder != null;
    final Widget? remoteView = showVideo
        ? widget.videoViewBuilder!(_info.peer, local: false)
        : (widget.remoteViewBuilder != null
            ? widget.remoteViewBuilder!(context)
            : null);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (showVideo && _connected)
            // 视频接通后主画面为远端视频，本地预览缩到右上角。
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: remoteView ?? const SizedBox.shrink(),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: SizedBox(
                      width: 96,
                      height: 132,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: widget.videoViewBuilder!(_info.peer, local: true),
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            CircleAvatar(
              radius: _incoming ? 56 : 48,
              backgroundColor: scheme.primary.withValues(alpha: 0.25),
              child: Icon(Icons.person, size: _incoming ? 56 : 48, color: scheme.primary),
            ),
          const SizedBox(height: 20),
          Text(
            widget.peerName.isEmpty ? _info.peer : widget.peerName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _statusLabel(context, _info.state),
            key: const ValueKey<String>('call-status'),
            style: const TextStyle(color: Colors.white60, fontSize: 14),
          ),
          if (_incoming) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              context.t(
                '邀请你进行${_info.video ? '视频' : '语音'}通话',
              ),
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
          if (_connected) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _formatDuration(_info.elapsed),
              key: const ValueKey<String>('call-duration'),
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final String mm = d.inMinutes.toString().padLeft(2, '0');
    final String ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
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
    this.size = 30,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CircleAvatar(
          radius: size,
          backgroundColor: color,
          child: IconButton(
            iconSize: size,
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
