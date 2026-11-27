import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/nexmem_logo.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import '../account/account_manager.dart';
import '../account/account_manager_page.dart';
import '../account/app_exit.dart';
import 'developer_settings.dart';
import '../social/social_hub_page.dart';
import '../push/push_controller.dart';
import '../push/push_settings_dialog.dart';
import '../permissions/permissions_pane.dart';
import '../remote/remote_settings_page.dart';
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
    this.accountManager,
    this.push,
    this.profileOnly = false,
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

  /// 账号管理/临时锁入口所需的本机账号管理器。
  final AccountManager? accountManager;

  /// 消息通知设置；为空时设置页不展示对应面板。
  final PushController? push;

  /// 拆分模式：「我的」只展示账号卡片与个人资料，普通设置为纯菜单列表。
  final bool profileOnly;

  /// 点击账号卡片：打开只读资料展示。为空时退回本地弹窗（兼容独立使用）。
  final VoidCallback? onOpenProfileView;

  /// 点击设置列表项：由外层决定在右栏 / 全屏页展示对应面板。
  /// 参数为菜单 label；为空时退回原有弹窗行为（兼容独立使用）。
  final ValueChanged<String>? onOpenPane;

  /// 「我的」页放资料与账号相关入口；其余系统项归入底部「设置」。
  static const List<(IconData, String)> _profileItems = <(IconData, String)>[
    (Icons.badge_outlined, '个人资料'),
    (Icons.devices_other_outlined, '远程设备'),
    (Icons.radar, '账号发现'),
    (Icons.groups, '社交中心'),
    (Icons.shield_outlined, '账号与安全'),
    (Icons.manage_accounts_outlined, '账号管理'),
    (Icons.lock_outline, '临时锁'),
    (Icons.exit_to_app, '退出应用'),
  ];

  static const List<(IconData, String)> _settingsItems = <(IconData, String)>[
    (Icons.sync_outlined, '多设备同步'),
    (Icons.desktop_windows_outlined, '远程控制'),
    (Icons.notifications_none, '消息通知'),
    (Icons.verified_user_outlined, '权限管理'),
    (Icons.wifi_tethering, '网络'),
    (Icons.cloud_outlined, '离线存储'),
    (Icons.palette_outlined, '外观'),
    (Icons.language, '语言'),
    (Icons.info_outline, '关于'),
    (Icons.code, '开发者'),
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
        PaneHeader(title: context.t(profileOnly ? '我的' : '设置')),
        Expanded(
          child: ListView(
            children: <Widget>[
              if (profileOnly)
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
              if (webOnlineOnly && !profileOnly)
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
              for (final (IconData icon, String label)
                  in (profileOnly ? _profileItems : _settingsItems))
                SizedBox(
                  height: NexmemMetrics.listItemHeight,
                  child: ListTile(
                    key: ValueKey<String>('settings-${_itemKey(label)}'),
                    // 与外层 SizedBox 同高，避免内容比卡片中心高 2px。
                    minTileHeight: NexmemMetrics.listItemHeight,
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
    // 社交中心是铺满内容页，不是对话框：独立使用本页时也要走普通页面路由，
    // 否则 showDialog 会额外套一层居中白卡和灰色 barrier。
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext routeContext) => Scaffold(
            appBar: AppBar(title: Text(routeContext.t('社交中心'))),
            body: SafeArea(
              child: SocialHubPage(session: session, showHeader: false),
            ),
          ),
        ),
      ),
    );
  }

  static String _itemKey(String label) {
    switch (label) {
      case '社交中心':
        return 'social-hub';
      case '个人资料':
        return 'profile';
      case '远程设备':
        return 'remote-devices';
      case '账号发现':
        return 'device-discovery';
      case '账号与安全':
        return 'account';
      case '账号管理':
        return 'account-manager';
      case '临时锁':
        return 'app-lock';
      case '退出应用':
        return 'exit-app';
      case '多设备同步':
        return 'device-sync';
      case '远程控制':
        return 'remote-control';
      case '消息通知':
        return 'push-notifications';
      case '权限管理':
        return 'permissions';
      case '网络':
        return 'network';
      case '离线存储':
        return 'storage';
      case '外观':
        return 'appearance';
      case '语言':
        return 'language';
      case '开发者':
        return 'developer';
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
    if (label == '远程设备') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('请从应用「我的」页打开远程设备'))),
      );
      return;
    }
    if (label == '账号发现') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('请从应用「我的」页打开账号发现'))),
      );
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
    if (label == '账号管理' || label == '临时锁') {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t('请从应用「我的」页打开账号管理'))),
      );
      return;
    }
    if (label == '退出应用') {
      showPaneDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(context.t('退出应用')),
          content: Text(context.t('确定要退出奈讯联吗？')),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.t('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.t('确定')),
            ),
          ],
        ),
      ).then((bool? confirmed) {
        if (confirmed == true) {
          unawaited(exitProcess());
        }
      });
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
    if (label == '远程控制') {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => const RemoteSettingsPage(),
      );
      return;
    }
    if (label == '权限管理') {
      unawaited(showPaneDialog<void>(
        context: context,
        builder: (BuildContext context) => const PermissionsPane(),
      ));
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
      return;
    }
    if (label == '开发者') {
      unawaited(showPaneDialog<void>(
        context: context,
        builder: (BuildContext context) => DeveloperPane(
          settings: settings,
          push: push,
        ),
      ));
    }
  }
}

