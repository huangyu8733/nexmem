// iOS 音乐选择器必须在 Info.plist 声明用途，否则 MPMediaPickerController
// 会在 present 时触发系统 TCC 终止进程（表现为点击音乐图标闪退）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS 音乐库用途说明已声明', () {
    final File plist = <File>[
      File('ios/Runner/Info.plist'),
      File('app/ios/Runner/Info.plist'),
    ].firstWhere(
      (File file) => file.existsSync(),
      orElse: () => throw StateError('找不到 iOS Info.plist'),
    );
    final String content = plist.readAsStringSync();
    expect(content, contains('NSAppleMusicUsageDescription'));
    expect(content, isNot(contains('<key>NSAppleMusicUsageDescription</key>\n\t<string></string>')));
  });

  test('音乐库权限被拒时原生层回退到文件选择器', () {
    final File source = <File>[
      File('ios/Runner/NexmemPlugin.swift'),
      File('app/ios/Runner/NexmemPlugin.swift'),
    ].firstWhere(
      (File file) => file.existsSync(),
      orElse: () => throw StateError('找不到 NexmemPlugin.swift'),
    );
    final String content = source.readAsStringSync();
    expect(content, contains('MPMediaLibrary.authorizationStatus()'));
    expect(content, contains('pickMedia(result)'));
  });
}
