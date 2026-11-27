// Web 推送平台实现：浏览器 Notification（无凭证）+ 可选 Web Push（VAPID）。
//
// VAPID 公钥来源优先级：开发者页写入本机设置 > 构建期
//   --dart-define=NEXMEM_WEB_VAPID_PUBLIC_KEY=<base64url 公钥>
// 未配置时只启用浏览器本地通知（页面打开时），不请求 Push 订阅，功能不报错。
// 更换公钥会退订旧订阅重新订阅；私钥始终只在服务端，不进入客户端。
// Service Worker（web/sw.js）负责后台到达时的 showNotification 与点击回传。

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../settings/settings_service.dart';
import 'push_platform.dart';

const String _kBuildTimeVapidKey =
    String.fromEnvironment('NEXMEM_WEB_VAPID_PUBLIC_KEY');

class WebPushPlatform implements PushPlatform {
  WebPushPlatform({this.settings}) {
    _vapidKey = _kBuildTimeVapidKey;
    _installMessageListener();
    if (settings != null) {
      unawaited(loadCredentials());
    }
  }

  final SettingsService? settings;

  /// 当前生效的公钥；构建期值作为兜底，运行时可被开发者页覆盖。
  String _vapidKey = '';

  /// 上次订阅使用的公钥；变化时强制退订重订。
  String _subscribedWithKey = '';

  /// 从本机设置读取开发者页填写的公钥；留空则恢复构建期值。
  Future<void> loadCredentials() async {
    String? stored;
    final SettingsService? service = settings;
    if (service != null) {
      try {
        stored = await service.read(kVapidPublicKeySetting);
      } on Object {
        stored = null;
      }
    }
    final String key = (stored ?? '').trim();
    _vapidKey = key.isEmpty ? _kBuildTimeVapidKey : key;
  }

  @override
  Future<void> refreshCredentials() async {
    await loadCredentials();
    // 即使公钥文本相同也重读一次订阅，避免服务端换密钥后客户端仍用旧订阅。
    _subscribedWithKey = '';
  }

  final StreamController<PushOpenTarget> _open =
      StreamController<PushOpenTarget>.broadcast();

  web.ServiceWorkerRegistration? _registration;
  bool _swChecked = false;

  @override
  PushCapability get capability => PushCapability.browser;

  @override
  bool get supported => true;

  bool get _hasVapid => _vapidKey.isNotEmpty;

  Future<web.ServiceWorkerRegistration?> _ensureRegistration() async {
    if (_swChecked) return _registration;
    _swChecked = true;
    try {
      final web.ServiceWorkerContainer container =
          web.window.navigator.serviceWorker;
      _registration = await container.register('/sw.js'.toJS).toDart;
      await container.ready.toDart;
    } on Object {
      _registration = null;
    }
    return _registration;
  }

  void _installMessageListener() {
    try {
      web.window.addEventListener(
        'message',
        ((web.MessageEvent event) {
          final JSAny? raw = event.data;
          if (raw == null) return;
          final String? json = switch (raw) {
            JSString(:final String toDart) => toDart,
            _ => null,
          };
          if (json == null) return;
          try {
            final Map<String, dynamic> data =
                jsonDecode(json) as Map<String, dynamic>;
            final Object? id = data['conversationId'];
            if (data['type'] == 'open' && id is String && id.isNotEmpty) {
              _open.add(PushOpenTarget(id));
            }
          } on Object {
            // 忽略第三方页面 postMessage。
          }
        }).toJS,
      );
    } on Object {
      // 测试环境无 window 时降级。
    }
  }

  @override
  Future<PushPermission> permission() async {
    try {
      return PushPermission(web.Notification.permission);
    } on Object {
      return const PushPermission('denied');
    }
  }

  @override
  Future<PushPermission> requestPermission() async {
    try {
      final JSString result = await web.Notification.requestPermission().toDart;
      return PushPermission(result.toDart);
    } on Object {
      return const PushPermission('denied');
    }
  }

  @override
  Future<PushToken?> getToken() async {
    if (!_hasVapid) return null;
    if (!(await permission()).granted) return null;
    final web.ServiceWorkerRegistration? registration =
        await _ensureRegistration();
    if (registration == null) return null;
    try {
      web.PushSubscription? existing =
          await registration.pushManager.getSubscription().toDart;
      // 开发者页换公钥后旧订阅已失效：退订重订，避免 token 指向旧密钥。
      if (existing != null && _subscribedWithKey != _vapidKey) {
        await existing.unsubscribe().toDart;
        existing = null;
      }
      final web.PushSubscription sub = existing ??
          await registration.pushManager
              .subscribe(web.PushSubscriptionOptionsInit(
                userVisibleOnly: true,
                applicationServerKey: _vapidKeyBytes().toJS,
              ))
              .toDart;
      _subscribedWithKey = _vapidKey;
      final web.PushSubscriptionJSON json = sub.toJSON();
      // 服务端只需要 endpoint；keys 一并带上便于后续扩展加密载荷。
      final Map<String, dynamic> payload = <String, dynamic>{
        'endpoint': json.endpoint,
      };
      final String encoded = base64Url.encode(utf8.encode(jsonEncode(payload)));
      return PushToken(token: encoded, platform: 'web', env: 'production');
    } on Object {
      return null;
    }
  }

  Uint8List _vapidKeyBytes() => base64Url.decode(_vapidKey);

  @override
  Stream<PushOpenTarget> get onOpen => _open.stream;

  @override
  Future<void> show(PushNotice notice) async {
    if (!(await permission()).granted) return;
    try {
      final web.NotificationOptions options = web.NotificationOptions(
        body: notice.body,
        tag: 'nexmem-${notice.conversationId}',
      );
      final web.Notification notification =
          web.Notification(notice.title, options);
      notification.addEventListener(
        'click',
        ((web.Event _) {
          notification.close();
          web.window.focus();
          _open.add(PushOpenTarget(notice.conversationId));
        }).toJS,
      );
    } on Object {
      // 浏览器不支持通知时静默降级，消息本身仍会落到会话里。
    }
  }

  @override
  Future<void> clear(String conversationId) async {
    // Web Notification 无法按 tag 批量关闭；点击 handler 自己 close。
  }

  @override
  void dispose() {
    unawaited(_open.close());
  }
}

PushPlatform makePushPlatform({SettingsService? settings}) =>
    WebPushPlatform(settings: settings);
