/// Web 下载触发器的非 Web 占位实现。
///
/// `web_download.dart` 通过条件导入在 Web 上换成 `web_download_web_impl.dart`；
/// 测试与桌面构建只会链接到本文件。
library;

void downloadThroughBrowserImpl(Uri url, String fileName) {
  // 非 Web 平台文件已由内核直接落盘到本机，无需浏览器下载。
}
