// 在线升级对话框：检查 GitHub 最新版、展示说明、下载并打开安装目录。

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../settings/settings_pane.dart';
import 'update_service.dart';

/// 显示在线升级对话框。
Future<void> showUpdateDialog(BuildContext context, String currentVersion) {
  return showPaneDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        UpdateDialog(currentVersion: currentVersion),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.currentVersion});

  final String currentVersion;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  final UpdateService _updater = UpdateService();
  ReleaseInfo? _release;
  String? _error;
  bool _checking = true;
  bool _downloading = false;
  int _downloaded = 0;
  int _total = -1;
  String? _downloadPath;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _updater.close();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final ReleaseInfo r = await _updater.checkLatest();
      if (!mounted) return;
      setState(() {
        _release = r;
        _checking = false;
      });
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _checking = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = context.t('检查更新失败，请稍后重试');
        _checking = false;
      });
    }
  }

  Future<void> _download() async {
    final ReleaseInfo? release = _release;
    if (release == null) return;
    setState(() {
      _downloading = true;
      _downloaded = 0;
      _total = -1;
      _error = null;
    });
    try {
      final String path = await _updater.download(release, (int d, int t) {
        if (mounted) {
          setState(() {
            _downloaded = d;
            _total = t;
          });
        }
      });
      final String dir = await _updater.extract(path);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadPath = dir;
      });
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = context.t('下载失败，请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasUpdate = _release != null &&
        isNewer(widget.currentVersion, _release!.version);

    return AlertDialog(
      title: Text(context.t('在线升级')),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.t('当前版本：{0}', [widget.currentVersion]),
                key: const ValueKey<String>('update-current-version'),
              ),
              const SizedBox(height: NexmemMetrics.space8),
              if (_checking)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: NexmemMetrics.space16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey<String>('update-error'),
                  style: TextStyle(color: scheme.error),
                )
              else if (_release != null) ...<Widget>[
                Text(
                  hasUpdate
                      ? context.t('发现新版本：{0}', [_release!.version])
                      : context.t('已是最新版本：{0}', [_release!.version]),
                  key: const ValueKey<String>('update-latest-version'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: hasUpdate ? scheme.primary : scheme.onSurface,
                  ),
                ),
                if (_release!.notes.isNotEmpty) ...<Widget>[
                  const SizedBox(height: NexmemMetrics.space8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 160),
                    padding: const EdgeInsets.all(NexmemMetrics.space8),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: Text(_release!.notes, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
                if (_downloading) ...<Widget>[
                  const SizedBox(height: NexmemMetrics.space12),
                  LinearProgressIndicator(
                    value: _total > 0 ? _downloaded / _total : null,
                  ),
                  const SizedBox(height: NexmemMetrics.space4),
                  Text(
                    _total > 0
                        ? context.t('已下载 {0} / {1}', [
                            _formatBytes(_downloaded),
                            _formatBytes(_total),
                          ])
                        : context.t('已下载 {0}', [_formatBytes(_downloaded)]),
                  ),
                ],
                if (_downloadPath != null) ...<Widget>[
                  const SizedBox(height: NexmemMetrics.space12),
                  Text(
                    context.t('安装包已保存到：{0}', [_downloadPath]),
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    context.t('请打开该目录，按说明完成安装；Windows 需运行 install.ps1。'),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => _updater.openReleasePage(kReleasePage),
          child: Text(context.t('打开发布页')),
        ),
        if (_error != null)
          TextButton(onPressed: _check, child: Text(context.t('重试'))),
        if (_release != null && hasUpdate && _downloadPath == null)
          FilledButton(
            key: const ValueKey<String>('update-download'),
            onPressed: _downloading ? null : _download,
            child: Text(
              _downloading ? context.t('下载中…') : context.t('下载安装包'),
            ),
          ),
        if (_downloadPath != null)
          FilledButton(
            onPressed: () => _updater.reveal(_downloadPath!),
            child: Text(context.t('打开安装目录')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('关闭')),
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
