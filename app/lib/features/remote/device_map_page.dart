// 设备地图：按合规要求默认使用腾讯地图 GL JS。
//
// 桌面端 WebView 插件不可用，因此这里做分级降级：
//   * Android / iOS / Web：WebView 加载腾讯地图 GL JS，按设备坐标聚合标注；
//   * macOS / Windows / Linux：列出已标注设备，并可填写用户自备的腾讯地图 Key。
// 经纬度由用户在设备台账中手动标注，采用 GCJ-02；内核不做 IP 归属查询。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/pane_header.dart';
import '../../l10n/l10n.dart';
import '../settings/settings_service.dart';
import 'remote_device_directory.dart';

/// 腾讯地图 JavaScript GL Key 的本机设置键。Key 只保存在本机 KV，不随代码分发。
const String deviceMapTencentKeySetting = 'device.map_tencent_key';

class DeviceMapPage extends StatefulWidget {
  const DeviceMapPage({
    super.key,
    required this.devices,
    required this.settings,
    this.embedded = true,
  });

  final List<RemoteDevice> devices;
  final SettingsService settings;
  final bool embedded;

  @override
  State<DeviceMapPage> createState() => _DeviceMapPageState();
}

class _DeviceMapPageState extends State<DeviceMapPage> {
  String? _key;
  bool _loading = true;
  WebViewController? _controller;

  List<RemoteDevice> get _located =>
      widget.devices.where((RemoteDevice device) => device.hasLocation).toList();

  bool get _webViewSupported {
    if (kIsWeb) {
      return true;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadKey());
  }

