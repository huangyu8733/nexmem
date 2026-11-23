import 'package:material_ui/material_ui.dart';

/// 视觉令牌，取值见 docs/ui-spec.md §6。
abstract final class NexmemColors {
  static const Color primary = Color(0xFF12B7F5);
  static const Color success = Color(0xFF2BB673);
  static const Color warning = Color(0xFFF5A623);
  static const Color danger = Color(0xFFE5484D);

  static const Color lightPage = Color(0xFFF2F2F2);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightText = Color(0xFF1A1A1A);
  static const Color lightTextSecondary = Color(0xFF8C8C8C);

  static const Color darkPage = Color(0xFF111214);
  static const Color darkCard = Color(0xFF1C1D1F);
  static const Color darkText = Color(0xFFEDEDED);
  static const Color darkTextSecondary = Color(0xFF9A9A9A);

  /// 头像底色候选，按会话 / 联系人 ID 取模，保证同一对象颜色稳定。
  static const List<Color> avatarPalette = <Color>[
    Color(0xFF12B7F5),
    Color(0xFF2BB673),
    Color(0xFFF5A623),
    Color(0xFF7C6BF5),
    Color(0xFFE5484D),
    Color(0xFF13A8A8),
  ];
}

/// 布局与尺寸常量，间距统一取 4 的倍数。
abstract final class NexmemMetrics {
  /// 响应式断点：`< 720` 用移动布局，`>= 720` 用三栏布局。
  static const double desktopBreakpoint = 720;

  static const double listItemHeight = 56;
  static const double avatarSize = 44;
  static const double railWidth = 64;
  static const double listPaneWidth = 280;
  static const double listPaneWidthWide = 320;

  /// 桌面宽屏右侧聊天资料面板宽度（P6-22）。
  static const double profilePaneWidth = 280;

  static const double radiusListItem = 8;
  static const double radiusBubble = 12;

  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space24 = 24;
}

abstract final class NexmemTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;
    final Color page = isDark ? NexmemColors.darkPage : NexmemColors.lightPage;
    final Color card = isDark ? NexmemColors.darkCard : NexmemColors.lightCard;
    final Color text = isDark ? NexmemColors.darkText : NexmemColors.lightText;
    final Color textSecondary = isDark
        ? NexmemColors.darkTextSecondary
        : NexmemColors.lightTextSecondary;

    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: NexmemColors.primary,
      brightness: brightness,
    ).copyWith(
      primary: NexmemColors.primary,
      onPrimary: Colors.white,
      surface: card,
      onSurface: text,
      error: NexmemColors.danger,
    );

    final ThemeData base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: page,
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
      ),
      iconTheme: base.iconTheme.copyWith(color: textSecondary),
      dividerTheme: DividerThemeData(
        color: textSecondary.withValues(alpha: 0.18),
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 60,
        backgroundColor: card,
        indicatorColor: NexmemColors.primary.withValues(alpha: 0.14),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            color: selected ? NexmemColors.primary : textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final bool selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? NexmemColors.primary : textSecondary,
          );
        }),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        iconTheme: IconThemeData(color: text),
      ),
    );
  }
}
