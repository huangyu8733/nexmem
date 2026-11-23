import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'locale_config.dart';
import 'translations.dart';

/// 界面语言控制器：持有当前 locale（null 表示跟随系统），并持久化到内核设置。
///
/// 由 [NexmemApp] 持有，通过 [LocaleScope] 注入子树；设置页切换语言时调用
/// [localeController.setLocale]，MaterialApp 因 locale 变化重建并自动为
/// RTL 语种（阿拉伯语 / 希伯来语 / 波斯语 / 乌尔都语等）设置镜像排版。
class LocaleController extends ChangeNotifier {
  LocaleController(this._settings);

  final LocaleSettings _settings;

  /// 首次安装默认中文：避免测试环境（系统 locale 常为 en_US）误切英文，
  /// 也保证新用户体验一致；只有用户显式选「跟随系统」时才置为 null。
  static Locale get defaultLocale => const Locale('zh', 'CN');

  Locale? _locale = defaultLocale;
  bool _restored = false;

  /// 当前显式选择的语言；null 表示跟随系统。
  Locale? get locale => _locale;

  /// 是否已完成设置恢复。
  bool get restored => _restored;

  /// 从设置恢复上次选择；读取失败时保持跟随系统。
  Future<void> restore() async {
    if (_restored) {
      return;
    }
    _restored = true;
    try {
      final String? value = await _settings.read(localeSettingKey);
      final Locale? next;
      if (value == null || value.isEmpty) {
        next = defaultLocale; // 首次安装：保持中文
      } else if (value == systemLocaleValue) {
        next = null; // 用户显式选择跟随系统
      } else {
        next = parseLocaleSetting(value) ?? defaultLocale;
      }
      if (next != _locale) {
        _locale = next;
        notifyListeners();
      }
    } on Object {
      // 内核未启动或设置不可用：保持跟随系统。
    }
  }

  /// 切换语言并持久化。[locale] 为 null 表示跟随系统。
  Future<void> setLocale(Locale? locale) async {
    if (_locale == locale && _restored) {
      return;
    }
    _locale = locale;
    _restored = true;
    notifyListeners();
    try {
      await _settings.write(
        localeSettingKey,
        locale == null ? systemLocaleValue : formatLocaleSetting(locale),
      );
    } on Object {
      // 忽略写入失败：语言已在本进程生效。
    }
  }
}

/// 语言设置的最小接口，避免 l10n 层依赖具体传输或设置实现。
abstract class LocaleSettings {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// 把 [LocaleController] 注入子树。
class LocaleScope extends InheritedNotifier<LocaleController> {
  const LocaleScope({
    super.key,
    required LocaleController controller,
    required super.child,
  }) : super(notifier: controller);

  static LocaleController of(BuildContext context) {
    final LocaleScope? scope =
        context.dependOnInheritedWidgetOfExactType<LocaleScope>();
    assert(scope != null, 'LocaleScope 未注入，请检查 NexmemApp 的 build');
    return scope!.notifier!;
  }

  /// 只读取控制器、不订阅变化（用于 MaterialApp 之外的非响应式读取）。
  static LocaleController? maybeOf(BuildContext context) {
    final LocaleScope? scope =
        context.getElementForInheritedWidgetOfExactType<LocaleScope>()?.widget
            as LocaleScope?;
    return scope?.notifier;
  }
}

/// 轻量本地化对象：按当前 locale 查表。[key] 一律使用中文原文。
///
/// 查表顺序：当前语言 → 语言代码（去地区）→ 英文 → 中文原文。
/// [args] 用于替换文案中的 `{0}` / `{1}` 占位符，适配不同语言的语序。
class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizations(const Locale('zh', 'CN'));

  /// 当前语言代码（小写），用于 RTL 判定等。
  String get languageCode => locale.languageCode;

  String t(String key, [List<Object?> args = const <Object?>[]]) {
    String text = lookupTranslation(locale, key);
    for (int i = 0; i < args.length; i++) {
      text = text.replaceAll('{$i}', '${args[i]}');
    }
    return text;
  }
}

/// 供任意 Widget 快速取翻译：`context.t('关闭')`。
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  String t(String key, [List<Object?> args = const <Object?>[]]) =>
      l10n.t(key, args);
}

/// [AppLocalizations] 的 delegate。
class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(AppLocalizations(locale));

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}
