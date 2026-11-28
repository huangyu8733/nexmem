// 非 Web 平台录音输出：record 直接写本机临时 m4a 文件。

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'voice_recorder.dart';

class IoVoiceOutput implements VoiceOutput {
  @override
  Future<String> preparePath() async {
    final Directory temp = await getTemporaryDirectory();
    final String dir = p.join(temp.path, 'nexmem-voice');
    await Directory(dir).create(recursive: true);
    return p.join(dir, 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a');
  }

  @override
  Future<VoiceRecording> finish(String path, Duration duration) async {
    final File file = File(path);
    final int size = await file.length();
    return VoiceRecording(
      path: path,
      name: p.basename(path),
      mime: 'audio/mp4',
      size: size,
      duration: duration,
    );
  }
}

VoiceOutput createVoiceOutput({Uri? endpoint, String token = ''}) =>
    IoVoiceOutput();
