import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../features/settings/settings_service.dart';
import '../l10n/l10n.dart';
import 'core_session.dart';
import 'shell.dart';
import 'theme.dart';

/// 把 [SettingsService] 适配为语言控制器所需的最小接口。
class _SettingsLocaleStore implements LocaleSettings {
  const _SettingsLocaleStore(this._settings);

  final SettingsService _settings;

  @override
  Future<String?> read(String key) => _settings.read(key);

  @override
  Future<void> write(String key, String value) => _settings.write(key, value);
}

/// 六端共用入口：主题、语言与首页壳。
class NexmemApp extends StatefulWidget {
  const NexmemApp({super.key, this.session});

  /// 内核会话；为空时以离线占位启动（未配置后端或 Widget 测试）。
  final CoreSession? session;

  @override
  State<NexmemApp> createState() => _NexmemAppState();
}

class _NexmemAppState extends State<NexmemApp> {
  /// 外观主题（ui-spec.md §5）：默认跟随系统，成功后经 `settings.set` 落盘。
  ThemeMode _themeMode = ThemeMode.system;

  /// 界面语言控制器：null locale 表示跟随系统；切换后持久化到设置 KV。
  late final LocaleController _locale = LocaleController(
    _SettingsLocaleStore(
      widget.session?.settings ?? const UnavailableSettingsService(),
    ),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_restoreTheme());
    unawaited(_locale.restore());
  }

  @override
  void dispose() {
    _locale.dispose();
    super.dispose();
  }

  /// 从内核设置恢复上次选择；读取失败时保持跟随系统。
  Future<void> _restoreTheme() async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    try {
      final String? value = await session.settings.read(themeModeSettingKey);
      final ThemeMode? mode = themeModeFromSetting(value);
      if (mode != null && mounted) {
        setState(() => _themeMode = mode);
      }
    } catch (_) {
      // 内核未启动或设置不可用：保持默认，不影响启动。
    }
  }

  void _changeThemeMode(ThemeMode mode) {
    if (mode == _themeMode) {
      return;
    }
    setState(() => _themeMode = mode);
    unawaited(_persistTheme(mode));
  }

  /// 持久化主题选择；失败时仅本机本次生效，不打断用户操作。
  Future<void> _persistTheme(ThemeMode mode) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    try {
      await session.settings.write(
        themeModeSettingKey,
        themeModeSettingValue(mode),
      );
    } catch (_) {
      // 忽略写入失败：主题已在本进程生效。
    }
  }

  @override
  Widget build(BuildContext context) {
    return LocaleScope(
      controller: _locale,
      child: AnimatedBuilder(
        animation: _locale,
        builder: (BuildContext context, Widget? child) {
          final Locale titleLocale =
              _locale.locale ?? WidgetsBinding.instance.platformDispatcher.locale;
          return MaterialApp(
            title: appDisplayName(titleLocale),
            debugShowCheckedModeBanner: false,
            locale: _locale.locale,
            supportedLocales: supportedLocales,
            localizationsDelegates: <LocalizationsDelegate<dynamic>>[
              const AppLocalizationsDelegate(),
              ...GlobalMaterialLocalizations.delegates,
            ],
            theme: NexmemTheme.light(),
            darkTheme: NexmemTheme.dark(),
            themeMode: _themeMode,
            home: AppShell(
              session: widget.session,
              themeMode: _themeMode,
              onThemeModeChanged: _changeThemeMode,
            ),
          );
        },
      ),
    );
  }
}
