import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';

/// 云存储厂商（P6-04 / C-03）：六家均走 S3 兼容协议，共用一套自检代码路径。
/// Go 内核不按厂商分支（blob/s3.go 为通用 SigV4 客户端），差异只在 UI 默认值与提示。
enum StorageProvider { r2, minio, oss, cos, backblazeB2, nas }

extension StorageProviderInfo on StorageProvider {
  /// 配置页展示名。
  String get label {
    switch (this) {
      case StorageProvider.r2:
        return 'Cloudflare R2';
      case StorageProvider.minio:
        return 'MinIO';
      case StorageProvider.oss:
        return '阿里云 OSS';
      case StorageProvider.cos:
        return '腾讯云 COS';
      case StorageProvider.backblazeB2:
        return 'Backblaze B2';
      case StorageProvider.nas:
        return '个人 NAS / 自建 S3';
    }
  }

  /// Endpoint 占位提示，帮助用户填对地址形态。
  String get endpointHint {
    switch (this) {
      case StorageProvider.r2:
        return 'https://<account>.r2.cloudflarestorage.com';
      case StorageProvider.minio:
        return 'http://127.0.0.1:9000';
      case StorageProvider.oss:
        return 'https://oss-cn-hangzhou.aliyuncs.com';
      case StorageProvider.cos:
        return 'https://cos.ap-guangzhou.myqcloud.com';
      case StorageProvider.backblazeB2:
        return 'https://s3.us-west-001.backblazeb2.com';
      case StorageProvider.nas:
        return 'http://192.168.1.10:9000';
    }
  }

  /// 各厂商常用签名区域。
  String get defaultRegion {
    switch (this) {
      case StorageProvider.r2:
        return 'auto';
      case StorageProvider.minio:
        return 'us-east-1';
      case StorageProvider.oss:
        return 'oss-cn-hangzhou';
      case StorageProvider.cos:
        return 'ap-guangzhou';
      case StorageProvider.backblazeB2:
        return 'us-west-001';
      case StorageProvider.nas:
        return 'us-east-1';
    }
  }

  /// MinIO、COS 与个人 NAS 通常使用 path-style 寻址；B2 使用 virtual-hosted。
  bool get defaultPathStyle =>
      this == StorageProvider.minio ||
      this == StorageProvider.cos ||
      this == StorageProvider.nas;
}

/// C-06：识别高风险「主密钥 / 权限过宽」的 Access Key 形态。
///
/// 只做高置信度前缀匹配，避免误伤自建 S3 的随机子密钥（例如测试夹具 AK123）。
/// 命中即拒绝保存/自检；真正的权限边界仍需服务端 storage.test 的 scope 验证兜底。
bool looksLikeMasterAccessKey(String accessKey) {
  final String ak = accessKey.trim();
  if (ak.isEmpty) {
    return false;
  }
  const List<String> masterPrefixes = <String>[
    'AKIA', // AWS 长期访问密钥
    'ASIA', // AWS 临时访问密钥
    'LTAI', // 阿里云 AccessKey ID
    'AKID', // 腾讯云 SecretId
  ];
  for (final String prefix in masterPrefixes) {
    if (ak.toUpperCase().startsWith(prefix)) {
      return true;
    }
  }
  // 常见自建 S3 的默认 root 凭证。
  final String lower = ak.toLowerCase();
  return lower == 'minioadmin' || lower == 'admin' || lower == 'root';
}

/// 自检入参，字段与 gateway 的 `storage.test` 一一对应。
class StorageTestRequest {
  const StorageTestRequest({
    required this.provider,
    required this.endpoint,
    required this.bucket,
    required this.prefix,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    required this.pathStyle,
  });

  final StorageProvider provider;
  final String endpoint;
  final String bucket;
  final String prefix;
  final String region;
  final String accessKey;
  final String secretKey;
  final bool pathStyle;

