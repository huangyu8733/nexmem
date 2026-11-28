import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// webview_flutter 4.x 同时支持 Android / iOS / macOS；Windows / Linux 走降级页。
bool get browserViewSupportedImpl =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

Widget buildBrowserViewportImpl({
  Key? key,
  WebViewController? controller,
  required String url,
  required ValueChanged<String> onUrlChanged,
}) {
  final WebViewController? view = controller;
  if (view == null) {
    return const SizedBox.shrink();
  }
  return WebViewWidget(
    key: key ?? const ValueKey<String>('browser-webview'),
    controller: view,
  );
}
