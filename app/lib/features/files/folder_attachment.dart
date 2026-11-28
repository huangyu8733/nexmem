/// 聊天发送文件夹：把目录打包成 ZIP 后复用单文件传输通道。
///
/// - 原生端：由平台目录选择器给出本机路径，逐文件读入内存后生成 ZIP。
/// - Web 端：浏览器 `<input webkitdirectory>` 只能给出 File 对象，先在内存
///   打包，再通过网关 `/upload` 上传，把服务端路径交给内核 `dm.sendFile`。
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../chat/chat_message.dart';
import 'folder_attachment_io_stub.dart'
    if (dart.library.io) 'folder_attachment_io.dart';
import 'system_file_picker.dart' show webUploadUri;
import 'system_file_picker_web.dart'
    if (dart.library.html) 'system_file_picker_web_impl.dart';

/// 选择文件夹并返回可作为聊天附件发送的 ZIP。
///
/// [directoryPicker] 由 CoreSession 注入：Android/iOS 走平台目录选择器，
/// 桌面走系统目录对话框；Web 端忽略该参数，直接走浏览器目录选择。
Future<ChatAttachment?> pickFolderAttachment({
  Uri? endpoint,
  String token = '',
  Future<String?> Function()? directoryPicker,
}) async {
  if (!kIsWeb) {
    return pickLocalFolderZip(directoryPicker);
  }

  final Uri? upload = endpoint;
  if (upload == null) {
    throw StateError('Web 文件夹发送缺少网关地址');
  }
  final List<WebPickedFile>? files = await pickWebDirectoryFiles();
  if (files == null || files.isEmpty) {
    return null;
  }

  final String folderName = _folderName(files);
  final Archive archive = Archive();
  for (final WebPickedFile file in files) {
    final String relative = _relativePath(file.relativePath);
    if (relative.isEmpty) {
      continue;
    }
    archive.addFile(ArchiveFile(relative, file.bytes.length, file.bytes));
  }
  final List<int> zipBytes = ZipEncoder().encode(archive);
  final String zipName = '$folderName.zip';

  final http.MultipartRequest request = http.MultipartRequest(
    'POST',
    webUploadUri(upload, token),
  );
  request.fields['mode'] = 'file';
  request.files.add(
    http.MultipartFile.fromBytes('file', zipBytes, filename: zipName),
  );
  final http.StreamedResponse response = await request.send();
  final String body = await response.stream.bytesToString();
  if (response.statusCode != 200) {
    throw StateError('上传文件夹失败（${response.statusCode}）：$body');
  }
  final Map<String, dynamic> data = jsonDecode(body) as Map<String, dynamic>;
  final Object? path = data['path'];
  if (path is! String || path.isEmpty) {
    throw StateError('上传响应缺少文件路径');
  }
  return ChatAttachment(
    name: data['name'] is String ? data['name'] as String : zipName,
    size: zipBytes.length,
    mime: 'application/zip',
    path: path,
  );
}

/// `webkitRelativePath` 第一段就是用户选择的顶层目录名。
String _folderName(List<WebPickedFile> files) {
  for (final WebPickedFile file in files) {
    final List<String> parts = file.relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((String part) => part.isNotEmpty)
        .toList();
    if (parts.isNotEmpty) {
      return parts.first;
    }
  }
  return 'folder';
}

/// 去掉顶层目录名，避免 zip 内出现 `folder/folder/...` 双层前缀。
String _relativePath(String input) {
  final List<String> parts = input
      .replaceAll('\\', '/')
      .split('/')
      .where((String part) => part.isNotEmpty && part != '.' && part != '..')
      .toList();
  if (parts.isEmpty) {
    return '';
  }
  parts.removeAt(0);
  return parts.join('/');
}
