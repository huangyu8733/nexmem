/// Web 录音输出：record 返回 blob URL，读出字节后上传鉴权网关。
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../files/system_file_picker.dart';
import 'voice_recorder.dart';

class WebVoiceOutput implements VoiceOutput {
  WebVoiceOutput({this.endpoint, this.token = ''});

  final Uri? endpoint;
  final String token;

  @override
  Future<String> preparePath() async {
    // Web 上 record 忽略 path，仍给一个稳定占位便于诊断。
    return 'voice.webm';
  }

  @override
  Future<VoiceRecording> finish(String path, Duration duration) async {
    final Uint8List bytes = await _readBlob(path);
    final String name = 'voice-${DateTime.now().millisecondsSinceEpoch}.webm';
    if (bytes.isEmpty) {
      throw StateError('录音内容为空');
    }
    final String serverPath = await _upload(bytes, name);
    return VoiceRecording(
      path: serverPath,
      name: name,
      mime: 'audio/webm',
      size: bytes.length,
      duration: duration,
    );
  }

  Future<Uint8List> _readBlob(String url) async {
    final web.Response response =
        await web.window.fetch(url.toJS).toDart;
    final JSArrayBuffer buffer = await response.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  Future<String> _upload(Uint8List bytes, String name) async {
    final Uri? upload = endpoint;
    if (upload == null) {
      throw StateError('Web 语音上传缺少网关地址');
    }
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      webUploadUri(upload, token),
    );
    request.fields['mode'] = 'file';
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: name),
    );
    final http.StreamedResponse response = await request.send();
    final String body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw StateError('上传语音失败（${response.statusCode}）：$body');
    }
    final Map<String, dynamic> data = jsonDecode(body) as Map<String, dynamic>;
    final Object? path = data['path'];
    if (path is! String || path.isEmpty) {
      throw StateError('上传响应缺少文件路径');
    }
    return path;
  }
}

VoiceOutput createVoiceOutput({Uri? endpoint, String token = ''}) =>
    WebVoiceOutput(endpoint: endpoint, token: token);
