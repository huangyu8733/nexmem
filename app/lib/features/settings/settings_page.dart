import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/nexmem_logo.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import '../social/social_hub_page.dart';
import '../updater/update_dialog.dart';
import 'backup.dart';
import 'diagnostics.dart';
import 'discovery_settings.dart';
import 'language_dialog.dart';
import 'relay_settings.dart';
import 'profile_avatar.dart';
import 'profile_panel.dart';
import 'profile_view.dart';
import 'settings_pane.dart';
import 'report.dart';
import 'scrolling_id_text.dart';
import 'settings_service.dart';
import 'settings_sync.dart';
import 'storage_config.dart';

/// 客户端版本号，与 pubspec.yaml 的 `version` 保持一致。
const String appVersion = '1.1.0';

/// 我的 / 设置（ui-spec.md §5）。
///
/// 账号卡片展示当前账号与设备；「网络」打开运行诊断（DHT 耗时、打洞结果、
/// S3 状态码），「账号与安全」提供加密备份导出/导入，「离线存储」提供
/// R2 / MinIO / OSS / COS 接入引导与连通性自检，「外观」切换主题模式，
/// 「关于」提供诊断导出与举报反馈入口；除账号卡片与外观外均依赖
/// `core.start` 注入的服务。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    this.account,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
    this.diagnostics = const UnavailableDiagnosticsService(),
    this.ping = const UnavailablePingService(),
    this.reportSink = const UnavailableReportSink(),
    this.backup = const UnavailableBackupService(),
    this.storage = const UnavailableStorageTestService(),
    this.settings = const UnavailableSettingsService(),
    this.session,
    this.webOnlineOnly = false,
    this.coreInfo,
    this.onOpenProfileView,
    this.onOpenPane,
  });

  /// 当前账号（`account.me`）；为空表示内核未启动或离线占位。
  final CoreAccount? account;

  /// 当前外观主题（P6-15）。
  final ThemeMode themeMode;

  /// 切换外观主题；为空时只展示当前选择。
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  final DiagnosticsService diagnostics;

  /// 内核连接自检（P6-34）：`core.ping`。
  final PingService ping;
  final ReportSink reportSink;
  final BackupService backup;
  final StorageTestService storage;

  /// 本机键值设置（P6-15 / P6-20），用于中继开关等需要重启生效的配置。
  final SettingsService settings;

  /// 内核会话：用于发现源设置中读写本地地址簿；为空时隐藏手动地址区块。
  final CoreSession? session;

  /// Web 端常驻「仅在线接收」说明（ui-spec.md §5 / §7）。
  final bool webOnlineOnly;

  /// 内核版本与能力（P6-29）；为 null 表示内核未接入或协商失败。
  final CoreInfo? coreInfo;

  /// 点击账号卡片：打开只读资料展示。为空时退回本地弹窗（兼容独立使用）。
  final VoidCallback? onOpenProfileView;

  /// 点击设置列表项：由外层决定在右栏 / 全屏页展示对应面板。
  /// 参数为菜单 label；为空时退回原有弹窗行为（兼容独立使用）。
  final ValueChanged<String>? onOpenPane;

  static const List<(IconData, String)> _items = <(IconData, String)>[
    (Icons.groups, '社交中心'),
    (Icons.badge_outlined, '个人资料'),
    (Icons.shield_outlined, '账号与安全'),
    (Icons.sync_outlined, '多设备同步'),
    (Icons.wifi_tethering, '网络'),
    (Icons.cloud_outlined, '离线存储'),
    (Icons.palette_outlined, '外观'),
    (Icons.language, '语言'),
    (Icons.info_outline, '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final CoreAccount? account = this.account;
    final String accountId = account?.accountId ?? '';
    final String deviceId = account?.deviceId ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(title: context.t('我的')),
        Expanded(
          child: ListView(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(NexmemMetrics.space12),
                child: InkWell(
                  key: const ValueKey<String>('settings-profile-card'),
                  onTap: () => _openProfileView(context),
                  borderRadius: BorderRadius.circular(
                    NexmemMetrics.radiusListItem,
                  ),
                  child: Container(
                  padding: const EdgeInsets.all(NexmemMetrics.space16),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(
                      NexmemMetrics.radiusListItem,
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      const SelfAvatar(iconSize: 24),
                      const SizedBox(width: NexmemMetrics.space12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            _AccountName(
                              account: account,
                              settings: settings,
                            ),
                            if (accountId.isNotEmpty)
                              ScrollingIdText(
                                text: accountId,
                                keyName: 'settings-account-id-full',
                                label: context.t('账号'),
                                onCopy: () => _copyId(context, accountId, '账号'),
                                copyKeyName: 'settings-copy-account',
                              ),
                            if (deviceId.isNotEmpty)
                              ScrollingIdText(
                                text: deviceId,
                                keyName: 'settings-device-id-full',
                                label: context.t('设备'),
                                onCopy: () => _copyId(context, deviceId, '设备'),
                                copyKeyName: 'settings-copy-device',
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  ),
                ),
              ),
              if (webOnlineOnly)
                Container(
                  key: const ValueKey<String>('settings-web-online-only'),
                  margin: const EdgeInsets.fromLTRB(
                    NexmemMetrics.space12,
                    0,
                    NexmemMetrics.space12,
                    NexmemMetrics.space12,
                  ),
                  padding: const EdgeInsets.all(NexmemMetrics.space12),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(
                      NexmemMetrics.radiusListItem,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.public_off, size: 18, color: scheme.primary),
                      const SizedBox(width: NexmemMetrics.space8),
                      Expanded(
                        child: Text(
                          context.t('仅在线接收：浏览器关闭后不再实时接收消息，离线消息将在下次打开时补齐。'),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 1),
              for (final (IconData icon, String label) in _items)
                SizedBox(
                  height: NexmemMetrics.listItemHeight,
                  child: ListTile(
                    key: ValueKey<String>('settings-${_itemKey(label)}'),
                    leading: Icon(icon, size: 22),
                    title: Text(context.t(label)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _open(context, label),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 复制账号/设备完整值并给出提示。文案在 await 之前取好。
  static Future<void> _copyId(
    BuildContext context,
    String value,
    String label,
  ) async {
    if (value.isEmpty) {
      return;
    }
    final String message = context.t('{0}已复制', [label]);
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _openSocialHub(BuildContext context) {
    final CoreSession? session = this.session;
    if (session == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('内核尚未启动，社交功能暂不可用'))),
      );
      return;
    }
    unawaited(
      showPaneDialog<void>(
        context: context,
        builder: (BuildContext context) => SocialHubPage(session: session),
      ),
    );
  }

  static String _itemKey(String label) {
    switch (label) {
      case '社交中心':
        return 'social-hub';
      case '个人资料':
        return 'profile';
      case '账号与安全':
        return 'account';
      case '多设备同步':
        return 'device-sync';
      case '网络':
        return 'network';
      case '离线存储':
        return 'storage';
      case '外观':
        return 'appearance';
      case '语言':
        return 'language';
      case '关于':
        return 'about';
      default:
        return label;
    }
  }

  /// 账号卡片：只读资料展示。外层接入回调后由壳层在右栏 / 全屏页呈现；
  /// 独立使用（Widget 测试等）时退回对话框。
  void _openProfileView(BuildContext context) {
    final VoidCallback? callback = onOpenProfileView;
    if (callback != null) {
      callback();
      return;
    }
    unawaited(
      showProfileViewDialog(
        context: context,
        account: account,
        settings: settings,
      ),
    );
  }

  /// 「个人资料」菜单进入编辑面板。
  void _openProfile(BuildContext context) {
    unawaited(
      showProfileEditorDialog(
        context: context,
        account: account,
        settings: settings,
      ),
    );
  }

  void _open(BuildContext context, String label) {
    final ValueChanged<String>? callback = onOpenPane;
    if (callback != null) {
      callback(label);
      return;
    }
    if (label == '社交中心') {
      _openSocialHub(context);
      return;
    }
    if (label == '个人资料') {
      _openProfile(context);
      return;
    }
    if (label == '账号与安全') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            AccountSecurityDialog(backup: backup),
      );
      return;
    }
    if (label == '多设备同步') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            SettingsSyncDialog(settings: settings),
      );
      return;
    }
    if (label == '网络') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => _NetworkDiagnosticsDialog(
          diagnostics: diagnostics,
          ping: ping,
          settings: settings,
        ),
      );
      return;
    }
    if (label == '离线存储') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            StorageConfigDialog(service: storage),
      );
      return;
    }
    if (label == '外观') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            AppearanceDialog(mode: themeMode, onChanged: onThemeModeChanged),
      );
      return;
    }
    if (label == '语言') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => const LanguageDialog(),
      );
      return;
    }
    if (label == '关于') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => _AboutDialog(
          diagnostics: diagnostics,
          reportSink: reportSink,
          coreInfo: coreInfo,
        ),
      );
    }
  }
}

