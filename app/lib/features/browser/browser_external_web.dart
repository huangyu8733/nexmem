// Web 端内置浏览器直接用 iframe，不需要再跳系统浏览器。
Future<bool> openExternalUrlImpl(String url) async => false;
