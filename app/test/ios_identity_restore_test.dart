// iOS 卸载会清空沙盒；账号身份必须从 Keychain 恢复，否则内核会生成新账号。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS 内核在启动前恢复 Keychain 中的账号身份', () {
    final File source = <File>[
      File('ios/Runner/NexmemCore.swift'),
      File('app/ios/Runner/NexmemCore.swift'),
    ].firstWhere(
      (File file) => file.existsSync(),
      orElse: () => throw StateError('找不到 NexmemCore.swift'),
    );
    final String content = source.readAsStringSync();

    expect(content, contains('identity.sealed.map'));
    expect(content, contains('account.session'));
    expect(content, contains('restoreIdentityFromKeychain()'));
    expect(content, contains('backupIdentityToKeychain()'));
    // 必须在插件初始化时恢复，早于 Dart 读账号档案与 core.start。
    expect(
      content.indexOf('restoreIdentityFromKeychain()'),
      lessThan(content.indexOf('func call(_ request: String)')),
    );
  });
}
