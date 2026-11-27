/// Web 端下载触发器：用隐藏 `<a download>` 触发浏览器保存文件。
library;

import 'package:web/web.dart' as web;

void downloadThroughBrowserImpl(Uri url, String fileName) {
  final web.HTMLAnchorElement anchor = web.HTMLAnchorElement()
    ..href = url.toString()
    ..download = fileName
    ..style.display = 'none';
  final web.Element host = web.document.body ?? web.document.documentElement!;
  host.append(anchor);
  anchor.click();
  anchor.remove();
}
