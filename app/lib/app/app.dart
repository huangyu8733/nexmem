import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../features/account/account_manager.dart';
import '../features/account/account_manager_page.dart';
import '../features/account/lock_screen.dart';
import '../features/settings/settings_service.dart';
import '../l10n/l10n.dart';
import 'app_overlay.dart';
import 'core_session.dart';
import 'shell.dart';
import 'startup_gate.dart';
import 'system_ui_style.dart';
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
  const NexmemApp({
    super.key,
    this.session,
    this.startupChecks,
    this.onStartupReport,
    this.enableStartupCheck = true,
  });

  /// 内核会话；为空时以离线占位启动（未配置后端或 Widget 测试）。
  final CoreSession? session;

  /// 启动检测项 / 进度回报的测试注入点（生产为 null）。
  final List<StartupCheckDef>? startupChecks;
  final void Function(int, int, List<StartupCheckResult>)? onStartupReport;

  /// 是否启用启动服务检测。聚焦其它功能的测试可关闭，避免被检测门挡住。
  final bool enableStartupCheck;

  @override
  State<NexmemApp> createState() => _NexmemAppState();
}

class _NexmemAppState extends State<NexmemApp> {
  /// 根浮层：通知、通话、远控与 toast 都挂在 Navigator 之上，
  /// 避免移动端 push 出的聊天页把提示盖住。
  final AppOverlayController _overlay = AppOverlayController();

  /// 外观主题（ui-spec.md §5）：默认跟随系统，成功后经 `settings.set` 落盘。
  ThemeMode _themeMode = ThemeMode.system;

  /// 界面语言控制器：null locale 表示跟随系统；切换后持久化到设置 KV。
  late final LocaleController _locale = LocaleController(
    _SettingsLocaleStore(
      widget.session?.settings ?? const UnavailableSettingsService(),
    ),
  );

  /// 本机账号与临时锁：由入口持有，切换账号/解锁后重建整个导航壳。
  late final AccountManager _account = AccountManager(session: widget.session);

  /// 服务就绪检测：账号选定后先探测内核与关键服务，再进入主界面。
  /// 切换账号后重置，确保每套账号数据都在内核就绪后才呈现。
  bool _startupReady = false;
  int? _startupGeneration;

  @override
  void initState() {
    super.initState();
    _account.addListener(_onAccountChanged);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    unawaited(_account.initialize());
    unawaited(_restoreTheme());
    unawaited(_locale.restore());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _account.removeListener(_onAccountChanged);
    _account.dispose();
    _locale.dispose();
    _overlay.dispose();
    super.dispose();
  }

  void _onAccountChanged() {
    // 账号切换 / 重新登录会让内核落到新的数据目录，必须重新做服务就绪检测。
    if (_startupGeneration != _account.generation) {
      _startupGeneration = _account.generation;
      _startupReady = false;
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// 任意键盘活动都重置自动锁倒计时。
  bool _onKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _account.recordActivity();
    }
    return false;
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

  /// 依据账号状态在「初始化 / 锁屏 / 账号选择 / 主界面 / 退出页」间切换。
  Widget _buildHome() {
    if (!_account.initialized) {
      return const Center(
        key: ValueKey<String>('app-initializing'),
        child: CircularProgressIndicator(),
      );
    }
    if (_account.exited) {
      return ExitedScreen(onReenter: _account.cancelExit);
    }
    if (_account.locked && _account.lockSettings.hasPin) {
      return LockScreen(manager: _account);
    }
    if (_account.activeId == null) {
      return AccountGate(
        manager: _account,
        message: _account.locked ? context.t('锁屏已清除，请重新选择账号') : '',
      );
    }
    // 有内核会话时，先探测内核与关键服务就绪，再进入主界面。
    // 避免联系人/群等页面 initState 早于 core.start 而出现「尚未接入内核」。
    // session 为空的离线占位（未配置后端 / 单元测试）跳过检测直接进壳层。
    final CoreSession? session = widget.session;
    if (widget.enableStartupCheck && session != null && !_startupReady) {
      return StartupGate(
        key: const ValueKey<String>('startup-gate'),
        session: session,
        checks: widget.startupChecks,
        onReport: widget.onStartupReport,
        onReady: () {
          if (mounted) {
            setState(() => _startupReady = true);
          }
        },
      );
    }
    return AppShell(
      // 账号切换/解锁后强制重建，清除旧账号的会话、草稿与远控状态。
      key: ValueKey<String>('app-shell-${_account.generation}'),
      overlay: _overlay,
      session: widget.session,
      accountManager: _account,
      themeMode: _themeMode,
      onThemeModeChanged: _changeThemeMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LocaleScope(
      controller: _locale,
      child: AnimatedBuilder(
        animation: _locale,
        builder: (BuildContext context, Widget? child) {
          final Locale titleLocale =
              _locale.locale ??
              WidgetsBinding.instance.platformDispatcher.locale;
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
            // 浮层与 Navigator 同级且绘制在其上：聊天页 push 后仍可见。
            // SystemUiStyleScope 放在 Theme 之下，系统导航栏随外观切换，
            // 避免深色界面底部残留白色系统条。
            builder: (BuildContext context, Widget? child) {
              return SystemUiStyleScope(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (child != null) Positioned.fill(child: child),
                    Positioned.fill(child: AppOverlayHost(controller: _overlay)),
                  ],
                ),
              );
            },
            home: Listener(
              onPointerDown: (_) => _account.recordActivity(),
              child: _buildHome(),
            ),
          );
        },
      ),
    );
  }
}
