import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
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

  test('媒体 MIME 按扩展名推断，视频音频都能识别', () {
    expect(videoMimeFor('clip.MOV'), 'video/quicktime');
    expect(videoMimeFor('movie.mp4'), 'video/mp4');
    expect(audioMimeFor('song.mp3'), 'audio/mpeg');
    expect(
      mediaMimeFor(name: 'song.mp3', mime: '  '),
      'audio/mpeg',
    );
    // 选择器已给出 MIME 时不覆盖。
    expect(
      mediaMimeFor(name: 'clip.mp4', mime: 'video/mp4'),
      'video/mp4',
    );
    // 选择器给出通用 MIME 时按扩展名纠正，避免接收端误判为图片/文件。
    expect(
      mediaMimeFor(name: 'clip.mp4', mime: 'application/octet-stream'),
      'video/mp4',
    );
    expect(isVideoAttachment(name: 'clip.mp4'), isTrue);
    expect(isAudioAttachment(name: 'clip.mp4'), isFalse);
    expect(isVideoAttachment(name: 'song.mp3'), isFalse);
    expect(
      isAudioAttachment(name: 'unknown.bin', mime: 'audio/ogg'),
      isTrue,
    );
  });

  test('媒体过滤扩展名覆盖常见视频与音频', () {
    expect(mediaFileExtensions, containsAll(<String>[
      'mp4',
      'mov',
      'mkv',
      'mp3',
      'm4a',
      'wav',
      'flac',
    ]));
  });
}
