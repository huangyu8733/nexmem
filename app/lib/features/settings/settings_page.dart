import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../transport/transport.dart';
import 'backup.dart';
import 'diagnostics.dart';
import 'relay_settings.dart';
import 'report.dart';
import 'settings_service.dart';
import 'settings_sync.dart';
import 'storage_config.dart';

/// 客户端版本号，与 pubspec.yaml 的 `version` 保持一致。
const String appVersion = '1.0.0';

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
    this.webOnlineOnly = false,
    this.coreInfo,
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

  /// Web 端常驻「仅在线接收」说明（ui-spec.md §5 / §7）。
  final bool webOnlineOnly;

  /// 内核版本与能力（P6-29）；为 null 表示内核未接入或协商失败。
  final CoreInfo? coreInfo;

  static const List<(IconData, String)> _items = <(IconData, String)>[
    (Icons.shield_outlined, '账号与安全'),
    (Icons.sync_outlined, '多设备同步'),
    (Icons.wifi_tethering, '网络'),
    (Icons.cloud_outlined, '离线存储'),
    (Icons.palette_outlined, '外观'),
    (Icons.info_outline, '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const PaneHeader(title: '我的'),
        Expanded(
          child: ListView(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(NexmemMetrics.space12),
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
                      CircleAvatar(
                        radius: NexmemMetrics.avatarSize / 2,
                        backgroundColor: scheme.onSurface.withValues(
                          alpha: 0.08,
                        ),
                        child: Icon(
                          Icons.person_outline,
                          size: 24,
                          color: scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                      const SizedBox(width: NexmemMetrics.space12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              _accountTitle(account),
                              key: const ValueKey<String>(
                                'settings-account-name',
                              ),
                              style: Theme.of(context).textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_accountMeta(account) case final String meta)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  meta,
                                  key: const ValueKey<String>(
                                    'settings-account-meta',
                                  ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
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
                          '仅在线接收：浏览器关闭后不再实时接收消息，离线消息将在下次打开时补齐。',
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
                    title: Text(label),
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

  static String _itemKey(String label) {
    switch (label) {
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
      case '关于':
        return 'about';
      default:
        return label;
    }
  }

  void _open(BuildContext context, String label) {
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

/// 账号卡片标题：昵称优先，其次账号 ID 缩略；未接入内核时保持离线占位。
String _accountTitle(CoreAccount? account) {
  if (account == null) {
    return '未登录设备';
  }
  final String name = account.displayName.trim();
  if (name.isNotEmpty) {
    return name;
  }
  return account.accountId.isEmpty ? '本机设备' : _shortId(account.accountId);
}

/// 账号卡片副标题：`账号 xxx · 设备 xxx`；两者都缺失时返回 null。
String? _accountMeta(CoreAccount? account) {
  if (account == null) {
    return null;
  }
  final List<String> parts = <String>[];
  if (account.accountId.isNotEmpty) {
    parts.add('账号 ${_shortId(account.accountId)}');
  }
  if (account.deviceId.isNotEmpty) {
    parts.add('设备 ${_shortId(account.deviceId)}');
  }
  return parts.isEmpty ? null : parts.join(' · ');
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
      title: const Text('外观'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final (ThemeMode option, String label, IconData icon)
                in _options)
              ListTile(
                key: ValueKey<String>('appearance-${_optionKey(option)}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon, size: 22),
                title: Text(label),
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
          child: const Text('关闭'),
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
  });

  final DiagnosticsService diagnostics;
  final PingService ping;
  final SettingsService settings;

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
            ? '内核尚未接入，无法自检'
            : '自检失败（${error.code}）';
        _pinging = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pingError = '自检失败，请稍后再试';
        _pinging = false;
      });
    }
  }

  /// 打开中继设置（P6-20）；保存后由对话框自身提示「重启后生效」。
  void _openRelay() {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          RelaySettingsDialog(service: widget.settings),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('网络诊断'),
      content: SizedBox(
        width: 360,
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
                      return Text(_errorText(snapshot.error));
                    }
                    final DiagnosticsSnapshot data = snapshot.data!;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _row('在线时长', data.uptimeText),
                        _row(
                          'DHT 寻址',
                          '${data.dhtLookups} 次 · 失败 ${data.dhtErrors}',
                        ),
                        _row('DHT 耗时', data.dhtLatencyText),
                        _row('打洞结果', data.holePunchText),
                        _row('S3 状态码', data.s3Text),
                        _row(
                          '日志缓冲',
                          '${data.logRecords} 条 · 丢弃 ${data.logDropped}',
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
              title: const Text('连接自检'),
              subtitle: Text(
                _pingError ??
                    _pingResult?.summary ??
                    '测试内核连接与往返延迟',
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
                      child: const Text('测试'),
                    ),
            ),
            ListTile(
              key: const ValueKey<String>('settings-network-relay'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.alt_route, size: 20),
              title: const Text('中继设置'),
              subtitle: const Text(
                '直连失败时经中继兜底，默认关闭',
                style: TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: _openRelay,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _refresh, child: const Text('刷新')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
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
      messenger.showSnackBar(SnackBar(content: Text('诊断包已导出：$path')));
    } on NexmemException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'NOT_STARTED' ? '诊断能力尚未接入内核' : '诊断导出失败（${e.code}），请稍后再试',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('诊断导出失败，请稍后再试')));
    }
  }

  Future<void> _report(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? submitted = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          ReportDialog(reportSink: reportSink, diagnostics: diagnostics),
    );
    if (submitted == true) {
      messenger.showSnackBar(const SnackBar(content: Text('举报已提交，感谢反馈')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('关于 Nexmem'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '版本 $appVersion',
                key: const ValueKey<String>('about-client-version'),
              ),
              const SizedBox(height: NexmemMetrics.space4),
              Text(
                coreInfo == null
                    ? '内核版本 未知'
                    : '内核 ${coreInfo!.coreVersion.isEmpty ? '未知' : coreInfo!.coreVersion}',
                key: const ValueKey<String>('about-core-version'),
              ),
              if (coreInfo != null && coreInfo!.apiVersion.isNotEmpty)
                Text(
                  'API ${coreInfo!.apiVersion} · 已接入 ${coreInfo!.features.length} 项能力',
                  key: const ValueKey<String>('about-api-version'),
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              if (coreInfo != null && !coreInfo!.apiMajorCompatible)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space4),
                  child: Text(
                    '内核 API 主版本与客户端不一致，部分功能可能不可用',
                    key: const ValueKey<String>('about-api-incompatible'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              const SizedBox(height: NexmemMetrics.space8),
              Text(
                '去中心化 P2P 即时通讯，消息端到端加密。',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              ListTile(
                key: const ValueKey<String>('about-export'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description_outlined, size: 22),
                title: const Text('诊断导出'),
                subtitle: const Text('导出脱敏日志用于排障'),
                onTap: () => _export(context),
              ),
              ListTile(
                key: const ValueKey<String>('about-report'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.flag_outlined, size: 22),
                title: const Text('举报与反馈'),
                subtitle: const Text('可附脱敏诊断日志'),
                onTap: () => _report(context),
              ),
              ListTile(
                key: const ValueKey<String>('about-license'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.article_outlined, size: 22),
                title: const Text('开源许可'),
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
          child: const Text('关闭'),
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

String _errorText(Object? error) {
  if (error is NexmemException) {
    if (error.code == 'NOT_STARTED') {
      return '诊断能力尚未接入内核';
    }
    return '读取诊断指标失败（${error.code}）';
  }
  return '读取诊断指标失败，请稍后再试';
}
