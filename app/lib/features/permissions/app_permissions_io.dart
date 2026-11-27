// Android / iOS / 桌面权限实现。
//
// 原生宿主需实现 MethodChannel 'nexmem/permissions'：
//   status {kind}         -> String granted|denied|prompt|permanently_denied|unsupported
//   request {kind}        -> String 同上
//   openSettings {kind}   -> bool
// 宿主未接线时全部安全降级为 unsupported，不影响 App 启动与既有功能。

import 'package:flutter/services.dart';

import 'app_permission_types.dart';

class MethodChannelAppPermissions implements AppPermissions {
  const MethodChannelAppPermissions();

  static const MethodChannel _channel = MethodChannel('nexmem/permissions');

  Future<AppPermissionState> _call(String method, AppPermissionKind kind) async {
    try {
      final String? raw = await _channel.invokeMethod<String>(
        method,
        <String, String>{'kind': kind.wire},
      );
      return AppPermissionState.fromWire(raw);
    } on MissingPluginException {
      return AppPermissionState.unsupported;
    } on Object {
      return AppPermissionState.unsupported;
    }
  }

  @override
  Future<AppPermissionState> status(AppPermissionKind kind) =>
      _call('status', kind);

  @override
  Future<AppPermissionState> request(AppPermissionKind kind) =>
      _call('request', kind);

  @override
  Future<bool> openSettings(AppPermissionKind kind) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'openSettings',
        <String, String>{'kind': kind.wire},
      );
      return ok ?? false;
    } on Object {
      return false;
    }
  }
}

AppPermissions makeAppPermissions() => const MethodChannelAppPermissions();
