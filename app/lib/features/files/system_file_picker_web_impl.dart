/// Web 端目录选择器：使用浏览器的 `webkitdirectory` 文件输入框。
///
/// 浏览器只能给出 `File` 对象，不能给出服务端可读的本机路径；这里读取每个
/// 文件的字节与相对路径，交给上层上传到网关临时目录。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class WebPickedFile {
  const WebPickedFile({
    required this.name,
    required this.relativePath,
    required this.bytes,
  });

  final String name;
  final String relativePath;
  final Uint8List bytes;
}

Future<List<WebPickedFile>?> pickWebDirectoryFiles() {
  final Completer<List<WebPickedFile>?> completer =
      Completer<List<WebPickedFile>?>();
  final web.HTMLInputElement input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true
    ..style.display = 'none'
    ..setAttribute('webkitdirectory', '');
  final web.Element host =
      web.document.body ?? web.document.documentElement!;
  host.append(input);

  Future<void> finish(List<WebPickedFile>? files) async {
    if (completer.isCompleted) return;
    input.remove();
    if (files == null) {
      completer.complete(null);
      return;
    }
    completer.complete(files);
  }

  void onCancel(web.Event _) => unawaited(finish(null));
  input.addEventListener('cancel', onCancel.toJS);

  input.addEventListener(
    'change',
    ((web.Event event) async {
      final web.HTMLInputElement target =
          event.target as web.HTMLInputElement;
      final web.FileList? files = target.files;
      if (files == null || files.length == 0) {
        await finish(null);
        return;
      }
      try {
        final List<WebPickedFile> picked = <WebPickedFile>[];
        for (int i = 0; i < files.length; i++) {
          final web.File? file = files.item(i);
          if (file == null) continue;
          final String relative =
              file.webkitRelativePath.isEmpty ? file.name : file.webkitRelativePath;
          picked.add(
            WebPickedFile(
              name: file.name,
              relativePath: relative,
              bytes: await _readBytes(file),
            ),
          );
        }
        await finish(picked.isEmpty ? null : picked);
      } on Object catch (error, stackTrace) {
        if (!completer.isCompleted) {
          input.remove();
          completer.completeError(error, stackTrace);
        }
      }
    }).toJS,
  );

  input.click();
  return completer.future;
}

Future<Uint8List> _readBytes(web.File file) async {
  final Completer<Uint8List> completer = Completer<Uint8List>();
  final web.FileReader reader = web.FileReader();
  reader.addEventListener(
    'loadend',
    ((web.Event _) {
      if (completer.isCompleted) return;
      final JSAny? result = reader.result;
      final JSArrayBuffer? buffer = result != null &&
              result.isA<JSArrayBuffer>()
          ? result as JSArrayBuffer
          : null;
      if (buffer == null) {
        completer.completeError(StateError('读取文件字节失败：${file.name}'));
        return;
      }
      completer.complete(buffer.toDart.asUint8List());
    }).toJS,
  );
  reader.addEventListener(
    'error',
    ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('读取文件失败：${file.name}'));
      }
    }).toJS,
  );
  reader.readAsArrayBuffer(file);
  return completer.future;
}
