// 跨平台应用权限的公共类型。
//
// 只覆盖程序自己会主动使用的三类系统权限：摄像头（扫码/视频通话）、
// 麦克风（语音/视频通话）、通知（离线消息提醒）。文件与目录选择由系统
// 选择器授权，位置由用户手填，都不在这里申请。

/// 需要向系统申请的能力。
enum AppPermissionKind {
  camera,
  microphone,
  notifications;

  String get wire => name;

  static AppPermissionKind? fromWire(String? value) {
    for (final AppPermissionKind kind in AppPermissionKind.values) {
      if (kind.wire == value) {
        return kind;
      }
    }
    return null;
  }
}

/// 权限状态。[permanentlyDenied] 表示系统不再弹窗，只能跳设置页开启。
enum AppPermissionState {
  granted,
  denied,
  prompt,
  permanentlyDenied,
  unsupported;

  String get wire => switch (this) {
        AppPermissionState.granted => 'granted',
        AppPermissionState.denied => 'denied',
        AppPermissionState.prompt => 'prompt',
        AppPermissionState.permanentlyDenied => 'permanently_denied',
        AppPermissionState.unsupported => 'unsupported',
      };

  bool get canRequest => this == prompt || this == denied;

  static AppPermissionState fromWire(String? value) => switch (value) {
        'granted' => AppPermissionState.granted,
        'denied' => AppPermissionState.denied,
        'prompt' => AppPermissionState.prompt,
        'permanently_denied' => AppPermissionState.permanentlyDenied,
        'unsupported' => AppPermissionState.unsupported,
        _ => AppPermissionState.unsupported,
      };
}

/// 权限查询 / 申请 / 跳系统设置的统一入口。
abstract class AppPermissions {
  const AppPermissions();

  Future<AppPermissionState> status(AppPermissionKind kind);

  Future<AppPermissionState> request(AppPermissionKind kind);

  /// 打开系统设置中对应权限页；返回是否成功唤起。
  Future<bool> openSettings(AppPermissionKind kind);
}
