// Android 输入注入：指针手势走无障碍服务，文本走「剪贴板 + 粘贴」。
//
// Android 不允许第三方应用直接合成全局按键，因此：
//   - 指针：AccessibilityService.dispatchGesture（点击/拖拽/长按/滑动滚动）；
//   - 文本：写入系统剪贴板后对焦点输入框执行 ACTION_PASTE；
//   - 按键：Ctrl/Cmd 组合映射为节点的复制/剪切/粘贴/全选，返回键与 Home 走
//     全局动作，其余按键（方向键、功能键等）不支持。

import '../remote_host_platform.dart';
import '../remote_input_codec.dart';
import '../remote_session.dart';
import 'desktop_input_injector.dart';

class AndroidInputInjector implements DesktopInputInjector {
  @override
  bool get supportsInput => true;

  @override
  String get permissionHint =>
      '需要在系统设置中开启「Nexmem 远程控制」无障碍服务；文字输入通过剪贴板粘贴完成。';

  @override
  Future<InputPermissionStatus> checkPermissions() async {
    return await RemoteHostPlatform.accessibilityEnabled()
        ? InputPermissionStatus.granted
        : InputPermissionStatus.denied;
  }

  @override
  Future<InputPermissionStatus> requestPermissions() async {
    await RemoteHostPlatform.openAccessibilitySettings();
    return InputPermissionStatus.denied;
  }

  @override
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  }) async {
    await RemoteHostPlatform.injectPointer(event);
  }

  @override
  Future<void> key(String key, {required bool down, int modifiers = 0}) async {
    // 无障碍只能触发一次性动作，按键释放无需处理。
    if (!down) {
      return;
    }
    await RemoteHostPlatform.injectKey(key, down: true, modifiers: modifiers);
  }

  @override
  Future<void> text(String text) async {
    await RemoteHostPlatform.injectText(text);
  }

  @override
  Future<void> dispose() async {}
}
