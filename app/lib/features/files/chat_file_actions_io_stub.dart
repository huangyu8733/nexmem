/// 非 dart:io 平台（Web）的占位实现。实际逻辑在 chat_file_actions.dart 中
/// 走鉴权下载端点，不会调用这两个函数。
library;

import 'dart:typed_data';

Future<String?> saveLocalFile({
  required String sourcePath,
  required String fileName,
}) async {
  throw UnsupportedError('Web 端请通过鉴权下载保存到本机');
}

Future<Uint8List> readLocalFileBytes(String path) async {
  throw UnsupportedError('Web 端请通过鉴权下载读取文件');
}
