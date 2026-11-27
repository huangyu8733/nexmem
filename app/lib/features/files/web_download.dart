/// Web 端服务端文件取回：构造鉴权下载链接并触发浏览器保存。
///
/// Web 端内核在网关进程内运行，群文件只能落到服务端路径；浏览器拿不到该
/// 路径，改由本模块把路径交给网关 `/download`（token 鉴权、白名单目录），
/// 用隐藏 `<a download>` 触发浏览器把字节保存到用户本机。
/// 桌面/移动端条件导入到 stub，不会链接浏览器 API。
library;

import 'web_download_web.dart'
    if (dart.library.html) 'web_download_web_impl.dart';

/// 把 WebSocket 端点换算成网关 `/download` 的鉴权 URL。
///
/// 群文件下载路径由内核给出绝对路径，作为 `path` 查询参数；鉴权方式与其他
/// 网关端点一致（`?token=`）。
Uri webDownloadUri(Uri endpoint, String token, String serverPath) =>
    endpoint.replace(
      scheme: endpoint.scheme == 'wss' ? 'https' : 'http',
      path: '/download',
      queryParameters: <String, String>{'token': token, 'path': serverPath},
    );

/// 构造可供 `<video>` / `<audio>` / `<img>` 直接在线加载的鉴权 URL。
///
/// 与 [webDownloadUri] 使用同一个 `/download` 端点与白名单/令牌校验，只是额外
/// 声明 `disposition=inline`，让网关返回 `Content-Disposition: inline` 而不是
/// 触发保存。保留 `http.ServeFile` 的 Range 支持，浏览器可流式播放与拖动进度，
/// 不把整文件读进内存。
Uri webMediaUri(Uri endpoint, String token, String serverPath) {
  final Uri base = webDownloadUri(endpoint, token, serverPath);
  return base.replace(
    queryParameters: <String, String>{
      ...base.queryParameters,
      'disposition': 'inline',
    },
  );
}

/// 触发浏览器把服务端文件保存到本机；非 Web 平台为空实现。
Future<void> downloadThroughBrowser({
  required Uri endpoint,
  required String token,
  required String serverPath,
  required String fileName,
}) async {
  downloadThroughBrowserImpl(
    webDownloadUri(endpoint, token, serverPath),
    fileName,
  );
}
