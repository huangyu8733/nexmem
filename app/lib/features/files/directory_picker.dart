import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// 跨平台选择「可发布为 P2P 共享」的本地目录。
///
/// - 移动端：优先使用 CoreSession 注入的平台通道（Android 会把 SAF 目录树
///   复制到应用缓存后回传真实路径），因为 `content://` URI 内核无法直接读取。
/// - 桌面端：使用 `file_picker` 返回绝对路径。
/// - Web 端：优先用注入的上传式目录选择器；没有注入时返回 null，
///   由界面提示改用分享码导入。
Future<String?> pickShareDirectory({
  Future<String?> Function()? platformPicker,
}) async {
  if (kIsWeb) {
    try {
      return await platformPicker?.call();
    } on Object {
      return null;
    }
  }
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      return await platformPicker?.call();
    } catch (_) {
      return null;
    }
  }
  try {
    final Uri? uri = await FilePicker.pickDirectory();
    if (uri == null) return null;
    if (uri.scheme == 'file') return uri.toFilePath();
    final String raw = uri.toString();
    return raw.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(raw) ? raw : null;
  } catch (_) {
    return null;
  }
}
