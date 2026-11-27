// Android / iOS / 桌面的推送平台实现（非 Web 构建）。
//
// 原生宿主侧需要实现两条通道（见 docs/推送接入指南.md）：
//   MethodChannel 'nexmem/push'：
//     permission / requestPermission -> String（granted|denied|prompt）
//     getToken -> Map<String,String>? {token, platform, env}
//     show -> void {title, body, conversationId}
//     clear -> void {conversationId}
//   EventChannel 'nexmem/push/events'：
//     token -> Map{token,platform,env}；open -> Map{conversationId}
// 宿主未实现时所有调用安全降级为「不支持」，不影响 App 启动。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../settings/settings_service.dart';
import 'push_platform.dart';

class NativePushPlatform implements PushPlatform {
  NativePushPlatform() {
    // 宿主未实现推送通道时，receiveBroadcastStream().listen() 会同步抛
    // MissingPluginException（onError 只处理订阅后的流错误，拦不住激活异常）。
    // 真机启动到此为止会直接让 Flutter 测试框架判失败，必须吞掉并降级。
    if (!_isMobile) return;
    try {
      _eventsSub = _events.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is! Map) return;
          final Object? type = event['type'];
          final Object? conversationId = event['conversationId'];
          if (type == 'open' &&
              conversationId is String &&
              conversationId.isNotEmpty) {
            _open.add(PushOpenTarget(conversationId));
            return;
          }
          if (type == 'token') {
            final Object? token = event['token'];
            final Object? platform = event['platform'];
            if (token is String && token.isNotEmpty) {
              final Object? env = event['env'];
              _tokens.add(PushToken(
                token: token,
                platform:
                    platform is String && platform.isNotEmpty ? platform : 'apns',
                env: env is String && env.isNotEmpty ? env : 'production',
              ));
            }
          }
        },
        onError: (dynamic _) {},
      );
    } on MissingPluginException {
      _available = false;
    } on Object {
      _available = false;
    }
  }

  static const MethodChannel _channel = MethodChannel('nexmem/push');
  static const EventChannel _events = EventChannel('nexmem/push/events');

  final StreamController<PushOpenTarget> _open =
      StreamController<PushOpenTarget>.broadcast();
  final StreamController<PushToken> _tokens =
      StreamController<PushToken>.broadcast();
  StreamSubscription<dynamic>? _eventsSub;

  bool _available = true;

  /// 原生凭证由宿主持有，开发者页改动不影响本平台。
  @override
  Future<void> refreshCredentials() async {}

  @override
  PushCapability get capability => _available && _isMobile
      ? PushCapability.system
      : PushCapability.unsupported;

  @override
  bool get supported => capability != PushCapability.unsupported;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<T?> _call<T>(String method, [Object? args]) async {
    if (!_isMobile) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      _available = false;
      return null;
    } on Object {
      return null;
    }
  }

  @override
  Future<PushPermission> permission() async {
    final String? raw = await _call<String>('permission');
    return PushPermission(raw ?? 'unsupported');
  }

  @override
  Future<PushPermission> requestPermission() async {
    final String? raw = await _call<String>('requestPermission');
    return PushPermission(raw ?? (_isMobile ? 'denied' : 'unsupported'));
  }

  @override
  Future<PushToken?> getToken() async {
    final Map<Object?, Object?>? raw =
        await _call<Map<Object?, Object?>>('getToken');
    if (raw == null) return null;
    final Object? token = raw['token'];
    if (token is! String || token.isEmpty) return null;
    final Object? platform = raw['platform'];
    final Object? env = raw['env'];
    return PushToken(
      token: token,
      platform: platform is String && platform.isNotEmpty ? platform : 'apns',
      env: env is String && env.isNotEmpty ? env : 'production',
    );
  }

  /// 宿主通过 EventChannel 推来的令牌刷新。
  Stream<PushToken> get tokenRefresh => _tokens.stream;

  @override
  Stream<PushOpenTarget> get onOpen => _open.stream;

  @override
  Future<void> show(PushNotice notice) async {
    await _call<void>('show', <String, String>{
      'title': notice.title,
      'body': notice.body,
      'conversationId': notice.conversationId,
    });
  }

  @override
  Future<void> clear(String conversationId) async {
    await _call<void>('clear', <String, String>{'conversationId': conversationId});
  }

  @override
  void dispose() {
    unawaited(_eventsSub?.cancel());
    unawaited(_open.close());
    unawaited(_tokens.close());
  }
}

/// 原生凭证由宿主持有，settings 参数在桌面/移动端不使用。
PushPlatform makePushPlatform({SettingsService? settings}) =>
    NativePushPlatform();