  Future<void> _loadKey() async {
    String? key;
    try {
      key = await widget.settings.read(deviceMapTencentKeySetting);
    } on Object {
      key = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _key = (key ?? '').trim().isEmpty ? null : key!.trim();
      _loading = false;
      if (_key != null && _webViewSupported) {
        _controller = _makeController();
      }
    });
  }

  WebViewController _makeController() {
    final WebViewController controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setUserAgent('Nexmem/1.1 (DeviceMap)');
    unawaited(controller.loadHtmlString(
      buildDeviceMapHtml(
        devices: _located,
        key: _key ?? '',
        useWorkBuddyProxy: false,
        l10n: context.l10n,
      ),
      baseUrl: 'https://map.qq.com/',
    ));
    return controller;
  }

  Future<void> _editKey() async {
    final TextEditingController input =
        TextEditingController(text: _key ?? '');
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('设置腾讯地图 Key')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                context.t(
                  '请到腾讯位置服务控制台申请 JavaScript GL 类型的 Key，并配置域名白名单。Key 仅保存在本机。',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('device-map-key'),
                controller: input,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.t('腾讯地图 Key'),
                  hintText: context.t('留空则清除'),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('device-map-key-save'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.t('保存')),
          ),
        ],
      ),
    );
    if (saved != true) {
      return;
    }
    final String key = input.text.trim();
    input.dispose();
    try {
      await widget.settings.write(deviceMapTencentKeySetting, key);
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t('保存失败：{0}', [e]))),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _key = key.isEmpty ? null : key;
      _controller = _key != null && _webViewSupported ? _makeController() : null;
    });
  }

  Widget _buildKeyPrompt(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.map_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  context.t('设备地图使用腾讯地图'),
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _webViewSupported
                  ? context.t(
                      '请填写自己的腾讯地图 JavaScript GL Key；代码不会内置任何可用 Key。',
                    )
                  : context.t(
                      '当前平台不支持内嵌地图，可填写 Key 后查看设备坐标；桌面预览请在浏览器中打开腾讯地图页面。',
                    ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(
                key: const ValueKey<String>('device-map-key-button'),
                onPressed: () => unawaited(_editKey()),
                child: Text(context.t(_key == null ? '填写腾讯地图 Key' : '更换腾讯地图 Key')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocatedList(ThemeData theme) {
    if (_located.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(
            children: <Widget>[
              Icon(Icons.place_outlined, size: 48, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                context.t('还没有标注位置的设备，可在编辑设备时填写地区与经纬度'),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey<String>('device-map-list'),
      itemCount: _located.length,
      itemBuilder: (BuildContext context, int index) {
        final RemoteDevice device = _located[index];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.place_outlined),
            title: Text(device.name),
            subtitle: Text(
              <String>[
                device.region,
                device.latitude!.toStringAsFixed(5),
                device.longitude!.toStringAsFixed(5),
              ].where((String s) => s.isNotEmpty).join(' · '),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final Widget list = _buildLocatedList(theme);
    if (!_webViewSupported || _key == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _buildKeyPrompt(theme),
          ),
          Expanded(child: list),
        ],
      );
    }
    final WebViewController controller = _controller ??= _makeController();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  context.t('已标注 {0} 台设备 · 密集点自动聚合', [_located.length]),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => unawaited(_editKey()),
                icon: const Icon(Icons.key_outlined, size: 16),
                label: Text(context.t('更换 Key')),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: WebViewWidget(controller: controller),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget body = _buildBody(theme);
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(title: Text(context.t('设备地图'))),
        body: body,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(title: context.t('设备地图')),
        Expanded(child: body),
      ],
    );
  }
}

/// 生成腾讯地图 GL JS 页面。
///
/// [useWorkBuddyProxy] 为 WorkBuddy 预览场景：不写 key，改用本地代理占位，
/// 占位符由 WorkBuddy 运行时替换；独立 App 场景必须传 false 并让用户自备 Key。
String buildDeviceMapHtml({
  required List<RemoteDevice> devices,
  required String key,
  bool useWorkBuddyProxy = false,
  AppLocalizations? l10n,
}) {
  final String tipText = l10n?.t('点按标注查看设备；缩放时密集点会自动聚合。') ??
      '点按标注查看设备；缩放时密集点会自动聚合。';
  final String emptyTip = l10n?.t('还没有标注位置的设备。') ?? '还没有标注位置的设备。';
  final String tipHtml = tipText
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final String emptyTipJs = jsonEncode(emptyTip);
  final List<Map<String, dynamic>> points = devices
      .where((RemoteDevice d) => d.hasLocation)
      .map((RemoteDevice d) => <String, dynamic>{
            'id': d.peer,
            'name': d.name,
            'lat': d.latitude,
            'lng': d.longitude,
            'region': d.region,
          })
      .toList();
  final String payload = jsonEncode(points).replaceAll('<', r'\u003c');
  final String sdkUrl = useWorkBuddyProxy
      ? 'https://map.qq.com/api/gljs?v=1.exp'
      : 'https://map.qq.com/api/gljs?v=1.exp&key=${Uri.encodeComponent(key)}';
  final String proxyConfig = useWorkBuddyProxy
      ? '''
        window._TMapSecurityConfig = {
          serviceHost: 'http://127.0.0.1:__WB_HTTP_PORT__/_TMapService/_wbt/__WB_TMAP_SECRET__',
        };
      '''
      : '';

  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Nexmem 设备地图</title>
<style>
  html, body { margin: 0; padding: 0; height: 100%; font-family: system-ui, sans-serif; }
  #map { width: 100%; height: 100vh; }
  #tip {
    position: fixed; left: 12px; top: 12px; z-index: 999;
    max-width: 70vw; padding: 8px 12px; border-radius: 8px;
    background: rgba(255,255,255,.94); color: #1f2937; font-size: 13px;
    box-shadow: 0 2px 12px rgba(0,0,0,.12);
  }
</style>
$proxyConfig
<script src="$sdkUrl"></script>
</head>
<body>
<div id="tip">$tipHtml</div>
<div id="map"></div>
<script>
(function () {
  var devices = $payload;
  if (!devices.length) {
    document.getElementById('tip').textContent = $emptyTipJs;
    return;
  }
  var center = devices.reduce(function (acc, d) {
    acc.lat += d.lat; acc.lng += d.lng; return acc;
  }, {lat: 0, lng: 0});
  center.lat /= devices.length;
  center.lng /= devices.length;

  // 不传 mapStyleId，使用默认矢量底图，避免默认 Key 不支持自定义样式。
  var map = new TMap.Map('map', {
    zoom: devices.length > 1 ? 5 : 12,
    center: new TMap.LatLng(center.lat, center.lng),
  });

  function markerSvg(text, color) {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48">' +
      '<path fill="' + color + '" d="M24 2C13.5 2 5 10.5 5 21c0 14 19 25 19 25s19-11 19-25C43 10.5 34.5 2 24 2z"/>' +
      '<circle cx="24" cy="21" r="12" fill="white" opacity=".92"/>' +
      '<text x="24" y="26" text-anchor="middle" font-size="11" font-weight="700" fill="' + color + '">' + text + '</text></svg>';
    return 'data:image/svg+xml,' + encodeURIComponent(svg);
  }

  var markerLayer = null;
  function renderMarkers() {
    if (markerLayer) { markerLayer.setMap(null); }
    var zoom = map.getZoom();
    var step = zoom < 8 ? 4 : zoom < 11 ? 1 : zoom < 13 ? 0.2 : zoom < 15 ? 0.05 : 0.01;
    var groups = {};
    devices.forEach(function (d) {
      var key = Math.round(d.lat / step) + ':' + Math.round(d.lng / step);
      if (!groups[key]) { groups[key] = []; }
      groups[key].push(d);
    });
    var geometries = [];
    var styles = {};
    Object.keys(groups).forEach(function (key, index) {
      var group = groups[key];
      var clustered = group.length > 1 && zoom < 15;
      var styleId = 's' + index;
      styles[styleId] = new TMap.MarkerStyle({
        width: clustered ? 40 : 32,
        height: clustered ? 40 : 32,
        anchor: { x: clustered ? 20 : 16, y: clustered ? 40 : 32 },
        src: markerSvg(clustered ? String(group.length) : '•', clustered ? '#d97706' : '#2563eb'),
      });
      geometries.push({
        id: key,
        styleId: styleId,
        position: new TMap.LatLng(group[0].lat, group[0].lng),
      });
      if (group.length === 1) {
        geometries[geometries.length - 1].name = group[0].name;
      }
    });
    markerLayer = new TMap.MultiMarker({ map: map, styles: styles, geometries: geometries });
    markerLayer.on('click', function (evt) {
      var hit = evt && evt.geometry;
      if (!hit) { return; }
      var group = groups[hit.id];
      if (!group) { return; }
      if (group.length === 1) {
        document.getElementById('tip').textContent =
          group[0].name + (group[0].region ? ' · ' + group[0].region : '') +
          ' · ' + group[0].lat.toFixed(5) + ', ' + group[0].lng.toFixed(5);
      } else {
        map.setCenter(new TMap.LatLng(group[0].lat, group[0].lng));
        map.setZoom(Math.min(17, map.getZoom() + 2));
      }
    });
  }

  renderMarkers();
  map.on('zoomend', renderMarkers);
  map.on('dragend', renderMarkers);
})();
</script>
</body>
</html>
''';
}
