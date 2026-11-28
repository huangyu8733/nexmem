/// 跨平台本机文件/目录选择器。
///
/// - 桌面端：`file_picker` 打开系统文件管理器，直接使用内核可读的绝对路径。
/// - Web 端：浏览器不允许把本机路径交给服务端，选择后用 `/upload` 把字节
///   上传到网关临时目录，再把服务端路径交给内核，保持 `dm.sendFile` /
///   `file.sharePublish` 的既有契约不变。
/// - 移动端：聊天文件与分享目录走各自的平台通道，这个类只在桌面/Web 使用。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../chat/chat_message.dart';
import 'system_file_picker_web.dart'
    if (dart.library.html) 'system_file_picker_web_impl.dart';

/// 把 WebSocket 地址换算成网关 HTTP 上传地址。
Uri webUploadUri(Uri endpoint, String token) => endpoint.replace(
  scheme: endpoint.scheme == 'wss' ? 'https' : 'http',
  path: '/upload',
  queryParameters: <String, String>{'token': token},
);

String _mimeForName(String name) {
  final String image = imageMimeFor(name);
  if (image.isNotEmpty) return image;
  return audioMimeFor(name);
}

/// 选择单个本地文件并返回可交给内核的附件。
///
/// [endpoint] 与 [token] 仅在 Web 端用于上传；桌面端忽略。
Future<ChatAttachment?> pickLocalFile({
  Uri? endpoint,
  String token = '',
  FileType type = FileType.any,
}) async {
  final PlatformFile? file = await FilePicker.pickFile(type: type);
  if (file == null) {
    return null;
  }
  final String mime = _mimeForName(file.name);
  final int size = await file.length() ?? 0;
  if (!kIsWeb) {
    final String? path = file.path;
    if (path == null || path.isEmpty) {
      return null;
    }
    return ChatAttachment(name: file.name, size: size, mime: mime, path: path);
  }

  final Uri? upload = endpoint;
  if (upload == null) {
    throw StateError('Web 文件选择缺少网关地址');
  }
  final Uint8List bytes = await file.readAsBytes();
  final http.MultipartRequest request = http.MultipartRequest(
    'POST',
    webUploadUri(upload, token),
  );
  request.fields['mode'] = 'file';
  request.files.add(
    http.MultipartFile.fromBytes('file', bytes, filename: file.name),
  );
  final http.StreamedResponse response = await request.send();
  final String body = await response.stream.bytesToString();
  if (response.statusCode != 200) {
    throw StateError('上传文件失败（${response.statusCode}）：$body');
  }
  final Map<String, dynamic> data = jsonDecode(body) as Map<String, dynamic>;
  final Object? path = data['path'];
  if (path is! String || path.isEmpty) {
    throw StateError('上传响应缺少文件路径');
  }
  return ChatAttachment(
    name: data['name'] is String ? data['name'] as String : file.name,
    size: data['size'] is num ? (data['size'] as num).toInt() : bytes.length,
    mime: mime,
    path: path,
  );
}

/// 选择图片：桌面打开系统图片选择器，Web 复用鉴权上传通道。
Future<ChatAttachment?> pickLocalImage({Uri? endpoint, String token = ''}) =>
    pickLocalFile(endpoint: endpoint, token: token, type: FileType.image);

/// 选择本地目录并返回内核可读的目录路径。
///
/// Web 端使用 `<input webkitdirectory>` 打开浏览器目录选择器，并把目录内
/// 文件按相对路径上传到网关；桌面端沿用 `file_picker` 的系统目录对话框。
Future<String?> pickLocalDirectory({Uri? endpoint, String token = ''}) async {
  if (kIsWeb) {
    final Uri? upload = endpoint;
    if (upload == null) {
      throw StateError('Web 目录选择缺少网关地址');
    }
    final List<WebPickedFile>? files = await pickWebDirectoryFiles();
    if (files == null || files.isEmpty) {
      return null;
    }
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      webUploadUri(upload, token),
    );
    request.fields['mode'] = 'dir';
    for (final WebPickedFile file in files) {
      // MultipartRequest.fields 是 Map，同名字段会互相覆盖；
      // 用独立分片按顺序上报每个文件的相对路径。
      request.files.add(
        http.MultipartFile.fromString('relative_path', file.relativePath),
      );
      request.files.add(
        http.MultipartFile.fromBytes('files', file.bytes, filename: file.name),
      );
    }
    final http.StreamedResponse response = await request.send();
    final String body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw StateError('上传目录失败（${response.statusCode}）：$body');
    }
    final Map<String, dynamic> data = jsonDecode(body) as Map<String, dynamic>;
    final Object? path = data['path'];
    return path is String && path.isNotEmpty ? path : null;
  }

  try {
    final Uri? uri = await FilePicker.pickDirectory();
    if (uri == null) return null;
    if (uri.scheme == 'file') return uri.toFilePath();
    final String raw = uri.toString();
    return raw.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(raw)
        ? raw
        : null;
  } on Object {
    return null;
  }
}
