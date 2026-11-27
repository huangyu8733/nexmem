import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import 'settings_service.dart';

/// 中继开关设置键（P6-20），值为 `true` / `false`。
const String relayEnabledSettingKey = 'net.relay_enabled';

/// 中继地址设置键（P6-20），多行分隔的 libp2p multiaddr。
const String relayAddrsSettingKey = 'net.relay_addrs';

/// 官方公共中继节点（README「完整多地址」的主/备 relay）。
///
/// 首次启动、用户尚未保存过中继配置时默认开启并预填这两个地址，开箱即用；
/// 用户显式保存过（哪怕关闭或清空）则完全尊重用户选择，不再回落默认值。
const List<String> defaultRelayAddrs = <String>[
  '/ip4/103.119.14.14/tcp/14002/p2p/12D3KooWS3cnEVm6z4XQQB9nXs9WBb5sfaHnck5TRCAfxEKZQFKm',
  '/ip4/103.142.103.6/tcp/14002/p2p/12D3KooWCv4mouxCSAK6CXJ4B5gZbpjB2pdxVLu8DTz4jViLVvsJ',
];

/// 按换行 / 逗号拆分中继地址，去空白、去重；与内核侧 `splitRelayAddrs` 对齐。
List<String> parseRelayAddrs(String raw) {
  final List<String> out = <String>[];
  for (final String part in raw.split(RegExp(r'[\r\n,]'))) {
    final String addr = part.trim();
    if (addr.isEmpty || out.contains(addr)) {
      continue;
    }
    out.add(addr);
  }
  return out;
}

/// 校验单条中继地址是否为可用的 multiaddr；通过返回 null。
///
/// 只做形态校验（`/协议/值/.../p2p/<PeerID>`），可用性由内核启动时解析确认。
String? validateRelayAddr(String addr) {
  if (!addr.startsWith('/')) {
    return '中继地址需以 / 开头';
  }
  if (!addr.contains('/p2p/')) {
    return '中继地址需包含 /p2p/<PeerID>';
  }
  final List<String> parts = addr.split('/').where((String s) => s.isNotEmpty).toList();
  if (parts.length < 5) {
    return '中继地址格式不完整';
  }
  return null;
}

/// 校验整段中继地址文本；通过返回 null。
String? validateRelayAddrsText(String raw) {
  final List<String> addrs = parseRelayAddrs(raw);
  if (addrs.isEmpty) {
    return '请填写至少一个中继地址';
  }
  for (final String addr in addrs) {
    final String? problem = validateRelayAddr(addr);
    if (problem != null) {
      return '$problem：$addr';
    }
  }
  return null;
}

/// 「中继」：开关与中继地址配置（P6-20）。
///
/// libp2p 的中继客户端能力在主机创建时装配，因此保存后需重启应用生效。
class RelaySettingsDialog extends StatefulWidget {
  const RelaySettingsDialog({super.key, required this.service});

  final SettingsService service;

  @override
  State<RelaySettingsDialog> createState() => _RelaySettingsDialogState();
}

class _RelaySettingsDialogState extends State<RelaySettingsDialog> {
  final TextEditingController _addrs = TextEditingController();

  // 默认开启并预填官方中继地址；用户保存过则以 stored 为准（见 _loadStored）。
  bool _enabled = true;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _savedNote;

  @override
  void initState() {
    super.initState();
    _loadStored();
  }

  @override
  void dispose() {
    _addrs.dispose();
    super.dispose();
  }

