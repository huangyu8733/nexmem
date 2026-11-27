// 推送平台抽象：把「系统通知栏 / 浏览器通知」与业务层解耦。
//
// 原生平台（Android / iOS）的设备令牌由宿主 App 获取（FCM / APNs），
// 通过 MethodChannel 暴露；二次开发者填入凭证并实现宿主侧通道即可启用。
// 桌面端没有系统推送通道，返回「不支持」并让设置页显示说明。
// Web 端用浏览器 Notification API + Service Worker，不依赖任何第三方凭证；
// 真正的后台 Web Push 需要 VAPID 公钥（构建期 dart-define 或开发者页填写），
// 未配置时只保留前台/页面可见时的本地通知。

import 'dart:async';

import '../settings/settings_service.dart';
import 'push_platform_io.dart'
    if (dart.library.js_interop) 'push_platform_web.dart' as impl;

/// Web Push VAPID 公钥的本机设置键（公钥可公开，私钥只在服务端配置）。
const String kVapidPublicKeySetting = 'developer.vapid_public_key';

/// 平台通知能力。
enum PushCapability {
  /// 原生系统通知（Android / iOS）。
  system,

  /// 浏览器通知（Web）。
  browser,

  /// 无系统通知通道（桌面端 / 宿主未实现）。
  unsupported,
}

/// 平台给出的推送令牌。
class PushToken {
  const PushToken({
    required this.token,
    required this.platform,
    required this.env,
  });

  /// 原始令牌；Web 为 base64url(PushSubscription JSON)。
  final String token;

  /// apns / fcm / web；用于服务端路由。
  final String platform;

  /// production / sandbox。
  final String env;

  /// 上报给内核的带前缀令牌。
  String get wiredToken => '$platform:$token';
}

/// 平台返回的权限状态：granted / denied / prompt / unsupported。
class PushPermission {
  const PushPermission(this.raw);

  final String raw;

  bool get granted => raw == 'granted';
  bool get denied => raw == 'denied';
  bool get prompt => raw == 'prompt' || raw == 'unsupported';
}

/// 用户点击通知后要打开的会话。
class PushOpenTarget {
  const PushOpenTarget(this.conversationId);

  final String conversationId;
}

/// 一条待展示的本地通知。
class PushNotice {
  const PushNotice({
    required this.title,
    required this.body,
    required this.conversationId,
  });

  final String title;
  final String body;
  final String conversationId;
}

/// 平台适配器接口。所有方法在宿主未接线时都必须安全降级，不抛到 UI。
abstract class PushPlatform {
  PushCapability get capability;

  bool get supported => capability != PushCapability.unsupported;

  Future<PushPermission> permission();

  Future<PushPermission> requestPermission();

  /// 获取或刷新令牌；宿主未配置凭证时返回 null。
  Future<PushToken?> getToken();

  /// 用户点击系统/浏览器通知。
  Stream<PushOpenTarget> get onOpen;

  /// 展示一条本地通知（应用在前台、但会话未打开时使用）。
  Future<void> show(PushNotice notice);

  /// 关闭与当前会话相关的通知。
  Future<void> clear(String conversationId);

  /// 开发者页改完凭证后重新读取；默认无操作，只有 Web 需要换订阅。
  Future<void> refreshCredentials() async {}

  void dispose();
}

/// 由条件导入选择具体平台实现。
PushPlatform makePushPlatform({SettingsService? settings}) =>
    impl.makePushPlatform(settings: settings);

/// 桌面 / 宿主未接线时使用的空实现，保证 UI 不崩。
class UnsupportedPushPlatform implements PushPlatform {
  const UnsupportedPushPlatform();

  @override
  Future<void> refreshCredentials() async {}

  @override
  PushCapability get capability => PushCapability.unsupported;

  @override
  bool get supported => false;

  @override
  Future<PushPermission> permission() async => const PushPermission('unsupported');

  @override
  Future<PushPermission> requestPermission() async =>
      const PushPermission('unsupported');

  @override
  Future<PushToken?> getToken() async => null;

  @override
  Stream<PushOpenTarget> get onOpen => const Stream<PushOpenTarget>.empty();

  @override
  Future<void> show(PushNotice notice) async {}

  @override
  Future<void> clear(String conversationId) async {}

  @override
  void dispose() {}
}
