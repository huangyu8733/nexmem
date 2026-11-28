/// 非 Web 构建的空占位：条件导入在 Web 上换成 voice_recorder_web_impl.dart。
library;

import 'voice_recorder.dart';

VoiceRecorder createVoiceRecorder({Uri? endpoint, String token = ''}) =>
    const UnsupportedVoiceRecorder();