/// 为设置列表项生成可嵌入面板的对话框内容构建器。
///
/// 桌面右栏与手机全屏页共用：把原本独立的 AlertDialog 放进
/// `EmbeddedSettingsPane`，复用既有交互与内核服务，无需弹框。
WidgetBuilder settingsPaneBuilder({
  required String label,
  required BackupService backup,
  required SettingsService settings,
  required DiagnosticsService diagnostics,
  required PingService ping,
  required StorageTestService storage,
  required ThemeMode themeMode,
  ValueChanged<ThemeMode>? onThemeModeChanged,
  required ReportSink reportSink,
  CoreInfo? coreInfo,
  CoreSession? session,
}) {
  switch (label) {
    case '社交中心':
      return (BuildContext context) => session == null
          ? const SizedBox.shrink()
          : SocialHubPage(session: session, showHeader: false);
    case '账号与安全':
      return (BuildContext context) => AccountSecurityDialog(backup: backup);
    case '多设备同步':
      return (BuildContext context) => SettingsSyncDialog(settings: settings);
    case '网络':
      return (BuildContext context) => _NetworkDiagnosticsDialog(
            diagnostics: diagnostics,
            ping: ping,
            settings: settings,
            session: session,
          );
    case '离线存储':
      return (BuildContext context) => StorageConfigDialog(service: storage);
    case '外观':
      return (BuildContext context) => AppearanceDialog(
            mode: themeMode,
            onChanged: onThemeModeChanged,
          );
    case '语言':
      return (BuildContext context) => const LanguageDialog();
    case '关于':
      return (BuildContext context) => _AboutDialog(
            diagnostics: diagnostics,
            reportSink: reportSink,
            coreInfo: coreInfo,
          );
    default:
      return (BuildContext context) => const SizedBox.shrink();
  }
}

