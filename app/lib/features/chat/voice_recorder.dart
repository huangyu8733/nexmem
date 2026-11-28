/// 按住说话（PTT）录音能力。
///
/// - Android / iOS：走 `io.nexmem/core` MethodChannel，由原生 MediaRecorder /
///   AVAudioRecorder 输出 m4a 到应用缓存目录。
/// - Web：浏览器 MediaRecorder + 鉴权 `/upload`，把录音字节上传到网关后回传路径。
/// - 桌面：暂无系统录音通道，[VoiceRecorder.supported] 返回 false，
///   聊天页提示改用「音视频」按钮选择本机音频文件。
library;

import 'voice_recorder_io.dart'
    if (dart.library.html) 'voice_recorder_web.dart';

/// 一次完成的录音结果，可直接交给 `ChatStore.sendFile`。
class VoiceRecording {
  const VoiceRecording({
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
    required this.duration,
  });

  final String path;
  final String name;
  final String mime;
  final int size;

  /// 录音时长，用于气泡上展示语音秒数。
  final Duration duration;
}

/// 平台录音器。同一时刻只允许一个实例处于录音状态。
abstract class VoiceRecorder {
  /// 当前平台是否支持按住说话。
  bool get supported;

  bool get isRecording;

  /// 开始录音。成功返回 true；权限拒绝 / 设备不可用时返回 false。
  Future<bool> start();

  /// 停止录音并返回结果；录音过短或没有录音时返回 null。
  Future<VoiceRecording?> stop();

  /// 取消录音并删除临时文件。
  Future<void> cancel();
}

/// 无录音通道的平台安全降级：按钮仍可见，点击后提示改用音频文件选择。
class UnsupportedVoiceRecorder implements VoiceRecorder {
  const UnsupportedVoiceRecorder();

  @override
  bool get supported => false;

  @override
  bool get isRecording => false;

  @override
  Future<bool> start() async => false;

  @override
  Future<VoiceRecording?> stop() async => null;

  @override
  Future<void> cancel() async {}
}

/// 工厂：Web 需要网关地址以上传录音字节；移动端 / 桌面忽略这两个参数。
VoiceRecorder makeVoiceRecorder({Uri? endpoint, String token = ''}) =>
    createVoiceRecorder(endpoint: endpoint, token: token);
