/// 聊天附件的通用读取与「保存到本机」动作。
///
/// - 桌面 / 移动：直接读本机绝对路径；保存时用系统文件选择器让用户指定
///   目标位置，再把内核已落盘的文件复制过去。
/// - Web：内核在网关进程内，文件只有服务端路径；通过鉴权 `/download` 读
///   取字节（文本 / 压缩包预览）或触发浏览器下载（保存到本机）。
library;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../files/web_download.dart';
import 'chat_file_actions_io_stub.dart'
    if (dart.library.io) 'chat_file_actions_io_impl.dart';

/// 把内核已落盘的附件保存到用户设备，返回可展示的保存位置。
///
/// Web 端返回文件名即可：浏览器自己决定下载目录，前端拿不到绝对路径。
Future<String?> saveChatFileToDevice({
  required String sourcePath,
  required String fileName,
  Uri? endpoint,
  String token = '',
  Future<void> Function(String, String)? downloadToBrowser,
}) async {
  if (sourcePath.trim().isEmpty) {
    throw StateError('附件没有可用的文件路径');
  }
  if (kIsWeb) {
    final Uri? gateway = endpoint;
    final Future<void> Function(String, String)? toBrowser = downloadToBrowser;
    if (gateway == null || toBrowser == null) {
      throw StateError('Web 端缺少网关下载通道');
    }
    await toBrowser(sourcePath, fileName);
    return fileName;
  }
  return saveLocalFile(sourcePath: sourcePath, fileName: fileName);
}

/// 读取附件字节，用于文本 / 压缩包等内联预览。
Future<Uint8List> readChatFileBytes({
  required String path,
  Uri? endpoint,
  String token = '',
}) async {
  if (path.trim().isEmpty) {
    throw StateError('附件没有可用的文件路径');
  }
  if (kIsWeb) {
    final Uri? gateway = endpoint;
    if (gateway == null) {
      throw StateError('Web 端缺少网关下载通道');
    }
    final http.Response response = await http.get(
      webDownloadUri(gateway, token, path),
    );
    if (response.statusCode != 200) {
      throw StateError('读取文件失败（${response.statusCode}）');
    }
    return response.bodyBytes;
  }
  return readLocalFileBytes(path);
}

/// 常见纯文本 / 代码文件：可以直接按 UTF-8 展示，不需要外部程序。
bool isTextPreviewable(String name, String mime) {
  final String lower = name.toLowerCase();
  if (mime.startsWith('text/') ||
      mime == 'application/json' ||
      mime == 'application/xml' ||
      mime == 'application/javascript') {
    return true;
  }
  const Set<String> extensions = <String>{
    'txt', 'md', 'markdown', 'json', 'jsonl', 'xml', 'yaml', 'yml', 'csv',
    'tsv', 'log', 'ini', 'conf', 'cfg', 'toml', 'env', 'properties',
    'js', 'jsx', 'ts', 'tsx', 'dart', 'py', 'java', 'go', 'c', 'h', 'cc',
    'cpp', 'hpp', 'cs', 'php', 'rb', 'sh', 'bash', 'zsh', 'sql', 'html',
    'htm', 'css', 'scss', 'vue', 'kt', 'kts', 'swift', 'rs', 'lua', 'pl',
    'r', 'gradle', 'dockerfile', 'gitignore', 'makefile',
  };
  final int dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) {
    return false;
  }
  return extensions.contains(lower.substring(dot + 1));
}

/// 可列出内部条目的归档文件。
bool isArchivePreviewable(String name) {
  final String lower = name.toLowerCase();
  return lower.endsWith('.zip') || lower.endsWith('.tar');
}