/// 账号卡片标题：个人资料昵称优先，回落内核昵称或账号 ID 缩略。
class _AccountName extends StatelessWidget {
  const _AccountName({required this.account, required this.settings});

  final CoreAccount? account;
  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: settings.read(profileNicknameSettingKey),
      builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
        final String? nickname = snapshot.data?.trim();
        final String title = nickname != null && nickname.isNotEmpty
            ? nickname
            : _accountTitle(context, account);
        return Text(
          title,
          key: const ValueKey<String>('settings-account-name'),
          style: Theme.of(context).textTheme.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// 账号卡片标题：昵称优先，其次账号 ID 缩略；未接入内核时保持离线占位。
String _accountTitle(BuildContext context, CoreAccount? account) {
  if (account == null) {
    return context.t('未登录设备');
  }
  final String name = account.displayName.trim();
  if (name.isNotEmpty) {
    return name;
  }
  return account.accountId.isEmpty
      ? context.t('本机设备')
      : _shortId(account.accountId);
}

/// 十六进制 ID 缩略：保留前 10 位，避免撑破移动端卡片宽度。
String _shortId(String id) => id.length <= 14 ? id : '${id.substring(0, 10)}…';

/// 外观：浅色 / 深色 / 跟随系统（ui-spec.md §5）。
///
/// 选择后立即关闭弹窗并通过 [onChanged] 交给 [NexmemApp] 应用与持久化。
class AppearanceDialog extends StatelessWidget {
  const AppearanceDialog({super.key, required this.mode, this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode>? onChanged;

  static const List<(ThemeMode, String, IconData)> _options =
      <(ThemeMode, String, IconData)>[
        (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
        (ThemeMode.light, '浅色', Icons.light_mode_outlined),
        (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
      ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('外观')),
      content: responsiveDialogContent(
        maxWidth: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final (ThemeMode option, String label, IconData icon)
                in _options)
              ListTile(
                key: ValueKey<String>('appearance-${_optionKey(option)}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon, size: 22),
                title: Text(context.t(label)),
                trailing: option == mode
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: () {
                  onChanged?.call(option);
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('关闭')),
        ),
      ],
    );
  }

  static String _optionKey(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

/// 网络诊断：展示 DHT 寻址耗时、打洞结果与 S3 状态码（ui-spec.md §5）。
class _NetworkDiagnosticsDialog extends StatefulWidget {
  const _NetworkDiagnosticsDialog({
    required this.diagnostics,
    required this.ping,
    required this.settings,
    this.session,
  });

  final DiagnosticsService diagnostics;
  final PingService ping;
  final SettingsService settings;
  final CoreSession? session;

  @override
  State<_NetworkDiagnosticsDialog> createState() =>
      _NetworkDiagnosticsDialogState();
}

class _NetworkDiagnosticsDialogState extends State<_NetworkDiagnosticsDialog> {
  late Future<DiagnosticsSnapshot> _future;

  /// 连接自检状态（P6-34）：null 表示尚未自检。
  PingResult? _pingResult;
  String? _pingError;
  bool _pinging = false;

  @override
  void initState() {
    super.initState();
    _future = widget.diagnostics.snapshot();
  }

  void _refresh() {
    setState(() => _future = widget.diagnostics.snapshot());
  }

  /// 调用 `core.ping` 测内核往返，结果就地展示（P6-34）。
  Future<void> _runPing() async {
    if (_pinging) {
      return;
    }
    setState(() {
      _pinging = true;
      _pingError = null;
    });
    try {
      final PingResult result = await widget.ping.ping();
      if (!mounted) {
        return;
      }
      setState(() {
        _pingResult = result;
        _pinging = false;
      });
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pingError = error.code == 'NOT_STARTED'
            ? context.t('内核尚未接入，无法自检')
            : context.t('自检失败（{0}）', [error.code]);
        _pinging = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pingError = context.t('自检失败，请稍后再试');
        _pinging = false;
      });
    }
  }

  /// 打开中继设置（P6-20）；保存后由对话框自身提示「重启后生效」。
  void _openRelay() {
    showPaneDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          RelaySettingsDialog(service: widget.settings),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('网络诊断')),
      content: responsiveDialogContent(
        maxWidth: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FutureBuilder<DiagnosticsSnapshot>(
              future: _future,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<DiagnosticsSnapshot> snapshot,
                  ) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return Text(_errorText(context, snapshot.error));
                    }
                    final DiagnosticsSnapshot data = snapshot.data!;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _row(context.t('在线时长'), data.uptimeText),
                        _row(
                          context.t('DHT 寻址'),
                          context.t('{0} 次 · 失败 {1}', [data.dhtLookups, data.dhtErrors]),
                        ),
                        _row(context.t('DHT 耗时'), data.dhtLatencyText),
                        _row(context.t('打洞结果'), data.holePunchText),
                        _row(context.t('S3 状态码'), data.s3Text),
                        _row(
                          context.t('日志缓冲'),
                          context.t('{0} 条 · 丢弃 {1}', [data.logRecords, data.logDropped]),
                        ),
                      ],
                    );
                  },
            ),
            const Divider(height: NexmemMetrics.space16),
            ListTile(
              key: const ValueKey<String>('settings-network-ping'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.network_ping, size: 20),
              title: Text(context.t('连接自检')),
              subtitle: Text(
                _pingError ??
                    _pingResult?.summary ??
                    context.t('测试内核连接与往返延迟'),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: _pinging
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: _runPing,
                      child: Text(context.t('测试')),
                    ),
            ),
            ListTile(
              key: const ValueKey<String>('settings-network-relay'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.alt_route, size: 20),
              title: Text(context.t('中继设置')),
              subtitle: Text(
                context.t('直连失败时经中继兜底，默认关闭'),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: _openRelay,
            ),
            ListTile(
              key: const ValueKey<String>('settings-network-discovery'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.travel_explore, size: 20),
              title: Text(context.t('发现源设置')),
              subtitle: Text(
                context.t('局域网发现、公共 DHT 与手动地址，三者可并存'),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () {
                showPaneDialog<void>(
                  context: context,
                  builder: (BuildContext context) => DiscoverySettingsDialog(
                    service: widget.settings,
                    session: widget.session,
                  ),
                );
              },
            ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _refresh, child: Text(context.t('刷新'))),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('关闭')),
        ),
      ],
    );
  }
}

