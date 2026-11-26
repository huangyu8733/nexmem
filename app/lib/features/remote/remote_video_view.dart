// 控制端远控画面：RTCVideoRenderer 以 Contain 方式铺满可用区域。
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:material_ui/material_ui.dart';

class RemoteVideoView extends StatelessWidget {
  const RemoteVideoView({super.key, required this.renderer});

  final Object? renderer;

  @override
  Widget build(BuildContext context) {
    final Object? view = renderer;
    if (view is RTCVideoRenderer) {
      return RTCVideoView(
        view,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    }
    return const ColoredBox(
      color: Color(0xFF111317),
      child: Center(
        child: Icon(Icons.desktop_windows_outlined, color: Colors.white24, size: 48),
      ),
    );
  }
}
