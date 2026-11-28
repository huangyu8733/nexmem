/// 聊天视频气泡封面：取视频首帧作为静态缩略图。
///
/// 使用 paused 的 [VideoPlayerController] 只做解码初始化，不开始播放。
/// 本地文件不存在或平台不支持时回退为通用播放图标，避免测试/离线场景
/// 因原生插件不可用而报错。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../files/media_io_bridge.dart';

/// 视频首帧封面；点击行为仍由外层气泡处理（打开 MediaViewerDialog）。
class VideoThumbnail extends StatefulWidget {
  const VideoThumbnail({
    super.key,
    required this.path,
    this.sourceUri,
    required this.width,
    required this.height,
    required this.color,
  });

  final String path;
  final Uri? sourceUri;
  final double width;
  final double height;
  final Color color;

  @override
  State<VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<VideoThumbnail> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final bool canDecode = widget.sourceUri != null ||
        (!kIsWeb && widget.path.isNotEmpty && mediaFileExists(widget.path));
    if (!canDecode) return;
    final VideoPlayerController controller = widget.sourceUri == null
        ? mediaVideoController(widget.path)
        : VideoPlayerController.networkUrl(widget.sourceUri!);
    _controller = controller;
    unawaited(() async {
      try {
        await controller.initialize();
        if (!mounted) return;
        setState(() => _ready = true);
      } on Object {
        // 解码失败时保留通用播放图标，不影响消息发送/接收。
      }
    }());
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    if (_ready && controller != null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: controller.value.aspectRatio > 0
                      ? widget.height * controller.value.aspectRatio
                      : widget.width,
                  height: widget.height,
                  child: VideoPlayer(controller),
                ),
              ),
              Container(color: Colors.black.withValues(alpha: 0.12)),
              Center(
                child: Icon(
                  Icons.play_circle_outlined,
                  size: 44,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Icon(
          Icons.play_circle_outlined,
          size: 48,
          color: widget.color,
        ),
      ),
    );
  }
}
