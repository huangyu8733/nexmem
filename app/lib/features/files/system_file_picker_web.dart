/// Web 目录选择器的非 Web 占位实现。
///
/// `system_file_picker.dart` 通过条件导入在 Web 上换成
/// `system_file_picker_web_impl.dart`；测试与桌面构建只会链接到本文件。
library;

class WebPickedFile {
  const WebPickedFile({
    required this.name,
    required this.relativePath,
    required this.bytes,
  });

  final String name;
  final String relativePath;
  final List<int> bytes;
}

Future<List<WebPickedFile>?> pickWebDirectoryFiles() async {
  throw UnimplementedError('目录选择仅在 Web 平台可用');
}
