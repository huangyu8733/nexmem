import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../settings/storage_config.dart' show looksLikeMasterAccessKey;
import '../../transport/transport.dart';
import 'group_service.dart';

/// 群盘（对象存储）配置状态（P4-07）。
///
/// 数据源为网关 `group.members` 返回的 `storage_configured`：`unknown` 表示尚
/// 未拉取群资料，此时不展示提示，避免误报；仅在明确未配置时提示成员。
enum GroupStorageStatus { unknown, configured, unconfigured }

/// 群盘未配置时的常驻提示条：ui-spec.md §2「未配置群盘，离线消息不可补」。
class GroupStorageNotice extends StatelessWidget {
  const GroupStorageNotice({super.key});

  static const String message = '未配置群盘，离线消息不可补';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: NexmemColors.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
        horizontal: NexmemMetrics.space12,
        vertical: 6,
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.cloud_off_outlined,
            size: 14,
            color: NexmemColors.warning,
          ),
          const SizedBox(width: NexmemMetrics.space4),
          Expanded(
            child: Text(
              context.t('未配置群盘，离线消息不可补'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: NexmemColors.warning,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 群盘配置弹窗（P4-11）：管理员填写 S3 兼容桶信息，经 `group.setStorage`
/// 由内核密封后分发给全体成员；成员离线时即可从群盘补齐消息。
class GroupStorageConfigDialog extends StatefulWidget {
  const GroupStorageConfigDialog({
    super.key,
    required this.groupId,
    required this.service,
  });

  final String groupId;
  final GroupService service;

  @override
  State<GroupStorageConfigDialog> createState() =>
      _GroupStorageConfigDialogState();
}

class _GroupStorageConfigDialogState extends State<GroupStorageConfigDialog> {
  final TextEditingController _endpoint = TextEditingController();
  final TextEditingController _bucket = TextEditingController();
  final TextEditingController _prefix =
      TextEditingController(text: 'nexmem-group');
  final TextEditingController _region = TextEditingController(text: 'us-east-1');
  final TextEditingController _accessKey = TextEditingController();
  final TextEditingController _secretKey = TextEditingController();

  bool _pathStyle = true;
  bool _obscureSecret = true;
  bool _scopedKeyConfirmed = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _endpoint.dispose();
    _bucket.dispose();
    _prefix.dispose();
    _region.dispose();
    _accessKey.dispose();
    _secretKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final GroupStorageConfig config = GroupStorageConfig(
      endpoint: _endpoint.text.trim(),
      bucket: _bucket.text.trim(),
      prefix: _prefix.text.trim(),
      region: _region.text.trim(),
      accessKey: _accessKey.text.trim(),
      secretKey: _secretKey.text,
      pathStyle: _pathStyle,
    );
    final String? problem = config.validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    // C-05：拒绝疑似主密钥，并要求确认使用仅授权本群前缀的受限子密钥。
    if (looksLikeMasterAccessKey(config.accessKey)) {
      setState(() => _error = context.t('拒绝保存：请使用仅授权本群前缀的受限子密钥，不要填入主密钥'));
      return;
    }
    if (!_scopedKeyConfirmed) {
      setState(() => _error = context.t('请先确认使用仅授权本群前缀的受限子密钥'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.configureStorage(widget.groupId, config);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on NexmemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message.isEmpty ? e.code : e.message;
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(context.t('群盘设置')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.t('群盘用于成员离线时补齐加密消息，仅管理员可配置。凭证由内核用群密钥密封后只分发给成员，不会回显。'),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              Container(
                key: const ValueKey<String>('group-storage-billing-notice'),
                width: double.infinity,
                padding: const EdgeInsets.all(NexmemMetrics.space8),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  context.t('群离线消息的上传与下载流量、存储占用计入群盘所属方（群主）的云存储账单；必须使用仅授权本群前缀读写的受限子密钥，严禁跨群访问或填入主密钥。'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              // C-05：把「建议子密钥」升级为强制勾选门槛（对齐个人存储 C-06）。
              CheckboxListTile(
                key: const ValueKey<String>('group-storage-scoped-key-confirm'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _scopedKeyConfirmed,
                title: Text(
                  context.t('我确认使用仅授权本群前缀的受限子密钥（非主密钥）'),
                  style: const TextStyle(fontSize: 13),
                ),
                onChanged: _saving
                    ? null
                    : (bool? value) =>
                        setState(() => _scopedKeyConfirmed = value ?? false),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              _field(
                controller: _endpoint,
                key: 'group-storage-endpoint',
                label: 'Endpoint',
                hint: 'http://127.0.0.1:9000',
                keyboardType: TextInputType.url,
              ),
              _field(
                controller: _bucket,
                key: 'group-storage-bucket',
                label: context.t('桶名'),
              ),
              _field(
                controller: _prefix,
                key: 'group-storage-prefix',
                label: context.t('对象前缀'),
              ),
              _field(
                controller: _region,
                key: 'group-storage-region',
                label: 'Region',
              ),
              _field(
                controller: _accessKey,
                key: 'group-storage-ak',
                label: 'Access Key',
              ),
              _field(
                controller: _secretKey,
                key: 'group-storage-sk',
                label: 'Secret Key',
                obscureText: _obscureSecret,
                suffixIcon: IconButton(
                  key: const ValueKey<String>('group-storage-sk-toggle'),
                  icon: Icon(
                    _obscureSecret ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _obscureSecret = !_obscureSecret),
                ),
              ),
              SwitchListTile(
                key: const ValueKey<String>('group-storage-path-style'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(context.t('Path-style 寻址')),
                subtitle: Text(
                  context.t('MinIO 与腾讯云 COS 通常需要开启'),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _pathStyle,
                onChanged: _saving
                    ? null
                    : (bool value) => setState(() => _pathStyle = value),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                  child: Text(
                    _error!,
                    key: const ValueKey<String>('group-storage-error'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: NexmemColors.danger,
                    ),
                  ),
                ),
              const SizedBox(height: NexmemMetrics.space8),
              Text(
                context.t('重新配置会整体覆盖现有群盘设置。'),
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
          key: const ValueKey<String>('group-storage-cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('group-storage-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.t('保存配置')),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String key,
    required String label,
    String? hint,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NexmemMetrics.space8),
      child: TextField(
        key: ValueKey<String>(key),
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }
}
