import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../app/core_session.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import 'settings_pane.dart';
import 'settings_service.dart';

/// 三种发现源的本机设置键，与内核 `discovery_settings.go` 保持一致。
const String mdnsEnabledSettingKey = 'net.mdns_enabled';
const String publicDHTEnabledSettingKey = 'net.public_dht_enabled';

/// 手动地址解析：把用户输入的 multiaddr 拆分为账号维度条目所需的原始串。
/// 校验形态：以 / 开头、含 /p2p/、分段数足够。
String? validatePeerAddr(String addr) {
  final String trimmed = addr.trim();
  if (!trimmed.startsWith('/')) {
    return '地址需以 / 开头';
  }
  if (!trimmed.contains('/p2p/')) {
    return '地址需包含 /p2p/<PeerID>';
  }
  final int parts = trimmed.split('/').where((String s) => s.isNotEmpty).length;
  if (parts < 5) {
    return '地址格式不完整';
  }
  return null;
}

/// 发现源设置：三种并存的节点发现方式。
///
/// - 局域网发现（mDNS）：同网段自动互联，零服务器；
/// - 公共 DHT：无自建 bootstrap 时兜底寻址；
/// - 手动地址：导入对端 multiaddr，写入本地地址簿，完全离线可用。
///
/// 开关写入设置页 KV，重启应用后生效；手动地址通过 RPC 即时写入地址簿。
class DiscoverySettingsDialog extends StatefulWidget {
  const DiscoverySettingsDialog({
    super.key,
    required this.service,
    this.session,
  });

  final SettingsService service;
  final CoreSession? session;

  @override
  State<DiscoverySettingsDialog> createState() => _DiscoverySettingsDialogState();
}

class _DiscoverySettingsDialogState extends State<DiscoverySettingsDialog> {
  // mDNS 与公共 DHT 默认开启；手动地址簿始终参与解析。
  bool _mdns = true;
  bool _publicDht = true;
  bool _saving = false;
  String? _error;
  String? _savedNote;