  /// 返回第一条校验失败的原因；全部通过返回 null。
  String? validate() {
    if (endpoint.isEmpty) {
      return '请填写 Endpoint';
    }
    if (!endpoint.startsWith('http://') && !endpoint.startsWith('https://')) {
      return 'Endpoint 必须以 http:// 或 https:// 开头';
    }
    if (bucket.isEmpty) {
      return '请填写桶名';
    }
    if (prefix.isEmpty) {
      return '请填写对象前缀';
    }
    if (region.isEmpty) {
      return '请填写 Region';
    }
    if (accessKey.isEmpty || secretKey.isEmpty) {
      return '请填写 AK 与 SK';
    }
    if (looksLikeMasterAccessKey(accessKey)) {
      return '检测到疑似主密钥：请改用仅授权当前前缀读写的受限子密钥（严禁使用主密钥）';
    }
    return null;
  }

  /// 转成网关参数；凭证只在本次请求内使用，不落本地配置。
  Map<String, dynamic> toParams() {
    return <String, dynamic>{
      'endpoint': endpoint,
      'bucket': bucket,
      'prefix': prefix,
      'region': region,
      'ak': accessKey,
      'sk': secretKey,
      'path_style': pathStyle,
    };
  }
}

/// `storage.test` 的返回结果。
class StorageTestResult {
  const StorageTestResult({
    required this.ok,
    required this.latencyMs,
    required this.writable,
    required this.listable,
  });

  factory StorageTestResult.fromJson(Map<String, dynamic> json) {
    final Object? latency = json['latency_ms'];
    return StorageTestResult(
      ok: json['ok'] == true,
      latencyMs: latency is num ? latency.toInt() : 0,
      writable: json['writable'] == true,
      listable: json['listable'] == true,
    );
  }

  final bool ok;
  final int latencyMs;
  final bool writable;
  final bool listable;

  /// 结果摘要，最多一行。
  String get summary => ok ? '自检通过 · ${latencyMs}ms' : '自检未通过 · ${latencyMs}ms';
}

/// `storage.get` 的返回：当前落盘配置；Secret Key 永不回传。
class StorageConfigSnapshot {
  const StorageConfigSnapshot({
    required this.configured,
    required this.enabled,
    this.public = true,
    this.endpoint = '',
    this.bucket = '',
    this.prefix = '',
    this.region = '',
    this.accessKey = '',
    this.pathStyle = false,
    this.deleteAfterRead = false,
  });

  factory StorageConfigSnapshot.fromJson(Map<String, dynamic> json) {
    String text(Object? value) => value is String ? value : '';
    return StorageConfigSnapshot(
      configured: json['configured'] == true,
      enabled: json['enabled'] == true,
      // 旧版本内核不回传 public，按「对外公开」处理。
      public: json['public'] != false,
      endpoint: text(json['endpoint']),
      bucket: text(json['bucket']),
      prefix: text(json['prefix']),
      region: text(json['region']),
      accessKey: text(json['ak']),
      pathStyle: json['path_style'] == true,
      deleteAfterRead: json['delete_after_read'] == true,
    );
  }

  final bool configured;
  final bool enabled;

  /// 是否对外公开本机存储；关闭后对端无法写入离线消息。
  final bool public;
  final String endpoint;
  final String bucket;
  final String prefix;
  final String region;
  final String accessKey;
  final bool pathStyle;

  /// 已读后删除 S3 密文对象（C-02）；false 表示由桶生命周期清理。
  final bool deleteAfterRead;

  /// Access Key 尾号提示，避免在界面完整回显凭证。
  String get accessKeyHint {
    if (accessKey.isEmpty) {
      return '';
    }
    if (accessKey.length <= 4) {
      return '****';
    }
    return '****${accessKey.substring(accessKey.length - 4)}';
  }

  /// 依据 Endpoint / Region 推断厂商；无法判断时返回 null。
  StorageProvider? get provider {
    final String ep = endpoint.toLowerCase();
    if (region == 'auto' || ep.contains('r2.cloudflarestorage.com')) {
      return StorageProvider.r2;
    }
    if (ep.contains('backblazeb2.com') || region.startsWith('us-west-')) {
      return StorageProvider.backblazeB2;
    }
    if (ep.contains('aliyuncs.com') || region.startsWith('oss-')) {
      return StorageProvider.oss;
    }
    if (ep.contains('myqcloud.com') || region.startsWith('ap-')) {
      return StorageProvider.cos;
    }
    if (ep.contains('minio')) {
      return StorageProvider.minio;
    }
    // C-03：私有地址（127/10/172.16-31/192.168 或 localhost）归为个人 NAS；
    // 普通 minio 本地地址仍保留 minio 语义，避免误伤既有配置。
    if (ep.contains('localhost') || ep.contains('127.0.0.1')) {
      return StorageProvider.minio;
    }
    final Uri? uri = Uri.tryParse(endpoint);
    if (uri != null && _isPrivateAddress(uri.host)) {
      return StorageProvider.nas;
    }
    return null;
  }

