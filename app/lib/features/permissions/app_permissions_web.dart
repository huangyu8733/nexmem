// Web 权限实现：通知用浏览器 Notification API；摄像头/麦克风由
// getUserMedia 首次使用时弹窗授权，浏览器不提供静默查询接口，
// 因此 status 返回 prompt，request 主动申请后立即释放媒体流。

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'app_permission_types.dart';

class BrowserAppPermissions implements AppPermissions {
  const BrowserAppPermissions();

  @override
  Future<AppPermissionState> status(AppPermissionKind kind) async {
    if (kind == AppPermissionKind.notifications) {
      try {
        return switch (web.Notification.permission) {
          'granted' => AppPermissionState.granted,
          'denied' => AppPermissionState.denied,
          _ => AppPermissionState.prompt,
        };
      } on Object {
        return AppPermissionState.unsupported;
      }
    }
    return AppPermissionState.prompt;
  }

  @override
  Future<AppPermissionState> request(AppPermissionKind kind) async {
    if (kind == AppPermissionKind.notifications) {
      try {
        final JSString result = await web.Notification.requestPermission().toDart;
        return switch (result.toDart) {
          'granted' => AppPermissionState.granted,
          'denied' => AppPermissionState.denied,
          _ => AppPermissionState.prompt,
        };
      } on Object {
        return AppPermissionState.unsupported;
      }
    }
    try {
      final bool video = kind == AppPermissionKind.camera;
      final web.MediaStream stream =
          await web.window.navigator.mediaDevices
              .getUserMedia(
                web.MediaStreamConstraints(
                  video: video.toJS,
                  audio: (!video).toJS,
                ),
              )
              .toDart;
      for (final web.MediaStreamTrack track in stream.getTracks().toDart) {
        track.stop();
      }
      return AppPermissionState.granted;
    } on Object {
      return AppPermissionState.denied;
    }
  }

  @override
  Future<bool> openSettings(AppPermissionKind kind) async {
    // 浏览器不允许脚本打开站点权限设置页，只能提示用户在地址栏图标中修改。
    return false;
  }
}

AppPermissions makeAppPermissions() => const BrowserAppPermissions();
