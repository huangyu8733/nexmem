import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/services.dart' show SystemChrome, SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 按实际生效的主题亮度构造 Android 系统栏样式。
///
/// 系统导航栏取与底部 [NavigationBar] 相同的卡片色，让它与应用底栏连成一体；
/// [SystemUiOverlayStyle.systemNavigationBarContrastEnforced] 必须为 false，
/// 否则 Android 10+ 会额外铺一层半透明遮罩，深色界面下仍会透出灰白「白条」。
SystemUiOverlayStyle systemUiOverlayStyleFor(Brightness brightness) {
  final bool isDark = brightness == Brightness.dark;
  final Color barColor = isDark ? NexmemColors.darkCard : NexmemColors.lightCard;
  final Brightness iconBrightness =
      isDark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: barColor,
    statusBarIconBrightness: iconBrightness,
    // iOS 的 statusBarBrightness 语义与 statusBarIconBrightness 相反。
    statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: barColor,
    systemNavigationBarDividerColor: barColor,
    systemNavigationBarIconBrightness: iconBrightness,
    systemNavigationBarContrastEnforced: false,
  );
}

/// 生产实现：只有 Android 需要跟随应用外观同步系统栏。
///
/// 平台通道在单元测试与部分兼容层不可用；系统栏只是视觉细节，
/// 调用失败不能打断应用启动，因此一律吞掉异常。
void applyAndroidSystemUiStyle(Brightness brightness) {
  if (foundation.kIsWeb) {
    return;
  }
  if (foundation.defaultTargetPlatform != foundation.TargetPlatform.android) {
    return;
  }
  try {
    SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyleFor(brightness));
  } catch (_) {
    // 忽略平台通道缺失。
  }
}

/// 观察 `MaterialApp` 实际生效的亮度并在变化时同步系统栏。
///
/// 放在 `MaterialApp.builder` 内、`Theme` 之下，因此 [Theme.of] 返回的正是
/// 当前外观（含 `ThemeMode.system` 跟随平台的结果）。主题切换后通过
/// [State.didChangeDependencies] 重新应用，系统条不会停留在启动时的颜色。
class SystemUiStyleScope extends StatefulWidget {
  const SystemUiStyleScope({
    super.key,
    required this.child,
    this.onBrightnessChanged,
  });

  final Widget child;

  /// 测试注入点；为空时调用 [applyAndroidSystemUiStyle]。
  final ValueChanged<Brightness>? onBrightnessChanged;

  @override
  State<SystemUiStyleScope> createState() => _SystemUiStyleScopeState();
}

class _SystemUiStyleScopeState extends State<SystemUiStyleScope> {
  Brightness? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SystemUiStyleScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final Brightness brightness = Theme.of(context).brightness;
    if (brightness == _applied) {
      return;
    }
    _applied = brightness;
    (widget.onBrightnessChanged ?? applyAndroidSystemUiStyle)(brightness);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
