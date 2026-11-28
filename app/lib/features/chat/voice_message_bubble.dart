/// 聊天语音气泡：微信 / QQ 风格的内联播放。
///
/// 语音消息点击后直接在气泡内播放，不再打开 MediaViewerDialog。
/// 每个气泡懒创建一个播放器；播放前通过 [_VoicePlaybackRegistry] 抢占，
/// 保证同一时刻只有一条语音在播放。播放器接口可注入，便于测试替身。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

/// 语音气泡所需的最小播放器能力。
abstract class VoiceMessagePlayer {
  Future<void> setSource(Source source);
  Future<void> resume();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<Duration?> getDuration();
  Stream<Duration> get onPositionChanged;
  Stream<Duration> get onDurationChanged;
  Stream<PlayerState> get onPlayerStateChanged;
  Future<void> dispose();
}

/// 生产实现：audioplayers 的薄封装。
class AudioPlayersVoiceMessagePlayer implements VoiceMessagePlayer {
  AudioPlayersVoiceMessagePlayer(this._player);

  final AudioPlayer _player;

  @override
  Future<void> setSource(Source source) => _player.setSource(source);

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<Duration?> getDuration() => _player.getDuration();

  @override
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;

  @override
  Stream<Duration> get onDurationChanged => _player.onDurationChanged;

  @override
  Stream<PlayerState> get onPlayerStateChanged => _player.onPlayerStateChanged;

  @override
  Future<void> dispose() => _player.dispose();
}

typedef VoiceMessagePlayerFactory = VoiceMessagePlayer Function();

abstract class _PlaybackOwner {
  Future<void> pauseFor(String requester);
}

/// 全局播放仲裁：同一时刻只允许一个语音气泡处于播放态。
final class _VoicePlaybackRegistry {
  static final Map<String, _PlaybackOwner> _owners = <String, _PlaybackOwner>{};
  static String? _activeId;

  static void register(String id, _PlaybackOwner owner) {
    _owners[id] = owner;
  }

  static void unregister(String id, _PlaybackOwner owner) {
    if (identical(_owners[id], owner)) {
      _owners.remove(id);
    }
    if (_activeId == id) {
      _activeId = null;
    }
  }

  static Future<void> takeOver(
    String id,
    _PlaybackOwner owner,
    Future<void> Function() start,
  ) async {
    final String? active = _activeId;
    if (active != null && active != id) {
      final _PlaybackOwner? previous = _owners[active];
      if (previous != null) {
        await previous.pauseFor(id);
      }
    }
    _activeId = id;
    try {
      await start();
    } on Object {
      if (_activeId == id) {
        _activeId = null;
      }
      rethrow;
    }
  }

  static void paused(String id) {
    if (_activeId == id) {
      _activeId = null;
    }
  }
}

/// 语音消息气泡（内联播放，不弹窗）。
class VoiceMessageBubble extends StatefulWidget {
  const VoiceMessageBubble({
    super.key,
    required this.id,
    required this.name,
    required this.path,
    required this.mine,
    this.sourceUri,
    this.playerFactory,
    this.onSave,
  });

  final String id;

  /// 附件文件名，仅用于无障碍标签与失败提示。
  final String name;

  /// 本机路径；Web 端可为空，此时使用 [sourceUri]。
  final String path;

  final bool mine;

  /// Web 鉴权在线播放源（与图片 / 视频气泡一致）。
  final Uri? sourceUri;

  /// 测试或自定义播放器注入；为空时创建 audioplayers 实例。
  final VoiceMessagePlayerFactory? playerFactory;

