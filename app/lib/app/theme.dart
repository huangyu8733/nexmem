import 'package:material_ui/material_ui.dart';

/// 视觉令牌，取值见 docs/ui-spec.md §6。
///
/// 视觉语言对齐 QQ 桌面端：品牌蓝主色、蓝色侧边栏、红色未读角标、
/// 圆角方形头像与带尖角的聊天气泡。所有颜色集中在此，明暗主题共用一套
/// 语义令牌，页面不直接写死色值。
abstract final class NexmemColors {
  /// QQ 品牌蓝：主按钮、自己发出的气泡、选中态。
  static const Color primary = Color(0xFF12B7F5);

  /// 侧边栏渐变：上浅下深，模拟 QQ 左侧蓝色导航条。
  static const Color railTop = Color(0xFF2FC6F8);
  static const Color railBottom = Color(0xFF0C8FD4);

  /// 主色加深/浅化变体，用于按压态与浅色底。
  static const Color primaryDeep = Color(0xFF0A86BC);
  static const Color primaryWash = Color(0xFFE6F6FE);

  static const Color success = Color(0xFF2BB673);
  static const Color warning = Color(0xFFF5A623);
  static const Color danger = Color(0xFFE5484D);

  /// QQ 未读红：数字角标与小红点。
  static const Color unread = Color(0xFFFF3B30);

  /// 免打扰会话的灰色小点。
  static const Color unreadMuted = Color(0xFFB0B0B0);

  static const Color lightPage = Color(0xFFF5F6F8);
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

  static const double listItemHeight = 60;
  static const double avatarSize = 44;
  static const double railWidth = 64;
  static const double listPaneWidth = 280;
  static const double listPaneWidthWide = 320;

  /// 桌面宽屏右侧聊天资料面板宽度（P6-22）。
  static const double profilePaneWidth = 280;

  /// QQ 风格头像为圆角方形（而非正圆）。
  static const double avatarRadius = 9;

  /// 聊天气泡的小尖角边长。
  static const double bubbleTail = 6;

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
    final Color wash = isDark
        ? NexmemColors.primary.withValues(alpha: 0.16)
        : NexmemColors.primaryWash;

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

    final BorderRadius controlRadius =
        BorderRadius.circular(NexmemMetrics.radiusListItem);

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
      ),
      iconTheme: base.iconTheme.copyWith(color: textSecondary),
      dividerTheme: DividerThemeData(
        color: textSecondary.withValues(alpha: 0.12),
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 60,
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        indicatorColor: wash,
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
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.22),
        shape: RoundedRectangleBorder(borderRadius: controlRadius),
        insetPadding: const EdgeInsets.symmetric(
          horizontal: NexmemMetrics.space24,
          vertical: NexmemMetrics.space24,
        ),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: text,
        ),
      ),
      // 统一按钮观感：QQ 蓝实心按钮、轻圆角、无多余阴影。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: NexmemColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: textSecondary.withValues(alpha: 0.16),
          disabledForegroundColor: textSecondary.withValues(alpha: 0.62),
          minimumSize: const Size(72, 38),
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
            vertical: NexmemMetrics.space8,
          ),
          shape: RoundedRectangleBorder(borderRadius: controlRadius),
          elevation: 0,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: NexmemColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(72, 38),
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
            vertical: NexmemMetrics.space8,
          ),
          shape: RoundedRectangleBorder(borderRadius: controlRadius),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: NexmemColors.primary,
          minimumSize: const Size(56, 36),
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space12,
            vertical: NexmemMetrics.space8,
          ),
          shape: RoundedRectangleBorder(borderRadius: controlRadius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: NexmemColors.primary,
          side: BorderSide(color: NexmemColors.primary.withValues(alpha: 0.5)),
          minimumSize: const Size(72, 38),
          shape: RoundedRectangleBorder(borderRadius: controlRadius),
        ),
      ),
      // 输入框：浅底无描边，聚焦时用品牌蓝描边。
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: textSecondary.withValues(alpha: 0.06),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: NexmemMetrics.space12,
          vertical: NexmemMetrics.space12,
        ),
        hintStyle: TextStyle(color: textSecondary.withValues(alpha: 0.7)),
        border: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: const BorderSide(color: NexmemColors.primary, width: 1.5),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF3A3C40) : const Color(0xFF32343A),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        padding: const EdgeInsets.symmetric(
          horizontal: NexmemMetrics.space8,
          vertical: NexmemMetrics.space4,
        ),
        waitDuration: const Duration(milliseconds: 350),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all<double>(6),
        radius: const Radius.circular(6),
        thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.hovered)) {
            return textSecondary.withValues(alpha: 0.5);
          }
          return textSecondary.withValues(alpha: 0.28);
        }),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: NexmemColors.primary,
        linearTrackColor: NexmemColors.primary.withValues(alpha: 0.14),
        circularTrackColor: NexmemColors.primary.withValues(alpha: 0.14),
      ),
    );
  }
}

/// 对话框内容宽度自适应：窄屏跟随可用宽度，宽屏不超过 [maxWidth]。
///
/// 过去多处直接写 `SizedBox(width: 460)`，在 390px 手机上会横向溢出。
Widget responsiveDialogContent({
  required Widget child,
  double maxWidth = 480,
  double? height,
}) {
  return ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth),
    child: SizedBox(
      width: double.maxFinite,
      height: height,
      child: child,
    ),
  );
}