/// 为设置列表项生成可嵌入面板的对话框内容构建器。
///
/// 桌面右栏与手机全屏页共用：把原本独立的 AlertDialog 放进
/// `EmbeddedSettingsPane`，复用既有交互与内核服务，无需弹框。
WidgetBuilder settingsPaneBuilder({
  required String label,
  PushController? push,
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
  AccountManager? accountManager,
}) {
  switch (label) {
    case '社交中心':
      return (BuildContext context) => session == null
          ? const SizedBox.shrink()
          : SocialHubPage(session: session, showHeader: false);
    case '账号与安全':
      return (BuildContext context) => AccountSecurityDialog(backup: backup);
    case '账号管理':
    case '临时锁':
      return (BuildContext context) => accountManager == null
          ? const SizedBox.shrink()
          : AccountManagerPage(
              manager: accountManager,
              focusLock: label == '临时锁',
            );
    case '退出应用':
      return (BuildContext context) => _ExitPane(manager: accountManager);
    case '多设备同步':
      return (BuildContext context) => SettingsSyncDialog(settings: settings);
    case '远程控制':
      return (BuildContext context) => const RemoteSettingsPage();
    case '消息通知':
      return (BuildContext context) => push == null
          ? const SizedBox.shrink()
          : PushSettingsPane(controller: push, showHeader: false);
    case '权限管理':
      return (BuildContext context) => const PermissionsPane(showHeader: false);
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
            closeOnSelect: false,
          );
    case '语言':
      return (BuildContext context) =>
          const LanguageDialog(closeOnSelect: false);
    case '开发者':
      return (BuildContext context) => DeveloperPane(
            settings: settings,
            push: push,
            showHeader: false,
          );
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

/// 「退出应用」面板：桌面/移动端直接请求关闭进程，Web 端展示退出页。
class _ExitPane extends StatelessWidget {
  const _ExitPane({this.manager});

  final AccountManager? manager;

  Future<void> _exit() async {
    await manager?.exitApp();
    await exitProcess();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.exit_to_app, size: 48, color: scheme.primary),
            const SizedBox(height: NexmemMetrics.space16),
            Text(
              context.t('退出应用'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: NexmemMetrics.space8),
            Text(
              context.t('退出后需要重新进入应用，本地账号数据会保留'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: NexmemMetrics.space24),
            FilledButton.icon(
              key: const ValueKey<String>('exit-app-confirm'),
              onPressed: () => unawaited(_exit()),
              icon: const Icon(Icons.logout),
              label: Text(context.t('退出应用')),
            ),
          ],
        ),
      ),
    );
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
/// [closeOnSelect] 为 true（独立弹窗）时，选择后立即关闭并把结果交给
/// [onChanged] 应用与持久化；为 false（桌面右栏 / 手机全屏内嵌面板）时，
/// 选完保留面板，只就地更新勾选态，避免整个「外观」界面消失。
class AppearanceDialog extends StatefulWidget {
  const AppearanceDialog({
    super.key,
    required this.mode,
    this.onChanged,
    this.closeOnSelect = true,
  });

  final ThemeMode mode;
  final ValueChanged<ThemeMode>? onChanged;

  /// 选择后是否关闭。内嵌面板传 false，让用户仍停留在外观界面。
  final bool closeOnSelect;

  static const List<(ThemeMode, String, IconData)> _options =
      <(ThemeMode, String, IconData)>[
        (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
        (ThemeMode.light, '浅色', Icons.light_mode_outlined),
        (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
      ];

  @override
  State<AppearanceDialog> createState() => _AppearanceDialogState();

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

class _AppearanceDialogState extends State<AppearanceDialog> {
  late ThemeMode _selected = widget.mode;

  @override
  void didUpdateWidget(covariant AppearanceDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _selected = widget.mode;
    }
  }

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
                in AppearanceDialog._options)
              ListTile(
                key: ValueKey<String>(
                    'appearance-${AppearanceDialog._optionKey(option)}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon, size: 22),
                title: Text(context.t(label)),
                trailing: option == _selected
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: () {
                  if (option != _selected) {
                    setState(() => _selected = option);
                    widget.onChanged?.call(option);
                  }
                  if (widget.closeOnSelect) {
                    Navigator.of(context).pop();
                  }
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
                  // 「关于」在窄屏是 SettingsPanePage，内部有独立 Navigator；
                  // 默认 useRootNavigator=false 会把 LicensePage push 进该内层
                  // 导航栈，与外层 AppBar 叠加成两个标题栏。用根导航器全屏覆盖。
                  useRootNavigator: true,
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
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 88),
          child: Text(
            label,
            maxLines: 2,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: NexmemMetrics.space8),
        Expanded(
          child: Text(
            value,
            key: ValueKey<String>('diag-$label'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
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
