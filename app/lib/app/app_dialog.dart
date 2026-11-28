/// 应用内弹窗统一入口。
///
/// `EmbeddedSettingsPane` 为了把历史 Dialog 面板内嵌进右栏 / 全屏页，
/// 会给栈顶 dialog 套一层「去弹窗化」的透明 [DialogThemeData]。
/// 如果从这些面板内部再直接 `showDialog`，二级弹窗会继承透明主题，
/// 变成没有底色、与底层内容重叠、无法阅读的浮层。
///
/// 这里强制切到根 Navigator，并用根主题重建不透明的 dialog 主题，
/// 保证任何入口打开的弹窗都有真实底色、阴影和留白。
library;

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
  final ThemeData rootTheme = Theme.of(navigator.context);
  final DialogThemeData dialogTheme = rootTheme.dialogTheme;
  return showDialog<T>(
    context: navigator.context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext dialogContext) => Theme(
      data: rootTheme.copyWith(
        dialogTheme: dialogTheme.copyWith(
          backgroundColor: rootTheme.colorScheme.surface,
          surfaceTintColor: rootTheme.colorScheme.surface,
          elevation: 8,
          shadowColor: rootTheme.colorScheme.shadow,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space24,
            vertical: NexmemMetrics.space24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
          ),
        ),
      ),
      // 必须把 Theme 内部的 context 交给 builder：若直接传 dialogContext，
      // builder 创建的 AlertDialog 仍继承外层透明主题，修复不会生效。
      child: Builder(builder: builder),
    ),
  );
}
