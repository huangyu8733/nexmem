// 消息通知控制器：把平台推送能力、内核 push 契约、本机开关串起来。
//
// 职责：
//  - 本机开关持久化（settings 键 push.enabled），默认关闭；
//  - 开启时申请权限、取令牌、经内核 push.register 上报；关闭时注销；
//  - 收到入站消息时按「会话是否已打开」决定是否弹本地通知；
//  - 通知点击解析 conversation_id，回调壳层打开对应会话。
//
// 所有外部依赖都可注入，便于 Widget 测试；平台未接线时全部降级为空操作。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/push.dart';
import '../settings/settings_service.dart';
import 'push_platform.dart';

const String kPushEnabledSettingKey = 'push.enabled';

/// 推送开关与运行状态。
class PushController extends ChangeNotifier {
  PushController({
    required this._platform,
    required this._settings,
    this._pushService,
    this._onOpenConversation,
  }) {
    _sub = _platform.onOpen.listen(_handleOpen);
    unawaited(_restore());
  }

  final PushPlatform _platform;
  final SettingsService _settings;
  final PushService? _pushService;
  final void Function(String conversationId)? _onOpenConversation;

  StreamSubscription<PushOpenTarget>? _sub;

  /// 构造时的设置恢复是否仍在读取中；用户操作要先于异步恢复生效。
  bool _restoreInFlight = true;

  bool enabled = false;
  bool initializing = false;
  String? error;
  PushPermission permission = const PushPermission('prompt');
  String? registeredToken;

  /// 当前已打开的会话；该会话收到消息时不再弹通知。
  String? activeConversationId;

  bool get supported => _platform.supported;

  PushCapability get capability => _platform.capability;

  bool get canEnable => supported && !initializing;

  Future<void> _restore() async {
    try {
      final String? value = await _settings.read(kPushEnabledSettingKey);
      enabled = value == 'true';
    } on Object {
      enabled = false;
    }
    // 系统设置里可能被用户改过权限，恢复时只查询、不弹申请框。
    try {
      permission = await _platform.permission();
    } on Object {
      // 查询失败时保留 prompt，由 refresh() 再确认。
    }
    _notify();
    // 用户在恢复完成前手动开关时，禁止迟到的恢复再触发一次注册。
    if (!_restoreInFlight) {
      return;
    }
    _restoreInFlight = false;
    if (enabled) {
      await refresh();
    }
  }

  /// 申请权限并上报令牌；重复调用是幂等的。
  Future<void> refresh() async {
    _restoreInFlight = false;
    if (!_platform.supported || _pushService == null) {
      error = supported ? null : '当前平台不支持系统通知';
      _notify();
      return;
    }
    initializing = true;
    error = null;
    _notify();
    try {
      permission = await _platform.requestPermission();
      if (!permission.granted) {
        error = permission.denied ? '通知权限已被拒绝，请在系统设置中开启' : null;
        enabled = false;
        await _persist(false);
        return;
      }
      final PushToken? token = await _platform.getToken();
      if (token == null) {
        error = '尚未获取设备令牌，请确认推送凭证已配置';
        return;
      }
      await _pushService.register(
        token.wiredToken,
        env: token.env == 'sandbox'
            ? PushEnvironment.sandbox
            : PushEnvironment.production,
      );
      registeredToken = token.wiredToken;
      error = null;
    } on Object catch (e) {
      error = '$e';
    } finally {
      initializing = false;
      _notify();
    }
  }

  /// 开发者页改完凭证后调用：让平台重读公钥，并在通知已开启时重新注册。
  Future<void> reloadCredentials() async {
    await _platform.refreshCredentials();
    if (enabled) {
      await refresh();
    } else {
      _notify();
    }
  }

  /// 开关：关闭时立即注销令牌并清除本机开关。
  Future<void> setEnabled(bool value) async {
    _restoreInFlight = false;
    if (!value) {
      enabled = false;
      final String? token = registeredToken;
      registeredToken = null;
      if (token != null && _pushService != null) {
        try {
          await _pushService.unregister(token);
        } on Object {
          // 注销失败不影响本地关闭；服务端令牌有上限会自动裁剪。
        }
      }
      await _persist(false);
      _notify();
      return;
    }
    if (!supported) {
      error = '当前平台不支持系统通知';
      _notify();
      return;
    }
    await _persist(true);
    enabled = true;
    _notify();
    await refresh();
  }

  Future<void> _persist(bool value) async {
    try {
      await _settings.write(kPushEnabledSettingKey, value ? 'true' : '');
    } on Object {
      // 设置服务未就绪时只保留内存状态。
    }
  }

  /// 入站消息：会话未打开时弹本地通知。
  Future<void> onIncomingMessage({
    required String conversationId,
    required String title,
    required String body,
  }) async {
    if (!enabled || conversationId.isEmpty) return;
    if (activeConversationId == conversationId) return;
    try {
      await _platform.show(PushNotice(
        title: title,
        body: body,
        conversationId: conversationId,
      ));
    } on Object {
      // 通知失败不影响消息本身。
    }
  }

  /// 用户已打开会话：清掉对应通知。
  Future<void> markConversationOpen(String conversationId) async {
    activeConversationId = conversationId;
    try {
      await _platform.clear(conversationId);
    } on Object {
      // 忽略。
    }
  }

  /// 用户离开会话：之后的入站消息应重新弹通知。
  void markConversationClosed(String conversationId) {
    if (activeConversationId == conversationId) {
      activeConversationId = null;
    }
  }

  void _handleOpen(PushOpenTarget target) {
    _onOpenConversation?.call(target.conversationId);
  }

  void _notify() {
    if (hasListeners) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _platform.dispose();
    super.dispose();
  }
}