  static bool _isPrivateAddress(String host) {
    if (host == 'localhost') {
      return true;
    }
    final RegExp ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
    final RegExpMatch? m = ipv4.firstMatch(host);
    if (m == null) {
      return false;
    }
    final int a = int.tryParse(m.group(1) ?? '') ?? -1;
    final int b = int.tryParse(m.group(2) ?? '') ?? -1;
    if (a == 10 || a == 127 || (a == 192 && b == 168)) {
      return true;
    }
    return a == 172 && b >= 16 && b <= 31;
  }
}

/// `storage.configure` 的入参；凭证留空表示沿用已保存的值。
class StorageSaveRequest {
  const StorageSaveRequest({
    required this.endpoint,
    required this.bucket,
    required this.prefix,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    required this.pathStyle,
    required this.enabled,
    required this.public,
    this.deleteAfterRead = false,
  });

  final String endpoint;
  final String bucket;
  final String prefix;
  final String region;
  final String accessKey;
  final String secretKey;
  final bool pathStyle;
  final bool enabled;

  /// 是否对外公开本机存储；关闭后对端只能在线发送。
  final bool public;

  /// 已读后删除 S3 密文对象（C-02）。默认 false = 由桶生命周期清理。
  /// 多端共用同一桶时必须保持 false。
  final bool deleteAfterRead;

  /// 返回第一条校验失败的原因；全部通过返回 null。
  ///
  /// [hasStoredCredentials] 为真时允许留空 AK/SK 沿用旧值。
  String? validate({required bool hasStoredCredentials}) {
    if (endpoint.isEmpty) {
      return '请填写 Endpoint';
    }
    if (!endpoint.startsWith('http://') && !endpoint.startsWith('https://')) {
      return 'Endpoint 必须以 http:// 或 https:// 开头';
    }
    if (bucket.isEmpty) {
      return '请填写桶名';
    }
    if (region.isEmpty) {
      return '请填写 Region';
    }
    if (accessKey.isEmpty && !hasStoredCredentials) {
      return '请填写 Access Key';
    }
    if (secretKey.isEmpty && !hasStoredCredentials) {
      return '请填写 Secret Key';
    }
    if (looksLikeMasterAccessKey(accessKey)) {
      return '检测到疑似主密钥：请改用仅授权当前前缀读写的受限子密钥（严禁使用主密钥）';
    }
    return null;
  }

  Map<String, dynamic> toParams() {
    return <String, dynamic>{
      'endpoint': endpoint,
      'bucket': bucket,
      'prefix': prefix,
      'region': region,
      'ak': accessKey,
      'sk': secretKey,
      'path_style': pathStyle,
      'enabled': enabled,
      'public': public,
      'delete_after_read': deleteAfterRead,
    };
  }
}

/// 对象存储自检与配置服务：由 `core.start` 接入内核后注入。
abstract class StorageTestService {
  Future<StorageTestResult> test(StorageTestRequest request);

  /// 读取本机已保存的离线存储配置。
  Future<StorageConfigSnapshot> load();

  /// 保存配置；成功返回后需重启内核才生效。
  Future<void> save(StorageSaveRequest request);
}

/// 通过统一传输层调用 `storage.test` / `storage.get` / `storage.configure`。
class TransportStorageTestService implements StorageTestService {
  TransportStorageTestService(this._transport);

  final CoreTransport _transport;

  @override
  Future<StorageTestResult> test(StorageTestRequest request) async {
    return StorageTestResult.fromJson(
      await _transport.call('storage.test', params: request.toParams()),
    );
  }

  @override
  Future<StorageConfigSnapshot> load() async {
    return StorageConfigSnapshot.fromJson(
      await _transport.call('storage.get', params: const <String, dynamic>{}),
    );
  }

  @override
  Future<void> save(StorageSaveRequest request) async {
    await _transport.call('storage.configure', params: request.toParams());
  }
}