/// 关于：版本、开源许可、诊断导出与举报反馈。
class _AboutDialog extends StatelessWidget {
  const _AboutDialog({
    required this.diagnostics,
    required this.reportSink,
    this.coreInfo,
  });

  final DiagnosticsService diagnostics;
  final ReportSink reportSink;
  final CoreInfo? coreInfo;

  Future<void> _export(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final String path = await diagnostics.exportBundle();
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('诊断包已导出：{0}', [path]))),
      );
    } on NexmemException catch (e) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'NOT_STARTED'
                ? context.t('诊断能力尚未接入内核')
                : context.t('诊断导出失败（{0}），请稍后再试', [e.code]),
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('诊断导出失败，请稍后再试'))),
      );
    }
  }

  Future<void> _report(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? submitted = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          ReportDialog(reportSink: reportSink, diagnostics: diagnostics),
    );
    if (submitted == true) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('举报已提交，感谢反馈'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(context.t('关于 Nexmem')),
      content: responsiveDialogContent(
        maxWidth: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(child: NexmemBrand(name: context.t('奈讯联'))),
              const SizedBox(height: NexmemMetrics.space12),
              Text(
                context.t('版本 {0}', [appVersion]),
                key: const ValueKey<String>('about-client-version'),
              ),
              const SizedBox(height: NexmemMetrics.space4),
              Text(
                coreInfo == null
                    ? context.t('内核版本 未知')
                    : context.t('内核 {0}', [
                        coreInfo!.coreVersion.isEmpty
                            ? context.t('未知')
                            : coreInfo!.coreVersion,
                      ]),
                key: const ValueKey<String>('about-core-version'),
              ),
              if (coreInfo != null && coreInfo!.apiVersion.isNotEmpty)
                Text(
                  context.t('API {0} · 已接入 {1} 项能力', [
                    coreInfo!.apiVersion,
                    coreInfo!.features.length,
                  ]),
                  key: const ValueKey<String>('about-api-version'),
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              if (coreInfo != null && !coreInfo!.apiMajorCompatible)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space4),
                  child: Text(
                    context.t('内核 API 主版本与客户端不一致，部分功能可能不可用'),
                    key: const ValueKey<String>('about-api-incompatible'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              const SizedBox(height: NexmemMetrics.space8),
              Text(
                context.t('去中心化 P2P 即时通讯，消息端到端加密。'),
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              ListTile(
                key: const ValueKey<String>('about-update'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.system_update, size: 22),
                title: Text(context.t('检查更新')),
                subtitle: Text(context.t('从 GitHub 检查并下载新版安装包')),
                onTap: () => showUpdateDialog(context, appVersion),
              ),
              ListTile(
                key: const ValueKey<String>('about-export'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description_outlined, size: 22),
                title: Text(context.t('诊断导出')),
                subtitle: Text(context.t('导出脱敏日志用于排障')),
                onTap: () => _export(context),
              ),
              ListTile(
                key: const ValueKey<String>('about-report'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.flag_outlined, size: 22),
                title: Text(context.t('举报与反馈')),
                subtitle: Text(context.t('可附脱敏诊断日志')),
                onTap: () => _report(context),
              ),
              ListTile(
                key: const ValueKey<String>('about-license'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.article_outlined, size: 22),
                title: Text(context.t('开源许可')),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Nexmem',
                  applicationVersion: appVersion,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('关闭')),
        ),
      ],
    );
  }
}

Widget _row(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 88,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Text(
            value,
            key: ValueKey<String>('diag-$label'),
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

String _errorText(BuildContext context, Object? error) {
  if (error is NexmemException) {
    if (error.code == 'NOT_STARTED') {
      return context.t('诊断能力尚未接入内核');
    }
    return context.t('读取诊断指标失败（{0}）', [error.code]);
  }
  return context.t('读取诊断指标失败，请稍后再试');
}
