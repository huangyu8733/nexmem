// 无原生能力的平台（Web 等）：所有输入事件直接忽略。
import 'package:flutter/services.dart';

import '../remote_input_codec.dart';
import '../remote_session.dart';
import 'desktop_input_injector.dart';

class UnsupportedInputInjector implements DesktopInputInjector {
  const UnsupportedInputInjector();

  @override
  bool get supportsInput => false;

  @override
  String get permissionHint => '当前平台不支持远程控制输入';

  @override
  Future<InputPermissionStatus> checkPermissions() async =>
      InputPermissionStatus.unsupported;

  @override
  Future<InputPermissionStatus> requestPermissions() async =>
      InputPermissionStatus.unsupported;

  @override
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  }) async {}

  @override
  Future<void> key(String key, {required bool down, int modifiers = 0}) async {}

  @override
  TargetPlatform get hostPlatform => TargetPlatform.windows;

  @override
  Future<void> combo(String comboKey, {int modifiers = 0}) async {}

  @override
  Future<void> touch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  }) async {}

  @override
  Future<void> text(String text) async => throw UnsupportedError('不支持文本注入');

  @override
  Future<void> dispose() async {}
}

DesktopInputInjector createDesktopInputInjector() =>
    const UnsupportedInputInjector();
