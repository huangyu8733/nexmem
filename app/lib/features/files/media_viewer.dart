import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/l10n.dart';
import 'media_io_bridge.dart';
import 'media_probe.dart';

/// 常见媒体文件的分类，优先按扩展名判断，mime 作为补充。
enum MediaKind { image, video, audio, other }

MediaKind mediaKindOf(String path, {String mime = ''}) {
  final String lower = path.toLowerCase();
  final String type = mime.toLowerCase();
  const Set<String> images = <String>{
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.svg',
  };
  const Set<String> videos = <String>{
    '.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.wmv', '.m4v', '.ts',
  };
  const Set<String> audios = <String>{
    '.mp3', '.wav', '.aac', '.flac', '.ogg', '.m4a', '.wma', '.opus',
  };
  final Uri uri = Uri.tryParse(lower) ?? Uri();
  final String ext = uri.pathSegments.isEmpty
      ? ''
      : pExtension(uri.pathSegments.last);
  if (images.contains(ext) || type.startsWith('image/')) return MediaKind.image;
  if (videos.contains(ext) || type.startsWith('video/')) return MediaKind.video;
  if (audios.contains(ext) || type.startsWith('audio/')) return MediaKind.audio;
  return MediaKind.other;
}

String pExtension(String name) {
  final int dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

IconData mediaIcon(MediaKind kind) {
  switch (kind) {
    case MediaKind.image:
      return Icons.image_outlined;
    case MediaKind.video:
      return Icons.movie_outlined;
    case MediaKind.audio:
      return Icons.audiotrack;
    case MediaKind.other:
      return Icons.insert_drive_file_outlined;
  }
}

/// 媒体预览弹窗：图片支持缩放，视频/音频使用原生播放器，
/// 原生解码失败时可按「ffmpeg 转码播放」用随包工具链转换后再播。
///
/// [sourceUri] 非空时走在线播放（Web 的鉴权 `/download?disposition=inline`），
/// 图片用 `Image.network`、视频/音频用网络源；为空时保持原来的本地文件播放。
class MediaViewerDialog extends StatefulWidget {
  const MediaViewerDialog({
    super.key,
    required this.path,
    this.mime = '',
    this.title,
    this.sourceUri,
  });

  final String path;
  final String mime;
  final String? title;
  final Uri? sourceUri;

  @override
  State<MediaViewerDialog> createState() => _MediaViewerDialogState();
}

class _MediaViewerDialogState extends State<MediaViewerDialog> {
  late final MediaKind _kind = mediaKindOf(widget.path, mime: widget.mime);
  VideoPlayerController? _video;
  final AudioPlayer _audio = AudioPlayer();
  MediaProbeInfo? _info;
  bool _loading = false;
  bool _videoReady = false;
  bool _videoFailed = false;
  String? _notice;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  String? _transcodedPath;

  @override
  void initState() {
    super.initState();
    _probeAndOpen();
  }

  Future<void> _probeAndOpen() async {
    setState(() => _loading = true);
    // 在线播放的 path 是网关服务端路径，本机探测无意义；本地文件才探测元信息。
    final MediaProbeInfo? info = widget.sourceUri == null
        ? await probeMedia(widget.path)
        : null;
    if (!mounted) return;
    setState(() => _info = info);
    if (_kind == MediaKind.video) {
      await _openVideo(widget.path);
    } else if (_kind == MediaKind.audio) {
      await _openAudio(widget.path);
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _openVideo(String path) async {
    await _video?.dispose();
    _positionSub?.cancel();
    final VideoPlayerController controller = widget.sourceUri == null
        ? mediaVideoController(path)
        : VideoPlayerController.networkUrl(widget.sourceUri!);
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _video = controller;
        _videoReady = true;
        _videoFailed = false;
        _duration = controller.value.duration;
        _loading = false;
      });
      controller.addListener(_onVideoTick);
    } catch (_) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _videoFailed = true;
        _videoReady = false;
        _loading = false;
        _notice = widget.sourceUri == null
            ? '原生播放器无法解码该文件，可尝试 ffmpeg 转码播放'
            : '在线播放失败，请下载后使用本地播放器打开';
      });
    }
  }

  void _onVideoTick() {
    final VideoPlayerController? controller = _video;
    if (controller == null || !mounted) return;
    final bool playing = controller.value.isPlaying;
    final Duration position = controller.value.position;
    if (playing != _playing || position != _position) {
      setState(() {
        _playing = playing;
        _position = position;
      });
    }
  }

  Future<void> _openAudio(String path) async {
    try {
      if (widget.sourceUri != null) {
        await _audio.setSource(UrlSource(widget.sourceUri!.toString()));
      } else {
        await _audio.setSource(DeviceFileSource(path));
      }
      _duration = await _audio.getDuration() ?? Duration.zero;
      _positionSub = _audio.onPositionChanged.listen((Duration d) {
        if (mounted) setState(() => _position = d);
      });
      _durationSub = _audio.onDurationChanged.listen((Duration d) {
        if (mounted) setState(() => _duration = d);
      });
      _stateSub = _audio.onPlayerStateChanged.listen((PlayerState s) {
        if (mounted) setState(() => _playing = s == PlayerState.playing);
      });
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = widget.sourceUri == null
            ? '原生播放器无法解码该文件，可尝试 ffmpeg 转码播放'
            : '在线播放失败，请下载后使用本地播放器打开';
      });
    }
  }

  Future<void> _togglePlayback() async {
    final VideoPlayerController? video = _video;
    if (video != null && _videoReady) {
      if (video.value.isPlaying) {
        await video.pause();
      } else {
        if (video.value.position >= video.value.duration &&
            video.value.duration > Duration.zero) {
          await video.seekTo(Duration.zero);
        }
        await video.play();
      }
      return;
    }
    if (_kind == MediaKind.audio) {
      if (_playing) {
        await _audio.pause();
      } else {
        await _audio.resume();
      }
    }
  }

  Future<void> _seek(double value) async {
    final Duration target = Duration(
      milliseconds: (_duration.inMilliseconds * value).round(),
    );
    final VideoPlayerController? video = _video;
    if (video != null && _videoReady) {
      await video.seekTo(target);
    } else if (_kind == MediaKind.audio) {
      await _audio.seek(target);
    }
  }

  Future<void> _transcode() async {
    if (!ffmpegAvailable) {
      setState(() => _notice = '未找到 ffmpeg，请把 ffmpeg 工具放到应用目录的 ffmpeg/ 文件夹');
      return;
    }
    setState(() => _loading = true);
    try {
      final String? output = await transcodeMedia(
        widget.path,
        target: _kind == MediaKind.audio
            ? TranscodeTarget.audio
            : TranscodeTarget.video,
        tempDir: mediaTempDir(),
      );
      if (!mounted) return;
      if (output == null) {
        setState(() {
          _loading = false;
          _notice = 'ffmpeg 转码失败，文件可能使用了不支持的编码';
        });
        return;
      }
      _transcodedPath = output;
      setState(() {
        _notice = '转码完成，正在播放兼容版本';
        _loading = false;
      });
      if (_kind == MediaKind.video) {
        await _openVideo(output);
      } else {
        await _openAudio(output);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = 'ffmpeg 转码失败，文件可能使用了不支持的编码';
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _video?.removeListener(_onVideoTick);
    unawaited(_video?.dispose());
    unawaited(_audio.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.title ?? _fileName(widget.path);
    return AlertDialog(
      key: const ValueKey<String>('media-viewer-dialog'),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildMedia(),
              const SizedBox(height: 12),
              if (_info != null)
                Wrap(
                  spacing: 12,
                  children: <Widget>[
                    if (_info!.durationMs > 0)
                      Text(context.t('时长 {0}', <String>[_info!.durationLabel])),
                    if (_info!.dimensionLabel.isNotEmpty)
                      Text(context.t('分辨率 {0}', <String>[_info!.dimensionLabel])),
                    if (_info!.videoCodec.isNotEmpty)
                      Text(context.t('视频 {0}', <String>[_info!.videoCodec])),
                    if (_info!.audioCodec.isNotEmpty)
                      Text(context.t('音频 {0}', <String>[_info!.audioCodec])),
                  ],
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    context.t(_notice!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (widget.sourceUri == null &&
            ((_videoFailed && _kind == MediaKind.video) ||
                (_kind == MediaKind.audio &&
                    _notice != null &&
                    _transcodedPath == null)))
          TextButton.icon(
            onPressed: _loading ? null : _transcode,
            icon: const Icon(Icons.movie_creation_outlined, size: 18),
            label: Text(context.t('ffmpeg 转码播放')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('关闭')),
        ),
      ],
    );
  }

  Widget _buildMedia() {
    if (_loading && _video == null && _kind != MediaKind.image) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    switch (_kind) {
      case MediaKind.image:
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: InteractiveViewer(
            child: widget.sourceUri == null
                ? Image(
                    image: mediaImageProvider(widget.path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        _placeholder(Icons.broken_image_outlined),
                  )
                : Image.network(
                    widget.sourceUri!.toString(),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        _placeholder(Icons.broken_image_outlined),
                  ),
          ),
        );
      case MediaKind.video:
        if (_video == null || !_videoReady) return _placeholder(Icons.movie_outlined);
        return Column(
          children: <Widget>[
            AspectRatio(
              aspectRatio: _video!.value.aspectRatio > 0
                  ? _video!.value.aspectRatio
                  : 16 / 9,
              child: VideoPlayer(_video!),
            ),
            _controls(),
          ],
        );
      case MediaKind.audio:
        return Column(
          children: <Widget>[
            const SizedBox(
              height: 120,
              child: Center(
                child: Icon(Icons.audiotrack, size: 64),
              ),
            ),
            _controls(),
          ],
        );
      case MediaKind.other:
        return _placeholder(Icons.insert_drive_file_outlined);
    }
  }

  Widget _controls() {
    final bool hasTimeline = _duration > Duration.zero;
    return Column(
      children: <Widget>[
        Slider(
          value: hasTimeline
              ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
              : 0,
          onChanged: hasTimeline ? _seek : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(_formatDuration(_position)),
              IconButton(
                icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle),
                iconSize: 36,
                onPressed: _togglePlayback,
              ),
              Text(_formatDuration(_duration)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _placeholder(IconData icon) => SizedBox(
        height: 200,
        child: Center(
          child: Icon(icon, size: 56, color: Theme.of(context).disabledColor),
        ),
      );

  String _fileName(String path) {
    final int slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }

  String _formatDuration(Duration d) {
    final int total = d.inSeconds;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:'
        '${(total % 60).toString().padLeft(2, '0')}';
  }
}