  final TextEditingController _accountId = TextEditingController();
  final TextEditingController _peerId = TextEditingController();
  final TextEditingController _addr = TextEditingController();
  final TextEditingController _label = TextEditingController();
  List<PeerEntry> _peers = <PeerEntry>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _accountId.dispose();
    _peerId.dispose();
    _addr.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final String? mdns = await widget.service.read(mdnsEnabledSettingKey);
      final String? dht = await widget.service.read(publicDHTEnabledSettingKey);
      if (!mounted) {
        return;
      }
      setState(() {
        // 未保存过（null）或非 'false' 一律视为默认开启。
        _mdns = mdns == null || mdns != 'false';
        _publicDht = dht == null || dht != 'false';
      });
    } catch (_) {
      // 内核未启动时保持默认值。
    }
    await _loadPeers();
  }

  Future<void> _loadPeers() async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    try {
      final List<PeerEntry> peers = await session.listPeers();
      if (!mounted) {
        return;
      }
      setState(() => _peers = peers);
    } catch (_) {
      // 内核未启动时地址簿保持为空。
    }
  }

  Future<void> _saveSwitches() async {
    setState(() {
      _saving = true;
      _error = null;
      _savedNote = null;
    });
    try {
      await widget.service.write(mdnsEnabledSettingKey, _mdns ? 'true' : 'false');
      await widget.service.write(
        publicDHTEnabledSettingKey,
        _publicDht ? 'true' : 'false',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _savedNote = context.t('已保存，重启应用后生效');
      });
      // 保存成功后关闭弹窗；失败分支保留弹窗并显示错误。
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    } on NexmemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = context.t('保存失败（{0}），请稍后再试', [e.code]);
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

  Future<void> _addPeer() async {
    final CoreSession? session = widget.session;
    if (session == null) {
      setState(() => _error = context.t('内核尚未启动，无法导入地址'));
      return;
    }
    final String account = _accountId.text.trim().replaceFirst(RegExp(r'^0x'), '').toLowerCase();
    final String addr = _addr.text.trim();
    final String peer = _peerId.text.trim();
    if (account.length != 64) {
      setState(() => _error = context.t('账号 ID 需为 64 位十六进制'));
      return;
    }
    final String? problem = validatePeerAddr(addr);
    if (problem != null) {
      setState(() => _error = context.t(problem));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await session.addPeer(
        accountId: account,
        peerId: peer,
        addrs: addr.split(RegExp(r'[\r\n,]')).map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList(),
        label: _label.text.trim(),
      );
      _accountId.clear();
      _peerId.clear();
      _addr.clear();
      _label.clear();
      await _loadPeers();
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _savedNote = context.t('已添加到本地地址簿');
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = context.t('导入失败：{0}', ['$e']);
        _saving = false;
      });
    }
  }

  Future<void> _removePeer(String accountId) async {
    final CoreSession? session = widget.session;
    if (session == null) {
      return;
    }
    final bool? confirm = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.t('删除')),
        content: Text(context.t('确定移除该手动地址？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await session.removePeer(accountId);
      await _loadPeers();
      if (!mounted) return;
      setState(() {
        _error = null;
        _savedNote = context.t('已删除');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = context.t('移除失败：{0}', <String>['$e']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(context.t('发现源设置')),
      content: responsiveDialogContent(
        context: context,
        maxWidth: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.t(
                  '三种发现方式可同时启用，互不冲突：局域网发现无需任何服务器；'
                  '公共 DHT 在无自建节点时兜底；手动地址写入本地簿，完全离线可用。',
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(context.t('局域网发现 (mDNS)')),
                subtitle: Text(
                  context.t('同一 WiFi 下的设备自动互联，零服务器'),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _mdns,
                onChanged: _saving
                    ? null
                    : (bool value) => setState(() {
                          _mdns = value;
                          _savedNote = null;
                        }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(context.t('公共 DHT 兜底')),
                subtitle: Text(
                  context.t('无自建引导节点时，用公共网络解析地址'),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _publicDht,
                onChanged: _saving
                    ? null
                    : (bool value) => setState(() {
                          _publicDht = value;
                          _savedNote = null;
                        }),
              ),
              const Divider(),
              Text(
                context.t('手动地址（本地地址簿）'),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: NexmemMetrics.space8),
              TextField(
                key: const ValueKey<String>('peer-account-id'),
                controller: _accountId,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: context.t('账号 ID（64 位十六进制）'),
                  isDense: true,
                ),
              ),
              const SizedBox(height: NexmemMetrics.space8),
              TextField(
                key: const ValueKey<String>('peer-id'),
                controller: _peerId,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: context.t('设备 PeerID'),
                  isDense: true,
                ),
              ),
              const SizedBox(height: NexmemMetrics.space8),
              TextField(
                key: const ValueKey<String>('peer-addr'),
                controller: _addr,
                enabled: !_saving,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: context.t('对端 multiaddr'),
                  hintText: context.t('/ip4/192.168.1.10/tcp/4001/p2p/12D3KooW...'),
                  isDense: true,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: NexmemMetrics.space8),
              TextField(
                controller: _label,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: context.t('备注（可选）'),
                  isDense: true,
                ),
              ),
              const SizedBox(height: NexmemMetrics.space8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  key: const ValueKey<String>('peer-add'),
                  onPressed: _saving ? null : _addPeer,
                  child: Text(context.t('添加到地址簿')),
                ),
              ),
              if (_peers.isNotEmpty) ...<Widget>[
                const SizedBox(height: NexmemMetrics.space12),
                Text(
                  context.t('已保存地址（{0}）', [_peers.length.toString()]),
                  style: const TextStyle(fontSize: 12),
                ),
                ..._peers.map(
                  (PeerEntry p) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      p.label.isNotEmpty ? p.label : p.peerId,
                      style: const TextStyle(fontSize: 12),
                    ),
                    subtitle: Text(
                      p.accountId,
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => _removePeer(p.accountId),
                    ),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                  child: Text(
                    _error!,
                    key: const ValueKey<String>('discovery-error'),
                    style: const TextStyle(fontSize: 13, color: NexmemColors.danger),
                  ),
                ),
              if (_savedNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                  child: Text(
                    _savedNote!,
                    key: const ValueKey<String>('discovery-saved'),
                    style: const TextStyle(fontSize: 13, color: NexmemColors.success),
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
          key: const ValueKey<String>('discovery-save'),
          onPressed: _saving ? null : _saveSwitches,
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
