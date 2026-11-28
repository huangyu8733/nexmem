// 移动端被控的系统能力通道（Android）。
//
// Android 从 10 开始要求采集屏幕期间存在 mediaProjection 类型的前台服务，
// 否则 getMediaProjection 会抛 SecurityException；输入注入则依赖无障碍服务。
// 桌面平台全部走 dart:ffi，不经过这里。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_input_codec.dart';

class RemoteHostPlatform {
  const RemoteHostPlatform._();

  static const MethodChannel channel = MethodChannel('io.nexmem/remote_host');

  /// 当前是否为 Android 被控端。
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 采集开始前启动前台服务；非 Android 平台为空操作。
  static Future<void> startScreenCapture() async {
    if (!isAndroid) {
      return;
    }
    try {
      await channel.invokeMethod<void>('startScreenCapture');
    } on Object {
      // 缺少原生实现时仍尝试采集，失败由媒体层报错。
    }
  }

  /// 采集结束后停止前台服务。
  static Future<void> stopScreenCapture() async {
    if (!isAndroid) {
      return;
    }
    try {
      await channel.invokeMethod<void>('stopScreenCapture');
    } on Object {
      // 服务可能已被系统回收。
    }
  }

  /// 无障碍服务是否已启用（决定能否注入输入）。
  static Future<bool> accessibilityEnabled() async {
    if (!isAndroid) {
      return false;
    }
    try {
      final bool? enabled =
          await channel.invokeMethod<bool>('accessibilityEnabled');
      return enabled ?? false;
    } on Object {
      return false;
    }
  }

  /// 打开系统的无障碍服务设置页。
  static Future<void> openAccessibilitySettings() async {
    if (!isAndroid) {
      return;
    }
    try {
      await channel.invokeMethod<void>('openAccessibilitySettings');
    } on Object {
      // 部分定制系统没有该设置页，忽略即可。
    }
  }

  static Future<void> injectPointer(RemotePointerEvent event) async {
    if (!isAndroid) {
      return;
    }
    try {
      await channel.invokeMethod<void>('injectPointer', <String, dynamic>{
        'type': event.type.name,
        'x': event.xNorm,
        'y': event.yNorm,
        'buttons': event.buttons,
        'wheelY': event.wheelY,
        'wheelX': event.wheelX,
        'modifiers': event.modifiers,
      });
    } on Object {
      // 无障碍服务未启用时静默忽略。
    }
  }

  static Future<void> injectKey(
    String key, {
    required bool down,
    int modifiers = 0,
  }) async {
    if (!isAndroid) {
      return;
    }
    try {
      await channel.invokeMethod<void>('injectKey', <String, dynamic>{
        'key': key,
        'down': down,
        'modifiers': modifiers,
      });
    } on Object {
      // 无障碍服务未启用时忽略。
    }
  }

  static Future<void> injectText(String text) async {
    if (!isAndroid || text.isEmpty) {
      return;
    }
    try {
      await channel.invokeMethod<void>('injectText', <String, dynamic>{
        'text': text,
      });
    } on Object {
      // 粘贴失败时由上层退回剪贴板权限检查。
    }
  }

  /// 下发多点触摸手势；points 每项为归一化 x/y 与触点 id。
  static Future<void> injectTouch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  }) async {
    if (!isAndroid || points.isEmpty) {
      return;
    }
    try {
      await channel.invokeMethod<void>('injectTouch', <String, dynamic>{
        'phase': phase,
        'points': points,
        'modifiers': modifiers,
      });
    } on Object {
      // 无障碍服务未启用时静默忽略。
    }
  }
}
