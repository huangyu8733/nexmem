import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../features/rtc/call_service.dart';
import '../l10n/l10n.dart';
import 'theme.dart';
import 'app_toast_speaker_native.dart'
    if (dart.library.js_interop) 'app_toast_speaker_web.dart' as speaker;

/// 音视频通话通知条：固定在「在线」状态条下方，点击展开全屏通话页。
///
/// 来电不再直接抢占屏幕，而是先给一条可点的通知；去电/通话中仍自动进入通话页。
/// 来电期间用系统提示音 + 浏览器语音合成播报，避免用户漏接。
class CallNoticeBar extends StatefulWidget {
  const CallNoticeBar({
    super.key,
    required this.info,
    required this.peerName,
    required this.onOpen,
    this.onReject,
    this.ringing = true,
  });

  final CallInfo info;
  final String peerName;
  final VoidCallback onOpen;
  final VoidCallback? onReject;

  /// 来电且通话页尚未展开时才响铃/播报，避免与通话页重复。
  final bool ringing;

  @override
  State<CallNoticeBar> createState() => _CallNoticeBarState();
}

class _CallNoticeBarState extends State<CallNoticeBar> {
  Timer? _ring;
  String? _spokenCallId;

  @override
  void initState() {
    super.initState();
    _syncRinging();
  }

  @override
  void didUpdateWidget(CallNoticeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info.state != widget.info.state ||
        oldWidget.info.callId != widget.info.callId ||
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
    final CallInfo info = widget.info;
    final bool ringing =
        info.state == CallState.incoming && widget.ringing;
    if (!ringing) {
      _ring?.cancel();
      _ring = null;
      return;
    }
    if (_spokenCallId != info.callId) {
      final String callId = info.callId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _spokenCallId == callId || !widget.ringing) {
          return;
        }
        _spokenCallId = callId;
        final String kind = context.t(info.video ? '视频通话' : '语音通话');
        speaker.speakNotice('${widget.peerName} $kind ${context.t('来电')}');
        _alert();
      });
    }
    _ring ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || widget.info.state != CallState.incoming || !widget.ringing) {
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
    final CallInfo info = widget.info;
    final String kind = context.t(info.video ? '视频通话' : '语音通话');
    final String stateLabel = switch (info.state) {
      CallState.incoming => context.t('来电'),
      CallState.outgoing => context.t('正在呼叫…'),
      CallState.connected => context.t('通话中'),
      CallState.ended => context.t('已结束'),
      CallState.idle => '',
    };
    final String name = widget.peerName.trim();
    final String title = name.isEmpty
        ? '$kind · $stateLabel'
        : '$name · $kind · $stateLabel';

    return Material(
      key: const ValueKey<String>('call-notice-bar'),
      color: scheme.primary.withValues(alpha: 0.10),
      child: InkWell(
        onTap: widget.onOpen,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                info.video ? Icons.videocam_outlined : Icons.call_outlined,
                size: 18,
                color: scheme.primary,
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
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    Text(
                      context.t('点击打开通话界面'),
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.7),
                          ),
                    ),
                  ],
                ),
              ),
              if (info.state == CallState.incoming && widget.onReject != null)
                TextButton(
                  key: const ValueKey<String>('call-notice-reject'),
                  onPressed: widget.onReject,
                  child: Text(context.t('拒绝')),
                ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
