import 'dart:io';

import 'package:flutter/services.dart';

import 'browser_url.dart';

Future<bool> openExternalUrlImpl(String url) async {
  final String target = normalizeWebUrl(url) ?? url;
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', <String>['/c', 'start', '', target]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[target]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[target]);
    } else if (Platform.isAndroid) {
      const MethodChannel channel = MethodChannel('io.nexmem/core');
      await channel.invokeMethod<void>(
        'openUrl',
        <String, dynamic>{'url': target},
      );
    } else {
      return false;
    }
    return true;
  } on Object {
    return false;
  }
}
