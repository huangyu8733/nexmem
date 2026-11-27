import 'dart:io';

import 'package:flutter/services.dart';

Future<void> exitProcess() async {
  if (Platform.isAndroid || Platform.isIOS) {
    await SystemNavigator.pop();
    return;
  }
  // 桌面端用户明确点击「退出应用」，直接结束进程。
  exit(0);
}