  /// 回显已保存的开关与地址；用户从未保存过时用官方默认值（默认开启）。
  ///
  /// 关键：区分「没保存过」（两个键都读不到，回落默认）与「显式关闭/清空」
  /// （键存在，哪怕值为 false/空串也尊重用户），避免用户关掉后又被默认开启。
  Future<void> _loadStored() async {
    final String defaultText = defaultRelayAddrs.join('\n');
    try {
      final String? enabled = await widget.service.read(relayEnabledSettingKey);
      final String? addrs = await widget.service.read(relayAddrsSettingKey);
      if (!mounted) {
        return;
      }
      setState(() {
        if (enabled == null && addrs == null) {
          // 首次配置：默认开启 + 官方主/备中继。
          _enabled = true;
          _addrs.text = defaultText;
        } else {
          _enabled = enabled == 'true';
          _addrs.text = addrs ?? '';
        }
        _loading = false;
      });
    } catch (_) {
      // NOT_STARTED 或读取失败时保持默认（开启+官方地址），表单仍可编辑。
      if (!mounted) {
        return;
      }
      setState(() {
        _enabled = true;
        _addrs.text = defaultText;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final String raw = _addrs.text;
    if (_enabled) {
      final String? problem = validateRelayAddrsText(raw);
      if (problem != null) {
        setState(() {
          _error = problem;
          _savedNote = null;
        });
        return;
      }
    }
    final String addrs = parseRelayAddrs(raw).join('\n');
    setState(() {
      _saving = true;
      _error = null;
      _savedNote = null;
    });
    try {
      await widget.service.write(relayEnabledSettingKey, _enabled ? 'true' : 'false');
      await widget.service.write(relayAddrsSettingKey, addrs);
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _addrs.text = addrs;
        _savedNote = _enabled
            ? context.t('已保存，重启应用后生效')
            : context.t('已关闭中继，重启应用后生效');
      });
    } on NexmemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = _describeError(context, e);
        _saving = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = context.t('保存失败，请稍后重试');
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AlertDialog(
      title: Text(context.t('中继设置')),
      content: responsiveDialogContent(
        maxWidth: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.t(
                  '中继在双方直连失败时兜底转发流量，已默认开启并预填官方公共节点；'
                  '可按需关闭或改为自建中继。',
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              SwitchListTile(
                key: const ValueKey<String>('relay-enabled'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(context.t('启用中继')),
                subtitle: Text(
                  context.t('开启后，直连失败时经中继建立连接'),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _enabled,
                onChanged: _loading || _saving
                    ? null
                    : (bool value) => setState(() {
                          _enabled = value;
                          _error = null;
                          _savedNote = null;
                        }),
              ),
              const SizedBox(height: NexmemMetrics.space8),
              TextField(
                key: const ValueKey<String>('relay-addrs'),
                controller: _addrs,
                enabled: !_saving,
                minLines: 3,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: context.t('中继地址'),
                  hintText: context.t('/ip4/1.2.3.4/tcp/4001/p2p/12D3KooW...\n每行一个'),
                  isDense: true,
                  alignLabelWithHint: true,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                  child: Text(
                    context.t(_error!),
                    key: const ValueKey<String>('relay-error'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: NexmemColors.danger,
                    ),
                  ),
                ),
              if (_savedNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                  child: Text(
                    context.t(_savedNote!),
                    key: const ValueKey<String>('relay-saved'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: NexmemColors.success,
                    ),
                  ),
                ),
              const SizedBox(height: NexmemMetrics.space8),
              Text(
                context.t('地址形如 /ip4/<IP>/tcp/<端口>/p2p/<PeerID>，保存后重启应用生效。'),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(context.t('关闭')),
        ),
        FilledButton.tonal(
          key: const ValueKey<String>('relay-save'),
          onPressed: _loading || _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.t('保存设置')),
        ),
      ],
    );
  }
}

String _describeError(BuildContext context, NexmemException e) {
  switch (e.code) {
    case 'NOT_STARTED':
      return context.t('中继设置尚未接入内核');
    case 'INVALID_ARG':
      return context.t('中继配置格式不正确（INVALID_ARG）');
    case 'DB_ERROR':
      return context.t('保存失败：本机配置写入异常（DB_ERROR）');
    default:
      return context.t('保存失败（{0}），请稍后再试', [e.code]);
  }
}