  final VoidCallback? onSave;

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble>
    implements _PlaybackOwner {
  VoiceMessagePlayer? _player;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  bool _prepared = false;
  bool _preparing = false;
  bool _starting = false;
  bool _playing = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _scrubPosition;

  @override
  void initState() {
    super.initState();
    _VoicePlaybackRegistry.register(widget.id, this);
  }

  @override
  void dispose() {
    _VoicePlaybackRegistry.unregister(widget.id, this);
    unawaited(_stopForDispose());
    super.dispose();
  }

  Future<void> _stopForDispose() async {
    final VoiceMessagePlayer? player = _player;
    if (player == null) return;
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _stateSub?.cancel();
    try {
      await player.stop();
      await player.dispose();
    } on Object {
      // 页面销毁时播放器可能已释放；无需向用户暴露。
    }
  }

  Future<VoiceMessagePlayer> _prepare() async {
    final VoiceMessagePlayer player = _player ??=
        widget.playerFactory?.call() ??
        AudioPlayersVoiceMessagePlayer(AudioPlayer());
    if (_prepared || _preparing) {
      while (_preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return player;
    }
    _preparing = true;
    try {
      if (widget.sourceUri != null) {
        await player.setSource(UrlSource(widget.sourceUri!.toString()));
      } else {
        await player.setSource(DeviceFileSource(widget.path));
      }
      _duration = await player.getDuration() ?? Duration.zero;
      _positionSub = player.onPositionChanged.listen((Duration position) {
        if (!mounted || position == _position) return;
        setState(() => _position = position);
      });
      _durationSub = player.onDurationChanged.listen((Duration duration) {
        if (!mounted || duration == _duration) return;
        setState(() => _duration = duration);
      });
      _stateSub = player.onPlayerStateChanged.listen((PlayerState state) {
        if (!mounted) return;
        if (state == PlayerState.completed) {
          _VoicePlaybackRegistry.paused(widget.id);
          setState(() {
            _playing = false;
            _position = Duration.zero;
            _scrubPosition = null;
          });
          return;
        }
        final bool playing = state == PlayerState.playing;
        if (playing != _playing) {
          setState(() => _playing = playing);
        }
      });
      _prepared = true;
      return player;
    } on Object {
      if (mounted) setState(() => _failed = true);
      rethrow;
    } finally {
      _preparing = false;
    }
  }

  @override
  Future<void> pauseFor(String requester) => _pause(notifyRegistry: false);

  Future<void> _pause({bool notifyRegistry = true}) async {
    final VoiceMessagePlayer? player = _player;
    if (player == null) return;
    try {
      await player.pause();
    } on Object {
      // 暂停失败也要让出新播放权，避免后续消息一直被占用。
    }
    if (notifyRegistry) {
      _VoicePlaybackRegistry.paused(widget.id);
    }
    if (mounted && _playing) {
      setState(() => _playing = false);
    }
  }

  Future<void> _seek(double value) async {
    final VoiceMessagePlayer? player = _player;
    if (player == null || _duration == Duration.zero) return;
    final Duration target = Duration(
      milliseconds: (value * _duration.inMilliseconds).round(),
    );
    try {
      await player.seek(target);
      if (mounted) {
        setState(() {
          _position = target;
          _scrubPosition = null;
        });
      }
    } on Object {
      if (mounted) setState(() => _scrubPosition = null);
    }
  }

  Future<void> _toggle() async {
    if (_starting) return;
    if (_playing) {
      await _pause();
      return;
    }
    if (widget.path.isEmpty && widget.sourceUri == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    setState(() {
      _starting = true;
      _failed = false;
    });
    try {
      await _VoicePlaybackRegistry.takeOver(widget.id, this, () async {
        final VoiceMessagePlayer player = await _prepare();
        await player.resume();
        // Android 上部分 aac/m4a 在 setSource 阶段拿不到时长，
        // 真正开始解码后才会刷新；这里补取一次，避免长期显示 --:--。
        final Duration? refreshed = await player.getDuration();
        if (refreshed != null && refreshed > Duration.zero && mounted) {
          setState(() => _duration = refreshed);
        }
      });
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  static String _format(Duration duration) {
    final int seconds = duration.inSeconds;
    if (seconds < 60) return '0:${seconds.toString().padLeft(2, '0')}';
    final int minutes = seconds ~/ 60;
    if (minutes < 60) {
      return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
    }
    final int hours = minutes ~/ 60;
    return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fg = widget.mine ? Colors.white : scheme.onSurface;
    final Color muted = fg.withValues(alpha: 0.78);
    final double barWidth = math.min(180, MediaQuery.sizeOf(context).width * 0.42);
    final double ratio = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final String durationText = _duration == Duration.zero
        ? '--:--'
        : _format(_duration);
    final String label = _failed
        ? context.t('语音播放失败：{0}', [widget.name])
        : context.t('语音 {0}，时长 {1}', [widget.name, durationText]);

    final Widget player = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          key: ValueKey<String>('chat-voice-play-${widget.id}'),
          onTap: () => unawaited(_toggle()),
          borderRadius: BorderRadius.circular(24),
          // 视觉直径保持 34，触控区扩到 48，避免手指点击落空。
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _starting
                      ? Icons.hourglass_top
                      : _failed
                          ? Icons.error_outline
                          : _playing
                              ? Icons.pause
                              : Icons.play_arrow,
                  size: 20,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: SizedBox(
            width: barWidth,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  activeTrackColor: fg,
                  inactiveTrackColor: fg.withValues(alpha: 0.2),
                  thumbColor: fg,
                  overlayColor: fg.withValues(alpha: 0.16),
                ),
                child: Slider(
                  key: ValueKey<String>('chat-voice-progress-${widget.id}'),
                  value: _scrubPosition != null && _duration.inMilliseconds > 0
                      ? (_scrubPosition!.inMilliseconds /
                              _duration.inMilliseconds)
                          .clamp(0.0, 1.0)
                      : ratio,
                  max: 1,
                  onChanged: _duration == Duration.zero
                      ? null
                      : (double value) {
                          setState(() {
                            _scrubPosition = Duration(
                              milliseconds: (value * _duration.inMilliseconds)
                                  .round(),
                            );
                          });
                        },
                  onChangeEnd: _duration == Duration.zero
                      ? null
                      : (double value) => unawaited(_seek(value)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.graphic_eq,
                      size: 12,
                      color: muted,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _scrubPosition == null
                          ? durationText
                          : '${_format(_scrubPosition!)}/$durationText',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
              ],
            ),
          ),
        ),
        if (widget.onSave != null) ...<Widget>[
          const SizedBox(width: 2),
          IconButton(
            key: ValueKey<String>('chat-file-save-${widget.id}'),
            icon: Icon(Icons.save_alt_outlined, size: 18, color: fg),
            tooltip: context.t('保存到本机'),
            onPressed: widget.onSave,
          ),
        ],
      ],
    );

    // 保留 chat-media-preview-* key：接收端传输完成回补路径后，
    // 现有验收仍能稳定找到这条语音气泡；但点击行为已改为内联播放。
    return KeyedSubtree(
      key: ValueKey<String>('chat-media-preview-${widget.id}'),
      child: Semantics(label: label, child: player),
    );
  }
}
