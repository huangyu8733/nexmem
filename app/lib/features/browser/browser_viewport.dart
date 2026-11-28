/// 内置浏览器的平台视图：移动端/macOS 用 WebView，Web 用 iframe，其余平台降级。
library;

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'browser_viewport_stub.dart'
    if (dart.library.io) 'browser_viewport_io.dart'
    if (dart.library.html) 'browser_viewport_web.dart';

/// 当前平台是否可直接显示网页内容。
bool get browserViewSupported => browserViewSupportedImpl;

/// 构建平台网页视图。原生端传入 [controller]，Web 端只用 [url]。
Widget buildBrowserViewport({
  Key? key,
  WebViewController? controller,
  required String url,
  required ValueChanged<String> onUrlChanged,
}) {
  return buildBrowserViewportImpl(
    key: key,
    controller: controller,
    url: url,
    onUrlChanged: onUrlChanged,
  );
}
