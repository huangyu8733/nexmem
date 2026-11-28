/// 非 dart:io 平台的文件夹打包占位实现。
///
/// Web 构建不会调用本函数：Web 分支在 `folder_attachment.dart` 中直接读取
/// 浏览器选择的文件并在内存中打包，再上传到网关临时目录。
library;

import '../chat/chat_message.dart';

Future<ChatAttachment?> pickLocalFolderZip(
  Future<String?> Function()? directoryPicker,
) async {
  throw UnimplementedError('本地目录打包需要 dart:io 平台');
}
