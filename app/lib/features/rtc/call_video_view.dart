// 通话视频视图：把媒体层暴露的渲染对象包装成 Widget。
//
// 媒体层用 Object? 暴露 RTCVideoRenderer，是为了让 CallService 的单测
// 不依赖平台插件；这里负责识别真实类型并渲染，语音通话则显示占位头像。

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:material_ui/material_ui.dart';

/// 远端/本地视频小窗。renderer 为空或类型不匹配时显示占位图标。
class CallVideoView extends StatelessWidget {
  const CallVideoView({
    super.key,
    required this.renderer,
    this.mirror = false,
    this.label,
  });

  final Object? renderer;
  final bool mirror;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final Object? view = renderer;
    if (view is RTCVideoRenderer) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: RTCVideoView(
          view,
          mirror: mirror,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.person, color: Colors.white54, size: 36),
          if (label != null && label!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              label!,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
