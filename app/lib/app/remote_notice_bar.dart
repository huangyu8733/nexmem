import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../features/remote/remote_session.dart';
import '../l10n/l10n.dart';
import 'theme.dart';
import 'app_toast_speaker_native.dart'
    if (dart.library.js_interop) 'app_toast_speaker_web.dart' as speaker;

/// 远程控制通知条：固定在「在线」状态条下方，与音视频通话通知条一致。
///
/// 被控来电不再直接抢占屏幕，而是先给一条可点的通知：
/// 来电期间播报 + 系统提示音 + 震动，点击展开全屏授权框，可直接在条上拒绝。
/// 被控进行中则显示控制状态，并提供暂停/继续与断开操作。
class RemoteNoticeBar extends StatefulWidget {
  const RemoteNoticeBar({
    super.key,
    required this.info,
    required this.peerName,
    required this.onOpen,
    this.onReject,
    this.onPause,
    this.onResume,
    this.onStop,
    this.ringing = true,
  });

  final RemoteInfo info;
  final String peerName;
  final VoidCallback onOpen;
  final VoidCallback? onReject;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onStop;

  /// 来电且授权框尚未展开时才响铃/播报，避免与授权框提示重复。
  final bool ringing;

  @override
  State<RemoteNoticeBar> createState() => _RemoteNoticeBarState();
}

class _RemoteNoticeBarState extends State<RemoteNoticeBar> {
  Timer? _ring;
  String? _spokenSid;

  @override
  void initState() {
    super.initState();
    _syncRinging();
  }

  @override
  void didUpdateWidget(RemoteNoticeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info.state != widget.info.state ||
        oldWidget.info.sid != widget.info.sid ||
        oldWidget.ringing != widget.ringing) {
      _syncRinging();
    }
  }

  @override
  void dispose() {
    _ring?.cancel();
    super.dispose();
  }

  void _syncRinging() {
    final bool ringing = widget.info.isIncoming && widget.ringing;
    if (!ringing) {
      _ring?.cancel();
      _ring = null;
      return;
    }
    if (_spokenSid != widget.info.sid) {
      final String sid = widget.info.sid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _spokenSid == sid || !widget.ringing) {
          return;
        }
        _spokenSid = sid;
        speaker.speakNotice(
          '${widget.peerName} ${context.t('远程控制')} ${context.t('来电')}',
        );
        _alert();
      });
    }
    _ring ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !widget.info.isIncoming || !widget.ringing) {
        return;
      }
      _alert();
    });
  }

  void _alert() {
    unawaited(
      SystemSound.play(SystemSoundType.alert).catchError((Object _) {}),
    );
    unawaited(
      HapticFeedback.vibrate().catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final RemoteInfo info = widget.info;
    final String stateLabel = switch (info.state) {
      RemoteState.idle => '',
      RemoteState.incoming => context.t('来电'),
      RemoteState.outgoing => context.t('正在请求…'),
      RemoteState.connecting => context.t('正在连接…'),
      RemoteState.active => context.t('远程控制中'),
      RemoteState.paused => context.t('已暂停'),
      RemoteState.reconnecting => context.t('重连中'),
      RemoteState.ended || RemoteState.failed => '',
    };
    final String name = widget.peerName.trim();
    final String title = name.isEmpty
        ? '${context.t('远程控制')} · $stateLabel'
        : '$name · ${context.t('远程控制')} · $stateLabel';
    final String hint = info.isIncoming
        ? context.t('点击打开远程控制授权界面')
        : context.t('点击管理远程控制');

    // 与通话通知条一致：使用不透明实色，避免透出下方聊天内容。
    final Color background = scheme.primaryContainer;
    final Color foreground = scheme.onPrimaryContainer;
    return Material(
      key: const ValueKey<String>('remote-notice-bar'),
      color: background,
      child: InkWell(
        onTap: widget.onOpen,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                info.isIncoming
                    ? Icons.desktop_windows_outlined
                    : Icons.screen_share_outlined,
                size: 18,
                color: foreground,
              ),
              const SizedBox(width: NexmemMetrics.space8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    Text(
                      hint,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.82),
                          ),
                    ),
                  ],
                ),
              ),
              if (info.isIncoming && widget.onReject != null)
                TextButton(
                  key: const ValueKey<String>('remote-notice-reject'),
                  onPressed: widget.onReject,
                  style: TextButton.styleFrom(foregroundColor: foreground),
                  child: Text(context.t('拒绝')),
                ),
              if (!info.isIncoming && !info.isTerminal) ...<Widget>[
                if (widget.onPause != null &&
                    (info.state == RemoteState.active ||
                        info.state == RemoteState.paused))
                  TextButton(
                    key: const ValueKey<String>('remote-notice-pause'),
                    onPressed: info.state == RemoteState.paused
                        ? widget.onResume
                        : widget.onPause,
                    style: TextButton.styleFrom(foregroundColor: foreground),
                    child: Text(
                      context.t(
                        info.state == RemoteState.paused ? '继续' : '暂停',
                      ),
                    ),
                  ),
                if (widget.onStop != null)
                  TextButton(
                    key: const ValueKey<String>('remote-notice-stop'),
                    onPressed: widget.onStop,
                    style: TextButton.styleFrom(foregroundColor: foreground),
                    child: Text(context.t('断开')),
                  ),
              ],
              Icon(
                Icons.chevron_right,
                size: 18,
                color: foreground.withValues(alpha: 0.75),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
