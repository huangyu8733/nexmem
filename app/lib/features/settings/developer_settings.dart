// 开发者配置：填写地图 Key 与可公开的 Web Push 公钥（本机保存），
// 以及用于生成服务端环境变量文本的私钥/服务账号（只在内存中，不落盘）。
//
// 安全边界：APNs / FCM / VAPID 私钥属于服务端签名凭据，绝不能写进客户端 KV、
// 日志或消息。本页只把它们转成一段可复制的配置文本，由部署者自行保存为文件。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../push/push_controller.dart';
import '../push/push_platform.dart';
import '../remote/device_map_page.dart';
import 'settings_service.dart';

class DeveloperPane extends StatefulWidget {
  const DeveloperPane({
    super.key,
    required this.settings,
    this.push,
    this.showHeader = true,
  });

  final SettingsService settings;
  final PushController? push;
  final bool showHeader;

  @override
  State<DeveloperPane> createState() => _DeveloperPaneState();
}

class _DeveloperPaneState extends State<DeveloperPane> {
  final TextEditingController _mapKey = TextEditingController();
  final TextEditingController _vapidPublic = TextEditingController();
  final TextEditingController _apnsKeyId = TextEditingController();
  final TextEditingController _apnsTeamId = TextEditingController();
  final TextEditingController _apnsBundleId = TextEditingController();
  final TextEditingController _apnsPrivateKey = TextEditingController();
  final TextEditingController _fcmAccount = TextEditingController();
  final TextEditingController _vapidPrivateKey = TextEditingController();
  final TextEditingController _vapidSubject = TextEditingController();

  bool _sandbox = false;
  bool _loading = true;
  String? _exported;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final TextEditingController controller in <TextEditingController>[
      _mapKey,
      _vapidPublic,
      _apnsKeyId,
      _apnsTeamId,
      _apnsBundleId,
      _apnsPrivateKey,
      _fcmAccount,
      _vapidPrivateKey,
      _vapidSubject,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _mapKey.text = await widget.settings.read(deviceMapTencentKeySetting) ?? '';
      _vapidPublic.text = await widget.settings.read(kVapidPublicKeySetting) ?? '';
    } on Object {
      // 设置服务未就绪时留空，用户仍可填写后再保存。
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    // 文案在 await 之前取好，避免跨异步间隔使用 BuildContext。
    final String savedMessage = context.t('开发者配置已保存');
    final String failTemplate = context.t('保存失败：{0}');
    try {
      await widget.settings.write(
        deviceMapTencentKeySetting,
        _mapKey.text.trim(),
      );
      await widget.settings.write(
        kVapidPublicKeySetting,
        _vapidPublic.text.trim(),
      );
      await widget.push?.reloadCredentials();
      _notice(savedMessage);
    } on Object catch (e) {
      _notice(failTemplate.replaceFirst('{0}', '$e'));
    }
  }

