/// 桌面 / 移动端的本地文件读取与保存。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<String?> saveLocalFile({
  required String sourcePath,
  required String fileName,
}) async {
  final File source = File(sourcePath);
  if (!await source.exists()) {
    throw StateError('附件源文件已不存在：$sourcePath');
  }
  // file_picker v13 的 saveFile 直接接收字节并写入用户选择的路径，
  // 桌面弹系统保存对话框，Android 走 SAF，不需要先拿到可写绝对路径。
  final Uri? target = await FilePicker.saveFile(
    dialogTitle: '保存到本机',
    fileName: fileName,
    bytes: await source.readAsBytes(),
  );
  if (target == null) {
    return null;
  }
  return target.scheme == 'file' ? target.toFilePath() : target.toString();
}

Future<Uint8List> readLocalFileBytes(String path) => File(path).readAsBytes();
