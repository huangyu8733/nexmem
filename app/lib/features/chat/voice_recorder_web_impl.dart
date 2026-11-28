/// Web 按住说话：MediaRecorder 录音后上传到鉴权网关，回传服务端路径。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../files/system_file_picker.dart';
import 'voice_recorder.dart';

class WebVoiceRecorder implements VoiceRecorder {
  WebVoiceRecorder({required this.endpoint, required this.token});

  final Uri? endpoint;
  final String token;

  web.MediaStream? _stream;
  web.MediaRecorder? _recorder;
  final List<web.Blob> _chunks = <web.Blob>[];
  Completer<void>? _stopped;
  DateTime? _startedAt;

  @override
  bool get supported => true;

  @override
  bool get isRecording =>
      _recorder != null && _recorder!.state == 'recording';

  @override
  Future<bool> start() async {
    if (_recorder != null) return false;
    try {
      final web.MediaStream stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              video: false.toJS,
              audio: true.toJS,
            ),
          )
          .toDart;
      final String mimeType = _supportedMime();
      final web.MediaRecorder recorder = web.MediaRecorder(
        stream,
        web.MediaRecorderOptions(
          mimeType: mimeType,
          audioBitsPerSecond: 64000,
        ),
      );
      _chunks.clear();
      _stopped = Completer<void>();
      final Completer<void> stopped = _stopped!;
      recorder.addEventListener(
        'dataavailable',
        ((web.Event event) {
          _chunks.add((event as web.BlobEvent).data);
        }).toJS,
      );
      recorder.addEventListener(
        'stop',
        ((web.Event _) {
          if (!stopped.isCompleted) stopped.complete();
        }).toJS,
      );
      recorder.start();
      _stream = stream;
      _recorder = recorder;
      _startedAt = DateTime.now();
      return true;
    } on Object {
      await _release();
      return false;
    }
  }

  @override
  Future<VoiceRecording?> stop() async {
    final web.MediaRecorder? recorder = _recorder;
    if (recorder == null) return null;
    final Duration duration = DateTime.now().difference(_startedAt ?? DateTime.now());
    final Completer<void> stopped = _stopped ?? Completer<void>()..complete();
    try {
      recorder.stop();
    } on Object {
      // 已经停止时忽略，继续按已有分片收尾。
    }
    await stopped.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    final Uint8List bytes = await _mergeChunks();
    await _release();
    if (bytes.isEmpty || duration.inMilliseconds < 400) {
      return null;
    }
    final String name = 'voice-${DateTime.now().millisecondsSinceEpoch}.webm';
    final String path = await _upload(bytes, name);
    return VoiceRecording(
      path: path,
      name: name,
      mime: 'audio/webm',
      size: bytes.length,
      duration: duration,
    );
  }

  @override
  Future<void> cancel() async {
    final web.MediaRecorder? recorder = _recorder;
    if (recorder == null) return;
    final Completer<void> stopped = _stopped ?? Completer<void>()..complete();
    try {
      recorder.stop();
    } on Object {
      // 忽略：下面直接释放流和分片。
    }
    await stopped.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    await _release();
  }

  Future<void> _release() async {
    final web.MediaRecorder? recorder = _recorder;
    if (recorder != null && recorder.state == 'recording') {
      try {
        recorder.stop();
      } on Object {
        // 忽略：流一定会释放。
      }
    }
    _recorder = null;
    _chunks.clear();
    _stopped = null;
    _startedAt = null;
    final web.MediaStream? stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final web.MediaStreamTrack track in stream.getTracks().toDart) {
        track.stop();
      }
    }
  }

  Future<Uint8List> _mergeChunks() async {
    int total = 0;
    for (final web.Blob chunk in _chunks) {
      total += chunk.size;
    }
    final Uint8List merged = Uint8List(total);
    int offset = 0;
    for (final web.Blob chunk in _chunks) {
      final JSArrayBuffer buffer = await chunk.arrayBuffer().toDart;
      final Uint8List view = buffer.toDart.asUint8List();
      merged.setRange(offset, offset + view.length, view);
      offset += view.length;
    }
    return merged;
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

  String _supportedMime() {
    for (final String type in <String>[
      'audio/webm;codecs=opus',
      'audio/webm',
      'audio/ogg;codecs=opus',
      'audio/mp4',
    ]) {
      if (web.MediaRecorder.isTypeSupported(type)) return type;
    }
    return 'audio/webm';
  }
}
