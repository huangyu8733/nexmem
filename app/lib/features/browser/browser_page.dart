/// 应用内浏览器：地址栏 + 前进/后退/刷新 + 平台网页视图。
///
/// 支持 Android / iOS / macOS 的 WebView 与 Web 端 iframe；Windows / Linux
/// 暂未接入原生 WebView，降级为提示 + 系统浏览器打开 + 复制网址。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import 'browser_external.dart';
import 'browser_url.dart';
import 'browser_viewport.dart';

/// 默认首页使用国内可访问的导航站，避免首次打开空白页。
const String kBrowserHomeUrl = 'https://www.baidu.com';

/// 在应用内打开网址。非 http(s) 内容会被忽略。
Future<void> openInAppBrowser(BuildContext context, String url) {
  final String? normalized = normalizeWebUrl(url);
  if (normalized == null) {
    return Future<void>.value();
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => BrowserPage(initialUrl: normalized),
    ),
  );
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    this.initialUrl = kBrowserHomeUrl,
  });

  final String initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late final TextEditingController _address;
  late String _url;
  WebViewController? _controller;
  bool _canBack = false;
  bool _canForward = false;
  bool _loading = false;

  /// Web 端 iframe 不走 WebViewController，地址栏历史由本页维护。
  final List<String> _webHistory = <String>[];
  int _webHistoryIndex = -1;
  int _webReloadNonce = 0;

  bool get _usesIframe => kIsWeb && browserViewSupported;
  bool get _canRenderWeb =>
      browserViewSupported && (_usesIframe || _controller != null);

  @override
  void initState() {
    super.initState();
    _url = normalizeWebUrl(widget.initialUrl) ?? kBrowserHomeUrl;
    _address = TextEditingController(text: _url);
    if (_usesIframe) {
      _webHistory.add(_url);
      _webHistoryIndex = 0;
    }
    if (browserViewSupported && !kIsWeb) {
      try {
        _controller = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.white)
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageStarted: (String url) => _setUrl(url, loading: true),
              onPageFinished: (String url) => _setUrl(url, loading: false),
              onWebResourceError: (WebResourceError _) {
                if (mounted) {
                  setState(() => _loading = false);
                }
              },
            ),
          );
        unawaited(_controller!.loadRequest(Uri.parse(_url)));
      } on Object {
        // 单元测试或未注册平台实现时安全降级为提示页。
        _controller = null;
      }
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _setUrl(String url, {required bool loading}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _url = url;
      _address.text = url;
      _loading = loading;
    });
    unawaited(_syncNavigation());
  }

  Future<void> _syncNavigation() async {
    if (_usesIframe) {
      if (!mounted) {
        return;
      }
      setState(() {
        _canBack = _webHistoryIndex > 0;
        _canForward = _webHistoryIndex >= 0 &&
            _webHistoryIndex < _webHistory.length - 1;
      });
      return;
    }
    final WebViewController? controller = _controller;
    if (controller == null) {
      return;
    }
    final bool back = await controller.canGoBack();
    final bool forward = await controller.canGoForward();
    if (!mounted) {
      return;
    }
    setState(() {
      _canBack = back;
      _canForward = forward;
    });
  }

  Future<void> _load(Uri uri) async {
    final String url = uri.toString();
    setState(() {
      _url = url;
      _address.text = url;
      _loading = _canRenderWeb;
    });
    if (_usesIframe) {
      if (_webHistoryIndex < 0 ||
          _webHistory[_webHistoryIndex] != url) {
        if (_webHistoryIndex < _webHistory.length - 1) {
          _webHistory.removeRange(_webHistoryIndex + 1, _webHistory.length);
        }
        _webHistory.add(url);
        _webHistoryIndex = _webHistory.length - 1;
      }
      await _syncNavigation();
      return;
    }
    final WebViewController? controller = _controller;
    if (controller != null) {
      await controller.loadRequest(uri);
      await _syncNavigation();
    }
  }

  Future<void> _submit() async {
    final String? url = normalizeWebUrl(_address.text);
    if (url == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.t('网址无效，请输入 http 或 https 地址')),
        ),
      );
      return;
    }
    await _load(Uri.parse(url));
  }

  Future<void> _applyWebHistory(int index) async {
    if (index < 0 || index >= _webHistory.length) {
      return;
    }
    _webHistoryIndex = index;
    final String url = _webHistory[index];
    setState(() {
      _url = url;
      _address.text = url;
      _loading = true;
    });
    await _syncNavigation();
  }

  Future<void> _back() async {
    if (_usesIframe) {
      await _applyWebHistory(_webHistoryIndex - 1);
      return;
    }
    final WebViewController? controller = _controller;
    if (controller == null || !_canBack) {
      return;
    }
    await controller.goBack();
    await _syncNavigation();
  }

  Future<void> _forward() async {
    if (_usesIframe) {
      await _applyWebHistory(_webHistoryIndex + 1);
      return;
    }
    final WebViewController? controller = _controller;
    if (controller == null || !_canForward) {
      return;
    }
    await controller.goForward();
    await _syncNavigation();
  }

  Future<void> _reload() async {
    if (_usesIframe) {
      setState(() {
        _webReloadNonce++;
        _loading = true;
      });
      return;
    }
    await _controller?.reload();
  }

  Future<void> _copyUrl() async {
    await Clipboard.setData(ClipboardData(text: _url));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t('已复制'))),
    );
  }

  Widget _unsupportedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.public_off, size: 56),
            const SizedBox(height: 12),
            Text(
              context.t('当前平台暂不支持内置网页视图'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SelectableText(
              _url,
              key: const ValueKey<String>('browser-unsupported-url'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey<String>('browser-open-external'),
              icon: const Icon(Icons.open_in_new),
              label: Text(context.t('在系统浏览器打开')),
              onPressed: () => unawaited(openExternalUrl(_url)),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: Text(context.t('复制')),
              onPressed: () => unawaited(_copyUrl()),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _appBarActions(BoxConstraints constraints) {
    final List<Widget> actions = <Widget>[
      IconButton(
        key: const ValueKey<String>('browser-back'),
        tooltip: context.t('返回'),
        icon: const Icon(Icons.arrow_back),
        onPressed: _canBack ? () => unawaited(_back()) : null,
      ),
    ];
    // 320–390px 窄屏保留地址栏宽度，把前进/刷新收起。
    if (constraints.maxWidth < 420) {
      return actions;
    }
    actions.addAll(<Widget>[
      IconButton(
        key: const ValueKey<String>('browser-forward'),
        tooltip: context.t('前进'),
        icon: const Icon(Icons.arrow_forward),
        onPressed: _canForward ? () => unawaited(_forward()) : null,
      ),
      IconButton(
        key: const ValueKey<String>('browser-reload'),
        tooltip: context.t('刷新'),
        icon: const Icon(Icons.refresh),
        onPressed: () => unawaited(_reload()),
      ),
    ]);
    return actions;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      // Android 系统返回键优先回退网页历史；Web 端交给浏览器自身历史。
      canPop: kIsWeb || !_canBack,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        unawaited(_back());
      },
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) => Scaffold(
      key: const ValueKey<String>('browser-page'),
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey<String>('browser-close'),
          tooltip: context.t('关闭'),
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: TextField(
          key: const ValueKey<String>('browser-address'),
          controller: _address,
          decoration: InputDecoration(
            hintText: context.t('网址'),
            prefixIcon: const Icon(Icons.public, size: 18),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (_) => unawaited(_submit()),
        ),
        actions: _appBarActions(constraints),
      ),
      body: Column(
        children: <Widget>[
          if (_loading)
            const LinearProgressIndicator(
              minHeight: 2,
              key: ValueKey<String>('browser-progress'),
            ),
          Expanded(
            child: _canRenderWeb
                ? buildBrowserViewport(
                    key: ValueKey<String>('browser-view-$_webReloadNonce'),
                    controller: _controller,
                    url: _url,
                    onUrlChanged: (String url) => _setUrl(url, loading: false),
                  )
                : _unsupportedView(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        key: const ValueKey<String>('browser-go'),
        tooltip: context.t('打开'),
        onPressed: () => unawaited(_submit()),
        child: const Icon(Icons.arrow_forward),
      ),
      ),
      ),
    );
  }
}
