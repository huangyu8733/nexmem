/// 在系统浏览器打开链接；内置浏览器不可用时作为降级出口。
library;

import 'browser_external_stub.dart'
    if (dart.library.io) 'browser_external_io.dart'
    if (dart.library.js_interop) 'browser_external_web.dart';

/// 打开系统浏览器；返回是否成功发起。
Future<bool> openExternalUrl(String url) => openExternalUrlImpl(url);
