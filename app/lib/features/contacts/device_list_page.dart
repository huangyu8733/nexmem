import 'package:material_ui/material_ui.dart';

import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import 'contact_service.dart';

/// 设备列表页（P6-21，ui-spec.md §4/§7）：展示账号已发布的设备证书。
///
/// 数据全部来自索引服务的公开档案：`peer` 为空表示本机账号（「我的设备」），
/// 好友资料页传入对方账号 ID。未接入索引服务时由内核返回 `NOT_STARTED`，
/// 页面给出明确提示而不是空白列表。
class DeviceListPage extends StatefulWidget {
  const DeviceListPage({
    super.key,
    required this.service,
    this.peer,
    this.title = '我的设备',
    this.embedded = false,
  });

  final ContactService service;

  /// 目标账号 ID；为空表示本机账号。
  final String? peer;

  final String title;

  /// 为 true 时以面板形式渲染（桌面右栏 / 手机全屏页复用），不套 Scaffold。
  final bool embedded;

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  bool _loading = true;
  String? _error;
  DeviceListResult _result = const DeviceListResult.empty();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final DeviceListResult result =
          await widget.service.devices(peer: widget.peer);
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _loading = false;
      });
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.isEmpty ? error.code : error.message;
      });
    }
  }

  List<Widget> get _actions => <Widget>[
        IconButton(
          key: const ValueKey<String>('device-refresh'),
          tooltip: context.t('刷新设备列表'),
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: _loading ? null : _reload,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader(title: context.t(widget.title), actions: _actions),
          Expanded(child: _buildBody(context)),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.t(widget.title)), actions: _actions),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _DeviceEmpty(
        icon: Icons.cloud_off_outlined,
        title: context.t('设备列表读取失败'),
        message: _error!,
        action: FilledButton.tonal(
          onPressed: _reload,
          child: Text(context.t('重试')),
        ),
      );
    }
    if (_result.items.isEmpty) {
      return _DeviceEmpty(
        icon: Icons.devices_other_outlined,
        title: context.t(_result.found ? '暂无可显示的设备' : '尚未发布设备信息'),
        message: context.t(_result.found
            ? '档案里的设备证书都已过期或被移除，设备重新上线后会自动补回。'
            : '该账号还没有把档案发布到索引服务，未配置索引服务时也会出现此提示。'),
        action: FilledButton.tonal(
          onPressed: _reload,
          child: Text(context.t('重新检查')),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: NexmemMetrics.space8),
      itemCount: _result.items.length + 1,
      separatorBuilder: (BuildContext _, int _) =>
          const Divider(height: 1, indent: 72),
      itemBuilder: (BuildContext context, int index) {
        if (index == _result.items.length) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              NexmemMetrics.space16,
              NexmemMetrics.space12,
              NexmemMetrics.space16,
              NexmemMetrics.space24,
            ),
            child: Text(
              context.t('设备信息来自账号公开档案，最多显示 16 台；「最近活跃」取该设备最近一次发布档案的时间。'),
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
        return DeviceTile(device: _result.items[index]);
      },
    );
  }
}

/// 单台设备条目；好友资料页内联展示时复用（`dense: true`）。
class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.device, this.dense = false});

  final DeviceInfo device;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> lines = <String>[
      if (device.deviceId.isNotEmpty)
        context.t('设备 {0}', [_shortPeer(device.deviceId)]),
      deviceActiveLabel(device.issuedAt, context.l10n),
    ];
    return ListTile(
      dense: dense,
      leading: CircleAvatar(
        radius: dense ? 18 : 20,
        backgroundColor: scheme.primary.withValues(alpha: 0.12),
        child: Icon(
          device.current ? Icons.smartphone : Icons.devices_outlined,
          size: dense ? 18 : 20,
          color: scheme.primary,
        ),
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: dense ? 14 : 15),
            ),
          ),
          if (device.current) ...<Widget>[
            const SizedBox(width: NexmemMetrics.space8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                context.t('本机'),
                style: TextStyle(fontSize: 11, color: scheme.primary),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        lines.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
      ),
      trailing: device.notAfter == null
          ? null
          : Text(
              context.t('有效期至 {0}', [_dateLabel(device.notAfter!)]),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
            ),
    );
  }
}

/// 「最近活跃」文案：证书签发时间按距离现在的时间段展示。
String deviceActiveLabel(DateTime? at, [AppLocalizations? l10n]) {
  String t(String key, [List<Object?> args = const <Object?>[]]) {
    final String? translated = l10n?.t(key, args);
    if (translated != null) return translated;
    String text = key;
    for (int i = 0; i < args.length; i++) {
      text = text.replaceAll('{$i}', '${args[i]}');
    }
    return text;
  }
  if (at == null) {
    return t('最近活跃未知');
  }
  final Duration diff = DateTime.now().difference(at);
  if (diff.isNegative || diff.inMinutes < 1) {
    return t('刚刚活跃');
  }
  if (diff.inHours < 1) {
    return t('{0} 分钟前活跃', <Object?>[diff.inMinutes]);
  }
  if (diff.inDays < 1) {
    return t('{0} 小时前活跃', <Object?>[diff.inHours]);
  }
  if (diff.inDays < 30) {
    return t('{0} 天前活跃', <Object?>[diff.inDays]);
  }
  return t('{0} 活跃', <Object?>[_dateLabel(at)]);
}

String _dateLabel(DateTime at) {
  final DateTime local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

/// PeerID 展示短串：保留前 8 位与末 4 位，中间省略。
String _shortPeer(String id) {
  if (id.length <= 14) {
    return id;
  }
  return '${id.substring(0, 8)}…${id.substring(id.length - 4)}';
}

class _DeviceEmpty extends StatelessWidget {
  const _DeviceEmpty({
    required this.icon,
    required this.title,
    required this.message,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NexmemMetrics.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: scheme.onSurface.withValues(alpha: 0.4)),
            const SizedBox(height: NexmemMetrics.space12),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: NexmemMetrics.space8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: NexmemMetrics.space16),
            action,
          ],
        ),
      ),
    );
  }
}
