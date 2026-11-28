import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/l10n.dart';
import '../qr/image_qr_decoder.dart';
import '../qr/qr_result_handler.dart';
import 'media_io_bridge.dart';
import 'media_probe.dart';

/// 常见媒体文件的分类，优先按扩展名判断，mime 作为补充。
enum MediaKind { image, video, audio, other }

MediaKind mediaKindOf(String path, {String mime = ''}) {
  final String lower = path.toLowerCase();
  final String type = mime.toLowerCase();
  const Set<String> images = <String>{
    '.jpg', '.jpeg', '.jfif', '.png', '.gif', '.webp', '.bmp',
    '.heic', '.heif', '.tif', '.tiff', '.avif', '.ico', '.svg',
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

/// 全屏媒体查看器：图片全屏缩放查看、视频全屏播放、音乐全屏播放。
///
/// 保留原 [MediaViewerDialog] 类型与构造参数，内部改为满屏页面式布局，
/// 点击聊天/文件里的媒体气泡即进入全屏；右上角关闭按钮退出。
///
/// [sourceUri] 非空时走在线播放（Web 的鉴权 `/download?disposition=inline`），
/// 图片用 `Image.network`、视频/音频用网络源；为空时保持原来的本地文件播放。
/// 原生解码失败时可按「ffmpeg 转码播放」用随包工具链转换后再播。
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
  final TransformationController _imageTransform = TransformationController();
  MediaProbeInfo? _info;
  bool _loading = false;
  bool _videoReady = false;
  bool _videoFailed = false;
  String? _notice;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _showControls = true;
  bool _imageZoomed = false;
  bool _landscape = false;

  /// 只有移动端能真正切换系统方向；Web/桌面隐藏无效按钮。
  bool get _orientationControlAvailable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  String? _transcodedPath;

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
    _probeAndOpen();
  }

  void _enterFullscreen() {
    // 隐藏系统栏进入沉浸全屏；测试/不支持平台静默忽略。
    try {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } on Object {
      // ignore
    }
  }

  void _exitFullscreen() {
    try {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    } on Object {
      // ignore
    }
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

  Future<void> _toggleOrientation() async {
    _landscape = !_landscape;
    try {
      await SystemChrome.setPreferredOrientations(
        _landscape
            ? <DeviceOrientation>[
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : <DeviceOrientation>[
                DeviceOrientation.portraitUp,
                DeviceOrientation.portraitDown,
              ],
      );
    } on Object {
      // ignore
    }
    if (mounted) setState(() {});
  }

  void _toggleImageZoom() {
    if (!mounted) return;
    setState(() {
      _imageZoomed = !_imageZoomed;
      _imageTransform.value = _imageZoomed
          ? Matrix4.diagonal3Values(2.5, 2.5, 1.0)
          : Matrix4.identity();
    });
  }

  /// 图片长按 / 右键识别二维码；网址进入内置浏览器，其它内容可复制。
  Future<void> _recognizeQr() async {
    if (_kind != MediaKind.image) {
      return;
    }
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    if (!qrImageDecodeSupported) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(context.t('当前平台不支持图片二维码识别，请用摄像头扫码')),
        ),
      );
      return;
    }
    messenger?.showSnackBar(
      SnackBar(content: Text(context.t('正在识别二维码…'))),
    );
    final String? raw = await decodeQrFromImage(
      path: widget.path,
      sourceUri: widget.sourceUri?.toString(),
    );
    if (!mounted) {
      return;
    }
    if (raw == null || raw.isEmpty) {
      messenger?.showSnackBar(
        SnackBar(content: Text(context.t('未识别到二维码'))),
      );
      return;
    }
    await handleQrResult(context, raw);
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
    _imageTransform.dispose();
    _exitFullscreen();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.title ?? _fileName(widget.path);
    return Material(
      key: const ValueKey<String>('media-viewer-dialog'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 媒体铺满整屏。
          Positioned.fill(child: _buildMedia()),
          // 顶部标题栏 + 关闭按钮。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      key: const ValueKey<String>('media-viewer-close'),
                      tooltip: context.t('关闭'),
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    if (_kind == MediaKind.video &&
                        _orientationControlAvailable)
                      IconButton(
                        key: const ValueKey<String>('media-viewer-orientation'),
                        icon: const Icon(
                          Icons.screen_rotation,
                          color: Colors.white,
                        ),
                        onPressed: _toggleOrientation,
                      ),
                  ],
                ),
              ),
            ),
          ),
          // 播放/进度控制条（视频与音频）。
          if (_kind == MediaKind.video || _kind == MediaKind.audio)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: _controls(),
                ),
              ),
            ),
          // 加载态。
          if (_loading && _kind != MediaKind.image)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }

  Widget _buildMedia() {
    switch (_kind) {
      case MediaKind.image:
        return GestureDetector(
          key: const ValueKey<String>('media-viewer-image'),
          onDoubleTap: _toggleImageZoom,
          onLongPress: () => unawaited(_recognizeQr()),
          onSecondaryTapDown: (_) => unawaited(_recognizeQr()),
          behavior: HitTestBehavior.opaque,
          child: InteractiveViewer(
            transformationController: _imageTransform,
            maxScale: 8,
            child: Center(
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
          ),
        );
      case MediaKind.video:
        if (_video == null || !_videoReady) return _placeholder(Icons.movie_outlined);
        return GestureDetector(
          key: const ValueKey<String>('media-viewer-video'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            unawaited(_togglePlayback());
            setState(() => _showControls = !_showControls);
          },
          child: Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: _video!.value.size.width > 0
                    ? _video!.value.size.width
                    : 1,
                height: _video!.value.size.height > 0
                    ? _video!.value.size.height
                    : 1,
                child: VideoPlayer(_video!),
              ),
            ),
          ),
        );
      case MediaKind.audio:
        return GestureDetector(
          key: const ValueKey<String>('media-viewer-audio'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_togglePlayback()),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 168,
                height: 168,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.audiotrack,
                  size: 96,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                widget.title ?? _fileName(widget.path),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        );
      case MediaKind.other:
        return _placeholder(Icons.insert_drive_file_outlined);
    }
  }

  Widget _controls() {
    final bool hasTimeline = _duration > Duration.zero;
    final bool canTranscode = widget.sourceUri == null &&
        ((_videoFailed && _kind == MediaKind.video) ||
            (_kind == MediaKind.audio &&
                _notice != null &&
                _transcodedPath == null));
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x00000000), Color(0xCC000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_info != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 12,
                  children: <Widget>[
                    if (_info!.durationMs > 0)
                      Text(
                        context.t('时长 {0}', <String>[_info!.durationLabel]),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    if (_info!.dimensionLabel.isNotEmpty)
                      Text(
                        context.t('分辨率 {0}', <String>[_info!.dimensionLabel]),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    if (_info!.videoCodec.isNotEmpty)
                      Text(
                        context.t('视频 {0}', <String>[_info!.videoCodec]),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    if (_info!.audioCodec.isNotEmpty)
                      Text(
                        context.t('音频 {0}', <String>[_info!.audioCodec]),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                  ],
                ),
              ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  context.t(_notice!),
                  style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                ),
              ),
            Slider(
              value: hasTimeline
                  ? (_position.inMilliseconds / _duration.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0,
              onChanged: hasTimeline ? _seek : null,
              activeColor: Colors.white,
              inactiveColor: Colors.white38,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                IconButton(
                  key: const ValueKey<String>('media-viewer-play-toggle'),
                  icon: Icon(
                    _playing ? Icons.pause_circle : Icons.play_circle,
                    color: Colors.white,
                  ),
                  iconSize: 40,
                  onPressed: _togglePlayback,
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
            if (canTranscode)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey<String>('media-viewer-transcode'),
                  onPressed: _loading ? null : _transcode,
                  icon: const Icon(Icons.movie_creation_outlined, size: 18),
                  label: Text(
                    context.t('ffmpeg 转码播放'),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(IconData icon) => Center(
        child: Icon(icon, size: 72, color: Colors.white38),
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
