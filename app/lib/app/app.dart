import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../features/settings/settings_service.dart';
import 'core_session.dart';
import 'shell.dart';
import 'theme.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(_restoreTheme());
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
    return MaterialApp(
      title: 'Nexmem',
      debugShowCheckedModeBanner: false,
      theme: NexmemTheme.light(),
      darkTheme: NexmemTheme.dark(),
      themeMode: _themeMode,
      home: AppShell(
        session: widget.session,
        themeMode: _themeMode,
        onThemeModeChanged: _changeThemeMode,
      ),
    );
  }
}