/// 未接入内核时的占位实现：明确抛 `NOT_STARTED`，UI 不做静默失败。
class UnavailableStorageTestService implements StorageTestService {
  const UnavailableStorageTestService();

  @override
  Future<StorageTestResult> test(StorageTestRequest request) async {
    throw const NexmemException('NOT_STARTED', '存储自检尚未接入内核');
  }

  @override
  Future<StorageConfigSnapshot> load() async {
    throw const NexmemException('NOT_STARTED', '离线存储配置尚未接入内核');
  }

  @override
  Future<void> save(StorageSaveRequest request) async {
    throw const NexmemException('NOT_STARTED', '离线存储配置尚未接入内核');
  }
}

/// 「离线存储」：R2 / MinIO / OSS / COS / B2 / 个人 NAS 接入引导与连通性自检（P6-04/C-03）。
class StorageConfigDialog extends StatefulWidget {
  const StorageConfigDialog({super.key, required this.service});

  final StorageTestService service;

  @override
  State<StorageConfigDialog> createState() => _StorageConfigDialogState();
}

class _StorageConfigDialogState extends State<StorageConfigDialog> {
  final TextEditingController _endpoint = TextEditingController();
  final TextEditingController _bucket = TextEditingController();
  final TextEditingController _prefix = TextEditingController(text: 'nexmem');
  final TextEditingController _region = TextEditingController(
    text: StorageProvider.r2.defaultRegion,
  );
  final TextEditingController _accessKey = TextEditingController();
  final TextEditingController _secretKey = TextEditingController();

  StorageProvider _provider = StorageProvider.r2;
  bool _obscureSecret = true;
  bool _busy = false;
  bool _saving = false;
  bool _configured = false;
  bool _enabled = true;
  bool _public = true;
  bool _deleteAfterRead = false;
  bool _scopedKeyConfirmed = false;
  String? _error;
  String? _savedNote;
  StorageTestResult? _result;

  @override
  void initState() {
    super.initState();
    _loadStored();
  }

  /// 回显已保存配置；未接入内核（NOT_STARTED）时保持空表单。
  Future<void> _loadStored() async {
    try {
      final StorageConfigSnapshot snapshot = await widget.service.load();
      if (!mounted || !snapshot.configured) {
        return;
      }
      final StorageProvider? provider = snapshot.provider;
      setState(() {
        _configured = true;
        _enabled = snapshot.enabled;
        _public = snapshot.public;
        _deleteAfterRead = snapshot.deleteAfterRead;
        if (provider != null) {
          _provider = provider;
        }
        _endpoint.text = snapshot.endpoint;
        _bucket.text = snapshot.bucket;
        if (snapshot.prefix.isNotEmpty) {
          _prefix.text = snapshot.prefix;
        }
        if (snapshot.region.isNotEmpty) {
          _region.text = snapshot.region;
        }
        _accessKey.text = snapshot.accessKey;
      });
    } on NexmemException {
      // 尚未启动内核时静默：表单仍可用于自检。
    } catch (_) {
      // 回显失败不阻断配置流程。
    }
  }

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

  void _selectProvider(StorageProvider provider) {
    setState(() {
      final String previousDefault = _provider.defaultRegion;
      _provider = provider;
      final String region = _region.text.trim();
      if (region.isEmpty || region == previousDefault) {
        _region.text = provider.defaultRegion;
      }
      _result = null;
      _error = null;
    });
  }

