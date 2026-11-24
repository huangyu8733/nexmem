import 'package:material_ui/material_ui.dart';

import '../../app/pane_header.dart';

/// 从嵌入式面板的对话框内部打开二级对话框时使用。
///
/// [EmbeddedSettingsPane] 会用「去弹窗化」的透明 [DialogThemeData] 包裹顶层
/// 对话框，使其看起来是右栏里的一整块内容。但 `showDialog` 会通过
/// `InheritedTheme.capture` 捕获调用处主题并重放到新路由，导致二级对话框
/// （中继设置、举报、备份流程等）也继承透明主题，渲染成与底层内容重叠、
/// 无法阅读的浮层。这里在 builder 内层显式恢复根导航器的正常主题，
/// 让二级对话框保有正常的背景卡片、圆角与阴影。
Future<T?> showPaneDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final ThemeData rootTheme = Theme.of(
    Navigator.of(context, rootNavigator: true).context,
  );
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (BuildContext dialogContext) => Theme(
      data: rootTheme,
      child: builder(dialogContext),
    ),
  );
}

/// 把一个以 `Navigator.pop()` 关闭的对话框 widget 变成可内嵌的面板。
///
/// 内部用一个独立的 [Navigator]：栈底为关闭监听页，栈顶为传入的对话框。
/// 对话框里的任何 `Navigator.pop()` 只会退到栈底，从而触发 [onDismiss]，
/// 不会弹出应用主路由。用于桌面右栏和手机全屏页复用既有弹窗内容。
class EmbeddedSettingsPane extends StatefulWidget {
  const EmbeddedSettingsPane({
    super.key,
    required this.builder,
    required this.onDismiss,
    this.title,
  });

  /// 构建要嵌入的对话框 widget（可含状态）。
  final WidgetBuilder builder;

  /// 对话框内部关闭时回调，外层据此切回默认面板。
  final VoidCallback onDismiss;

  /// 可选的面板标题；给出时在顶部渲染一条标题栏。
  final String? title;

  @override
  State<EmbeddedSettingsPane> createState() => _EmbeddedSettingsPaneState();
}

class _EmbeddedSettingsPaneState extends State<EmbeddedSettingsPane> {
  static const String _baseRoute = '/pane-base';
  static const String _dialogRoute = '/pane-dialog';

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 标记对话框已经压栈，避免初始构建 base 路由时误判为「已关闭」。
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _navigatorKey.currentState
          ?.pushNamed(_dialogRoute)
          .then<void>((_) {
            if (mounted) {
              setState(() => _dialogShown = true);
            }
          });
    });
  }

  /// 仅用于顶层内嵌对话框的「去弹窗化」主题：铺满面板、无浮层卡片与阴影。
  ///
  /// 关键：该主题只包裹栈顶那一个 dialog widget，**不能**包裹整个 Navigator。
  /// 否则从 dialog 内部再 `showDialog` 打开的二级弹框（中继设置、反馈、
  /// 备份流程等）也会继承透明主题，变成与底层内容重叠、无法阅读的怪异浮层。
  ThemeData _embeddedDialogTheme(ThemeData theme) => theme.copyWith(
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shadowColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          titleTextStyle: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              ) ??
              const TextStyle(fontSize: 20),
        ),
      );

  Route<void> _route(RouteSettings settings) {
    final String? name = settings.name;
    if (name == _dialogRoute) {
      return MaterialPageRoute<void>(
        builder: (BuildContext context) => Theme(
          data: _embeddedDialogTheme(Theme.of(context)),
          child: widget.builder(context),
        ),
      );
    }
    return MaterialPageRoute<void>(
      builder: (BuildContext context) => _PaneBase(
        dialogShown: () => _dialogShown,
        onDismiss: widget.onDismiss,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget navigator = Navigator(
      key: _navigatorKey,
      initialRoute: _baseRoute,
      onGenerateRoute: _route,
    );
    final String? title = widget.title;
    if (title == null) {
      return navigator;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(title: title),
        Expanded(child: navigator),
      ],
    );
  }
}

/// 栈底占位页：对话框 pop 后可见，通知外层它已关闭。
class _PaneBase extends StatelessWidget {
  const _PaneBase({
    required this.dialogShown,
    required this.onDismiss,
  });

  final bool Function() dialogShown;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    // 只有对话框曾压栈、且当前已无更多路由（即对话框已 pop）时才回调。
    if (dialogShown() && !Navigator.of(context).canPop()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onDismiss());
    }
    return const SizedBox.shrink();
  }
}

/// 手机窄屏下的设置项全屏页：标题栏 + 内嵌面板内容。
class SettingsPanePage extends StatelessWidget {
  const SettingsPanePage({
    super.key,
    required this.title,
    required this.builder,
  });

  final String title;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(child: EmbeddedSettingsPane(builder: builder, onDismiss: () {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      })),
    );
  }
}
