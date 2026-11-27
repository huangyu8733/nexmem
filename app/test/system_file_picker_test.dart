import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/features/files/system_file_picker.dart';

void main() {
  test('webUploadUri 把 ws 网关地址换算成上传地址', () {
    final Uri uri = webUploadUri(
      Uri.parse('ws://127.0.0.1:8082/ws'),
      'devtoken',
    );
    expect(uri.toString(), 'http://127.0.0.1:8082/upload?token=devtoken');
  });

  test('webUploadUri 在 TLS 网关上使用 https', () {
    final Uri uri = webUploadUri(
      Uri.parse('wss://example.test/ws'),
      'abc',
    );
    expect(uri.toString(), 'https://example.test/upload?token=abc');
  });
}
