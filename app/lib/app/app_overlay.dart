import 'package:material_ui/material_ui.dart';

/// 全局浮层控制器：应用入口持有，导航壳每帧登记当前要显示的浮层。
///
/// 浮层挂在 Navigator 之上，而不是壳层 Stack 里。移动端聊天页通过
/// `Navigator.push` 打开时，来电通知条、全屏通话页、远控页、消息提示
/// 依然能盖在聊天页上方；桌面内联聊天则不受影响。
class AppOverlayController extends ChangeNotifier {
  Object? _owner;
  List<WidgetBuilder> _layers = const <WidgetBuilder>[];

  /// 当前浮层构造器（只读）。
  List<WidgetBuilder> get layers => _layers;

  /// 由当前壳层登记浮层；旧壳层释放后不会清掉新壳层的浮层。
  void setLayers(Object owner, List<WidgetBuilder> layers) {
    if (identical(_owner, owner) &&
        _layers.length == layers.length &&
        _sameBuilders(layers)) {
      return;
    }
    _owner = owner;
    _layers = List<WidgetBuilder>.unmodifiable(layers);
    notifyListeners();
  }

  /// 壳层销毁时释放其登记的浮层。
  void release(Object owner) {
    if (!identical(_owner, owner)) {
      return;
    }
    _owner = null;
    _layers = const <WidgetBuilder>[];
    notifyListeners();
  }

  bool _sameBuilders(List<WidgetBuilder> layers) {
    for (int i = 0; i < layers.length; i++) {
      if (!identical(_layers[i], layers[i])) {
        return false;
      }
    }
    return true;
  }
}

/// 挂在根 Navigator 之上的浮层宿主，尺寸与屏幕一致。
///
/// 内部再套一层 [Overlay]：一来让 IconButton 的 Tooltip 等控件有宿主，
/// 二来每个 entry 自带满屏约束，避免 Positioned 只指定 top/right 时
/// 拿到无界高度导致排版溢出。
class AppOverlayHost extends StatefulWidget {
  const AppOverlayHost({super.key, required this.controller});

  final AppOverlayController controller;

  @override
  State<AppOverlayHost> createState() => _AppOverlayHostState();
}

class _AppOverlayHostState extends State<AppOverlayHost> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (BuildContext context) {
      return AnimatedBuilder(
        animation: widget.controller,
        builder: (BuildContext context, Widget? _) {
          final List<WidgetBuilder> layers = widget.controller.layers;
          if (layers.isEmpty) {
            return const IgnorePointer(child: SizedBox.expand());
          }
          return Stack(
            key: const ValueKey<String>('app-global-overlay'),
            children: <Widget>[
              for (final WidgetBuilder buildLayer in layers)
                buildLayer(context),
            ],
          );
        },
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: <OverlayEntry>[_entry]);
  }
}
