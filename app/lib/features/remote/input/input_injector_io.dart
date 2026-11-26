// 桌面平台选择对应的输入注入器实现。
import 'dart:io';

import 'desktop_input_injector.dart';
import 'input_injector_android.dart';
import 'input_injector_linux.dart';
import 'input_injector_macos.dart';
import 'input_injector_stub.dart';
import 'input_injector_windows.dart';

DesktopInputInjector createDesktopInputInjector() {
  try {
    if (Platform.isMacOS) {
      return MacInputInjector();
    }
    if (Platform.isWindows) {
      return WindowsInputInjector();
    }
    if (Platform.isLinux) {
      return LinuxInputInjector();
    }
    if (Platform.isAndroid) {
      return AndroidInputInjector();
    }
  } on Object {
    return const UnsupportedInputInjector();
  }
  return const UnsupportedInputInjector();
}