  Future<void> _runTest() async {
    if (!_scopedKeyConfirmed) {
      setState(() {
        _error = context.t('请先确认使用专用桶与受限子密钥（严禁主密钥）');
        _result = null;
      });
      return;
    }
    final StorageTestRequest request = StorageTestRequest(
      provider: _provider,
      endpoint: _endpoint.text.trim(),
      bucket: _bucket.text.trim(),
      prefix: _prefix.text.trim(),
      region: _region.text.trim(),
      accessKey: _accessKey.text.trim(),
      secretKey: _secretKey.text,
      pathStyle: _provider.defaultPathStyle,
    );
    final String? problem = request.validate();
    if (problem != null) {
      setState(() {
        _error = problem;
        _result = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final StorageTestResult result = await widget.service.test(request);
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _busy = false;
      });
    } on NexmemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = _describeError(context, e);
        _busy = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = context.t('自检失败，请检查网络后重试');
        _busy = false;
      });
    }
  }

  Future<void> _save() async {
    if (!_scopedKeyConfirmed) {
      setState(() {
        _error = context.t('请先确认使用专用桶与受限子密钥（严禁主密钥）');
        _savedNote = null;
      });
      return;
    }
    final StorageSaveRequest request = StorageSaveRequest(
      endpoint: _endpoint.text.trim(),
      bucket: _bucket.text.trim(),
      prefix: _prefix.text.trim(),
      region: _region.text.trim(),
      accessKey: _accessKey.text.trim(),
      secretKey: _secretKey.text,
      pathStyle: _provider.defaultPathStyle,
      enabled: _enabled,
      public: _public,
      deleteAfterRead: _deleteAfterRead,
    );
    final String? problem = request.validate(hasStoredCredentials: _configured);
    if (problem != null) {
      setState(() {
        _error = problem;
        _savedNote = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _savedNote = null;
    });
    try {
      await widget.service.save(request);
      if (!mounted) {
        return;
      }
      setState(() {
        _configured = true;
        _saving = false;
        _savedNote = !request.enabled
            ? context.t('已关闭离线存储，重启应用后生效')
            : !request.public
            ? context.t('已关闭对外公开，重启应用后生效')
            : context.t('已保存，重启应用后生效');
        if (request.secretKey.isEmpty) {
          // 沿用旧 SK 时清空输入框，避免误以为已更新。
          _secretKey.clear();
        }
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
      title: Text(context.t('离线存储')),
      content: responsiveDialogContent(
        context: context,
        maxWidth: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.t('选择服务商并填写桶信息，自检会在桶内写入并删除一个临时对象。'),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              _notice(
                key: const ValueKey<String>('storage-billing-notice'),
                scheme: scheme,
                text: context.t(
                  '离线消息的上传与下载流量、对象存储占用均计入本账号所填云存储的账单；'
                  '请创建专用桶并使用仅授权 im_offline/* 前缀读写的子密钥，严禁填入主密钥。',
                ),
              ),
              // C-06：把「不要填主密钥」从提示升级为强制门槛。
              CheckboxListTile(
                key: const ValueKey<String>('storage-scoped-key-confirm'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _scopedKeyConfirmed,
                title: Text(
                  context.t('我确认使用专用桶与受限子密钥（非主密钥）'),
                  style: const TextStyle(fontSize: 13),
                ),
                onChanged: _saving || _busy
                    ? null
                    : (bool? value) =>
                        setState(() => _scopedKeyConfirmed = value ?? false),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              Wrap(
                spacing: NexmemMetrics.space8,
                runSpacing: NexmemMetrics.space8,
                children: <Widget>[
                  for (final StorageProvider provider in StorageProvider.values)
                    ChoiceChip(
                      key: ValueKey<String>(
                        'storage-provider-${provider.name}',
                      ),
                      label: Text(context.t(provider.label)),
                      selected: _provider == provider,
                      onSelected: (_) => _selectProvider(provider),
                    ),
                ],
              ),
              const SizedBox(height: NexmemMetrics.space12),
              _field(
                controller: _endpoint,
                key: 'storage-endpoint',
                label: 'Endpoint',
                hint: _provider.endpointHint,
                keyboardType: TextInputType.url,
              ),
              _field(
                controller: _bucket,
                key: 'storage-bucket',
                label: context.t('桶名'),
              ),
              _field(
                controller: _prefix,
                key: 'storage-prefix',
                label: context.t('对象前缀'),
                hint: context.t('例如 nexmem 或 im_offline'),
              ),
              _field(
                controller: _region,
                key: 'storage-region',
                label: 'Region',
              ),
              _field(
                controller: _accessKey,
                key: 'storage-ak',
                label: 'Access Key',
              ),
              _field(
                controller: _secretKey,
                key: 'storage-sk',
                label: 'Secret Key',
                hint: _configured ? context.t('留空则沿用已保存的 Secret Key') : null,
                obscureText: _obscureSecret,
                suffixIcon: IconButton(
                  key: const ValueKey<String>('storage-sk-toggle'),
                  icon: Icon(
                    _obscureSecret ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _obscureSecret = !_obscureSecret),
                ),
              ),
              SwitchListTile(
                key: const ValueKey<String>('storage-enabled'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(context.t('启用离线存储')),
                subtitle: Text(
                  context.t('开启后，对端可在本机离线时投递加密消息'),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _enabled,
                onChanged: _saving || _busy
                    ? null
                    : (bool value) => setState(() => _enabled = value),
              ),
              SwitchListTile(
                key: const ValueKey<String>('storage-public'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(context.t('对外公开我的存储配置')),
                subtitle: Text(
                  context.t('关闭后对端只能在线发送，不再向本机写入离线消息；可随时重新开启'),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _public,
                onChanged: _saving || _busy
                    ? null
                    : (bool value) => setState(() => _public = value),
              ),
              SwitchListTile(
                key: const ValueKey<String>('storage-delete-after-read'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(context.t('已读后删除云端密文')),
                subtitle: Text(
                  context.t(
                    '开启后入库成功即删除 S3 密文对象；仅在单设备独占桶时使用，'
                    '多端共用同一桶请保持关闭（由桶生命周期清理）',
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _deleteAfterRead,
                onChanged: _saving || _busy
                    ? null
                    : (bool value) => setState(() => _deleteAfterRead = value),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                  child: Text(
                    context.t(_error!),
                    key: const ValueKey<String>('storage-error'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: NexmemColors.danger,
                    ),
                  ),
                ),
              if (_result != null) _resultBox(_result!),
              if (_savedNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                  child: Text(
                    context.t(_savedNote!),
                    key: const ValueKey<String>('storage-saved'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: NexmemColors.success,
                    ),
                  ),
                ),
              const SizedBox(height: NexmemMetrics.space8),
              Text(
                context.t('凭证由内核用设备主密钥加密后仅保存在本机，重启应用后生效。'),
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
          onPressed: _busy || _saving
              ? null
              : () => Navigator.of(context).pop(),
          child: Text(context.t('关闭')),
        ),
        FilledButton.tonal(
          key: const ValueKey<String>('storage-save'),
          onPressed: _busy || _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.t('保存配置')),
        ),
        FilledButton(
          key: const ValueKey<String>('storage-selftest'),
          onPressed: _busy || _saving ? null : _runTest,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.t('开始自检')),
        ),
      ],
    );
  }

  /// 计费归属与最小权限提示（需求 §7.2 / §7.5）。
  Widget _notice({
    required Key key,
    required ColorScheme scheme,
    required String text,
  }) {
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.all(NexmemMetrics.space8),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: scheme.onSurface.withValues(alpha: 0.75),
        ),
      ),
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

  Widget _resultBox(StorageTestResult result) {
    final Color color = result.ok ? NexmemColors.success : NexmemColors.danger;
    return Container(
      key: const ValueKey<String>('storage-result'),
      margin: const EdgeInsets.only(top: NexmemMetrics.space8),
      padding: const EdgeInsets.all(NexmemMetrics.space12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            context.t(result.summary),
            key: const ValueKey<String>('storage-result-summary'),
            style: TextStyle(fontWeight: FontWeight.w600, color: color),
          ),
          const SizedBox(height: NexmemMetrics.space4),
          Text(
            context.t('写入 {0} · 列举 {1}', [
              result.writable ? context.t('通过') : context.t('失败'),
              result.listable ? context.t('通过') : context.t('失败'),
            ]),
            key: const ValueKey<String>('storage-result-detail'),
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

String _describeError(BuildContext context, NexmemException e) {
  switch (e.code) {
    case 'S3_AUTH':
      return context.t('鉴权失败：请检查 AK/SK 与桶权限（S3_AUTH）');
    case 'S3_QUOTA':
      return context.t('配额或限流：请稍后重试（S3_QUOTA）');
    case 'S3_IO':
      return context.t('读写失败：请检查 Endpoint、Region 与网络（S3_IO）');
    case 'INVALID_ARG':
      return context.t('配置不完整或格式不正确（INVALID_ARG）');
    case 'DB_ERROR':
      return context.t('保存配置失败：本机配置写入异常（DB_ERROR）');
    case 'NOT_STARTED':
      return context.t('存储自检尚未接入内核');
    default:
      return context.t('自检失败（{0}），请稍后再试', [e.code]);
  }
}