  void _notice(String message) {
    if (!mounted || !context.mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 生成部署用的环境变量文本。私钥内容不写进文本，只给路径占位，
  /// 避免把多行 PEM / JSON 直接塞进 shell 命令造成泄漏或转义错误。
  void _generateExport() {
    final StringBuffer out = StringBuffer();
    final String keyId = _apnsKeyId.text.trim();
    final String teamId = _apnsTeamId.text.trim();
    final String bundleId = _apnsBundleId.text.trim();
    final bool hasApns = keyId.isNotEmpty ||
        teamId.isNotEmpty ||
        bundleId.isNotEmpty ||
        _apnsPrivateKey.text.trim().isNotEmpty;
    if (hasApns) {
      out
        ..writeln('# APNs: 请把私钥内容保存为 /opt/nexmem/AuthKey.p8')
        ..writeln('NEXMEM_APNS_KEY=/opt/nexmem/AuthKey.p8')
        ..writeln('NEXMEM_APNS_KEY_ID=$keyId')
        ..writeln('NEXMEM_APNS_TEAM_ID=$teamId')
        ..writeln('NEXMEM_APNS_BUNDLE_ID=$bundleId');
      if (_sandbox) {
        out.writeln('NEXMEM_APNS_SANDBOX=1');
      }
      out.writeln();
    }
    if (_fcmAccount.text.trim().isNotEmpty) {
      out
        ..writeln('# FCM: 请把服务账号 JSON 保存为 /opt/nexmem/fcm.json')
        ..writeln('NEXMEM_FCM_ACCOUNT=/opt/nexmem/fcm.json')
        ..writeln();
    }
    if (_vapidPrivateKey.text.trim().isNotEmpty ||
        _vapidSubject.text.trim().isNotEmpty) {
      out
        ..writeln('# Web Push: 请把私钥内容保存为 /opt/nexmem/vapid.pem')
        ..writeln('NEXMEM_VAPID_KEY=/opt/nexmem/vapid.pem')
        ..writeln('NEXMEM_VAPID_SUBJECT=${_vapidSubject.text.trim()}')
        ..writeln();
    }
    setState(() {
      _exported = out.isEmpty ? context.t('请先填写至少一项服务端凭证') : out.toString();
    });
  }

  Future<void> _copyExport() async {
    final String? text = _exported;
    if (text == null || text.isEmpty) {
      return;
    }
    final String copiedMessage = context.t('配置已复制');
    await Clipboard.setData(ClipboardData(text: text));
    _notice(copiedMessage);
  }

  Widget _field(
    BuildContext context,
    String label,
    TextEditingController controller, {
    String? keyName,
    bool obscure = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        key: keyName == null ? null : ValueKey<String>(keyName),
        controller: controller,
        obscureText: obscure,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      children: <Widget>[
        if (widget.showHeader)
          Padding(
            padding: const EdgeInsets.only(bottom: NexmemMetrics.space12),
            child: Text(context.t('开发者配置'), style: theme.textTheme.titleLarge),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(NexmemMetrics.space16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(context.t('地图与通知凭证'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                _field(context, context.t('腾讯地图 Key'), _mapKey,
                    keyName: 'developer-map-key', obscure: true),
                Text(
                  context.t('留空表示清除；Key 只保存在本机，不会随代码分发'),
                  style: theme.textTheme.bodySmall,
                ),
                _field(context, context.t('Web Push VAPID 公钥'), _vapidPublic,
                    keyName: 'developer-vapid-public'),
                Text(
                  context.t('用于浏览器后台通知；私钥在下方服务端配置中填写，不保存在客户端'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey<String>('developer-save'),
                  onPressed: _loading ? null : () => unawaited(_save()),
                  child: Text(context.t('保存本机配置')),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(NexmemMetrics.space16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  context.t('服务端凭证（仅生成配置文本）'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  context.t('以下私钥与服务账号只在本页内存中用于生成配置文本，不写入本机、不上传、不随消息发送'),
                  style: theme.textTheme.bodySmall,
                ),
                _field(context, 'APNs Key ID', _apnsKeyId,
                    keyName: 'developer-apns-key-id'),
                _field(context, 'APNs Team ID', _apnsTeamId,
                    keyName: 'developer-apns-team-id'),
                _field(context, 'Bundle ID', _apnsBundleId,
                    keyName: 'developer-apns-bundle-id'),
                _field(context, context.t('APNs 私钥内容（.p8）'), _apnsPrivateKey,
                    keyName: 'developer-apns-private', maxLines: 3),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _sandbox,
                  onChanged: (bool value) => setState(() => _sandbox = value),
                  title: Text(context.t('沙箱环境')),
                ),
                _field(context, 'FCM Service Account JSON', _fcmAccount,
                    keyName: 'developer-fcm-account', maxLines: 3),
                _field(context, 'VAPID Private Key (PEM)', _vapidPrivateKey, maxLines: 3),
                _field(context, 'VAPID Subject', _vapidSubject),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  key: const ValueKey<String>('developer-generate'),
                  onPressed: _generateExport,
                  child: Text(context.t('生成服务端配置')),
                ),
                if (_exported != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(context.t('生成的服务端配置'), style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      _exported!,
                      key: const ValueKey<String>('developer-export-text'),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      key: const ValueKey<String>('developer-copy'),
                      onPressed: () => unawaited(_copyExport()),
                      icon: const Icon(Icons.copy_all, size: 16),
                      label: Text(context.t('复制配置')),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
