import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;
import 'package:webview_flutter/webview_flutter.dart';

bool get browserViewSupportedImpl => true;

int _browserViewCounter = 0;

Widget buildBrowserViewportImpl({
  Key? key,
  WebViewController? controller,
  required String url,
  required ValueChanged<String> onUrlChanged,
}) {
  return _BrowserIframeView(
    key: key,
    url: url,
    onUrlChanged: onUrlChanged,
  );
}

class _BrowserIframeView extends StatefulWidget {
  const _BrowserIframeView({
    super.key,
    required this.url,
    required this.onUrlChanged,
  });

  final String url;
  final ValueChanged<String> onUrlChanged;

  @override
  State<_BrowserIframeView> createState() => _BrowserIframeViewState();
}

class _BrowserIframeViewState extends State<_BrowserIframeView> {
  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;

  @override
  void initState() {
    super.initState();
    _browserViewCounter++;
    _viewType = 'nexmem-inapp-browser-$_browserViewCounter';
    _iframe = web.HTMLIFrameElement()
      ..src = widget.url
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0';
    // iframe 不走 WebViewController 的 NavigationDelegate，必须自己回执加载完成，
    // 否则顶部进度条永远转、刷新按钮也无法给出任何反馈。
    _iframe.addEventListener(
      'load',
      ((web.Event _) {
        widget.onUrlChanged(widget.url);
      }).toJS,
    );
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _iframe,
    );
  }

  @override
  void didUpdateWidget(covariant _BrowserIframeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && _iframe.src != widget.url) {
      _iframe.src = widget.url;
    }
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(
      key: const ValueKey<String>('browser-iframe'),
      viewType: _viewType,
    );
  }
}
