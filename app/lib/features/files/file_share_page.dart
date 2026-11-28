import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../features/chats/start_chat_sheet.dart';
import '../../features/contacts/contact.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import '../settings/settings_pane.dart';
import 'directory_picker.dart';
import 'media_viewer.dart';
import 'transfer_store.dart';
import '../../app/app_dialog.dart';

/// P2P 文件共享管理页：发布本地文件夹、导入分享码、下载并自动做种。
///
/// 无文件大小限制；同一共享可从多个种子并行分片下载，下载完成者自动成为新种子。
class FileSharePage extends StatefulWidget {
  const FileSharePage({
    super.key,
    required this.session,
    this.showHeader = true,
    this.mediaSourceUri,
  });

  final CoreSession session;

  /// 嵌入「文件与传输」页面时隐藏自身标题，使用外层统一标题栏。
  final bool showHeader;

  /// Web 端已下载文件仍在网关进程内，预览需走鉴权 inline 链接。
  final Uri? Function(String path)? mediaSourceUri;

  @override
  State<FileSharePage> createState() => _FileSharePageState();
}

class _FileSharePageState extends State<FileSharePage> {
  List<FileShare> _shares = <FileShare>[];
  bool _loading = true;
  String? _error;
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  String? _pathError;
  String? _notice;
  bool _publishing = false;
  bool _importing = false;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final List<FileShare> shares = await widget.session.listShares();
      if (!mounted) return;
      setState(() {
        _shares = shares;
        _error = null;
        _loading = false;
      });
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final String path = _pathController.text.trim();
    if (path.isEmpty) {
      setState(() => _pathError = context.t('请填写或选择本地文件夹路径'));
      return;
    }
    setState(() {
      _pathError = null;
      _publishing = true;
    });
    try {
      final FileShare share = await widget.session.publishShare(path);
      if (!mounted) return;
      _pathController.clear();
      setState(() => _notice = context.t('已发布，分享码已生成，可复制发给好友'));
      await _showCode(share.code, share.name);
      await _refresh();
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() => _pathError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pathError = '$e');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _pickDirectory() async {
    final String? path = await pickShareDirectory(
      platformPicker: widget.session.pickDirectory,
    );
    if (!mounted) return;
    if (path != null) {
      setState(() => _pathController.text = path);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          kIsWeb
              ? context.t('浏览器无法读取本机目录，请改用分享码导入')
              : context.t('目录选择失败，请手动输入路径'),
        ),
      ),
    );
  }

  Future<void> _importCode() async {
    if (_importing) return;
    final String code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() => _importing = true);
    try {
      await widget.session.importShare(code);
      if (!mounted) return;
      _codeController.clear();
      setState(() => _notice = context.t('已导入共享，选择下载即可获取文件'));
      await _refresh();
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _showCode(String code, String name) async {
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('分享码：{0}', <String>[name])),
        content: SelectableText(code),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              Navigator.of(context).pop();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.t('分享码已复制'))),
                );
              }
            },
            child: Text(context.t('复制')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t('关闭')),
          ),
        ],
      ),
    );
  }

  Future<void> _showDetail(FileShare share) async {
    try {
      final FileShareDetail detail = await widget.session.getShare(share.shareId);
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(share.name.isEmpty ? context.t('共享详情') : share.name),
          content: responsiveDialogContent(
            maxWidth: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(context.t('文件数：{0}', <String>['${detail.files.length}'])),
                  Text(context.t('发布者：{0}', <String>[
                    detail.owner.isEmpty ? '-' : detail.owner.substring(0, detail.owner.length.clamp(0, 16)),
                  ])),
                  const SizedBox(height: 8),
                  ...detail.files.map(
                    (FileShareEntry f) {
                      final MediaKind kind = mediaKindOf(f.path, mime: f.mime);
                      final bool canPreview =
                          kind != MediaKind.other && detail.share.localRoot.isNotEmpty;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(mediaIcon(kind), size: 18),
                        title: Text(
                          f.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(_formatSize(f.size), style: const TextStyle(fontSize: 11)),
                        trailing: canPreview
                            ? IconButton(
                                key: ValueKey<String>('preview-${f.path}'),
                                tooltip: context.t('预览'),
                                icon: const Icon(Icons.play_circle_outline, size: 20),
                                onPressed: () => _previewFile(detail.share, f),
                              )
                            : null,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  if (detail.share.code.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => _showCode(detail.share.code, detail.share.name),
                      icon: const Icon(Icons.share, size: 16),
                      label: Text(context.t('查看/复制分享码')),
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
        ),
      );
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  /// 预览已下载到本机的媒体文件；路径按共享根目录 + 清单相对路径拼装。
  Future<void> _previewFile(FileShare share, FileShareEntry entry) async {
    final String filePath = p.join(share.localRoot, entry.path);
    final Uri? source = widget.mediaSourceUri == null
        ? null
        : widget.mediaSourceUri!(filePath);
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => MediaViewerDialog(
        path: filePath,
        mime: entry.mime,
        title: entry.path,
        sourceUri: source,
      ),
    );
  }

  Future<void> _sendToFriend(FileShare share) async {
    try {
      final Contact? contact = await showContactPicker(
        context,
        widget.session.contacts,
      );
      if (contact == null || !mounted) return;
      await widget.session.sendShare(share.shareId, contact.id);
      if (!mounted) return;
      setState(
        () => _notice = context.t('分享码已发送给 {0}，对方导入后即可下载', <String>[contact.name]),
      );
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _download(FileShare share) async {
    if (_downloading) return;
    // 每次下载先清掉上一次的错误，避免旧提示与新进度同时显示误导用户。
    if (mounted) setState(() => _error = '');
    final TransferStore store = TransferStore.instance;
    if (store.active.any((TransferTask t) => t.shareId == share.shareId)) {
      if (mounted) {
        setState(() => _notice = context.t('正在并行下载，可从多个种子加速…'));
      }
      return;
    }
    // 目标目录取系统下载目录；由用户后续在文件管理器查看。
    final String? dest = await _promptDest(share);
    if (dest == null || dest.trim().isEmpty || !mounted) return;
    final String target = dest.trim();
    setState(() => _downloading = true);
    store.start(
      shareId: share.shareId,
      name: share.name,
      dest: target,
      total: share.totalSize,
    );
    try {
      setState(() => _notice = context.t('正在并行下载，可从多个种子加速…'));
      await widget.session.downloadShare(share.shareId, target);
      store.finish(share.shareId);
      if (!mounted) return;
      setState(() => _notice = context.t('下载完成，本机已自动做种，可继续分享给他人'));
      await _refresh();
    } on NexmemException catch (e) {
      store.fail(share.shareId, e.message);
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      store.fail(share.shareId, '$e');
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<String?> _promptDest(FileShare share) async {
    final String defaultDir = await _defaultDownloadDir();
    if (!mounted) return null;
    final String name = share.name.isEmpty
        ? share.shareId.substring(0, share.shareId.length.clamp(0, 8))
        : share.name;
    // 控制器由对话框 State 自己持有并在 dispose 时释放。不能在 showPaneDialog
    // 的 future 完成时 dispose：路由关闭动画期间 TextField 仍在树里，
    // 提前释放会触发 “controller used after disposed” 并连带 inherited
    // element 断言崩溃（真机窄屏复现）。
    return showPaneDialog<String>(
      context: context,
      builder: (BuildContext ctx) =>
          _DownloadDestDialog(initial: p.join(defaultDir, name)),
    );
  }

  /// 系统下载目录；Web / 平台不支持时回落到文档目录或相对目录。
  Future<String> _defaultDownloadDir() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null && downloads.path.isNotEmpty) return downloads.path;
    } catch (_) {
      // Web 与部分桌面平台不支持，继续回落。
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, 'downloads');
    } catch (_) {
      return 'downloads';
    }
  }

  Future<void> _remove(FileShare share) async {
    final bool? confirm = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('删除共享')),
        content: Text(context.t('仅删除本机共享记录，不会删除已下载的文件。确定继续？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await widget.session.removeShare(share.shareId);
      await _refresh();
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showHeader) PaneHeader(title: context.t('文件共享')),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(NexmemMetrics.space16),
            children: <Widget>[
              Text(
                context.t('发布本地文件夹，生成分享码发给好友；同一共享可从多个种子并行加速下载，下载完成者自动做种。文件大小不设上限。'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: NexmemMetrics.space16),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Widget publishCard = Card(
                    child: Padding(
                      padding: const EdgeInsets.all(NexmemMetrics.space12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(context.t('发布文件夹'), style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _pathController,
                            decoration: InputDecoration(
                              labelText: context.t('本机文件夹绝对路径'),
                              hintText: 'D:\\share\\docs',
                              errorText: _pathError,
                              isDense: true,
                            ),
                            onSubmitted: (_) => _publish(),
                          ),
                          const SizedBox(height: NexmemMetrics.space8),
                          Wrap(
                            spacing: NexmemMetrics.space8,
                            children: <Widget>[
                              OutlinedButton.icon(
                                onPressed: _pickDirectory,
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: Text(context.t('选择文件夹')),
                              ),
                              FilledButton.icon(
                                onPressed: _publishing ? null : _publish,
                                icon: const Icon(Icons.publish, size: 18),
                                label: Text(context.t('发布')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                  final Widget importCard = Card(
                    child: Padding(
                      padding: const EdgeInsets.all(NexmemMetrics.space12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(context.t('导入分享码'), style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _codeController,
                            decoration: InputDecoration(
                              labelText: context.t('粘贴 nexmem://fs/ 分享码'),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _importCode(),
                          ),
                          const SizedBox(height: NexmemMetrics.space8),
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: FilledButton.icon(
                              onPressed: _importing ? null : _importCode,
                              icon: const Icon(Icons.add_link, size: 18),
                              label: Text(context.t('导入')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                  // 桌面宽屏并排，手机窄屏上下排列，减少来回滚动。
                  if (constraints.maxWidth >= 720) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(child: publishCard),
                        const SizedBox(width: NexmemMetrics.space12),
                        Expanded(child: importCard),
                      ],
                    );
                  }
                  return Column(
                    children: <Widget>[
                      publishCard,
                      const SizedBox(height: NexmemMetrics.space12),
                      importCard,
                    ],
                  );
                },
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space12),
                  child: Text(
                    _notice!,
                    style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: NexmemMetrics.space12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                  ),
                ),
              const SizedBox(height: NexmemMetrics.space16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(context.t('我的共享'), style: Theme.of(context).textTheme.titleSmall),
                  IconButton(
                    tooltip: context.t('刷新'),
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(NexmemMetrics.space16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_shares.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(NexmemMetrics.space16),
                  child: Text(context.t('还没有共享，先发布一个文件夹或导入分享码吧')),
                )
              else
                ..._shares.map(
                  (FileShare share) => Card(
                    key: ValueKey<String>('file-share-${share.shareId}'),
                    child: Padding(
                      padding: const EdgeInsets.all(NexmemMetrics.space12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                share.local
                                    ? Icons.folder_shared
                                    : Icons.cloud_download_outlined,
                              ),
                              const SizedBox(width: NexmemMetrics.space12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      share.name.isEmpty
                                          ? context.t('未命名共享')
                                          : share.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      context.t('{0} 个文件 · {1} · {2}', <String>[
                                        '${share.fileCount}',
                                        _formatSize(share.totalSize),
                                        share.isPublished
                                            ? context.t('已发布')
                                            : share.isDownloaded
                                                ? context.t('已下载并做种')
                                                : context.t('已导入'),
                                      ]),
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          // 常用操作直接露出，不藏在二级菜单里。
                          const SizedBox(height: NexmemMetrics.space8),
                          Wrap(
                            spacing: NexmemMetrics.space4,
                            runSpacing: NexmemMetrics.space4,
                            children: <Widget>[
                              TextButton.icon(
                                key: ValueKey<String>('share-detail-${share.shareId}'),
                                onPressed: () => _showDetail(share),
                                icon: const Icon(Icons.visibility_outlined, size: 16),
                                label: Text(context.t('查看详情')),
                              ),
                              if (share.code.isNotEmpty)
                                TextButton.icon(
                                  key: ValueKey<String>('share-code-${share.shareId}'),
                                  onPressed: () => _showCode(share.code, share.name),
                                  icon: const Icon(Icons.share, size: 16),
                                  label: Text(context.t('分享码')),
                                ),
                              TextButton.icon(
                                key: ValueKey<String>('share-send-${share.shareId}'),
                                onPressed: () => _sendToFriend(share),
                                icon: const Icon(Icons.send_outlined, size: 16),
                                label: Text(context.t('发给好友')),
                              ),
                              if (!share.local)
                                FilledButton.tonalIcon(
                                  key: ValueKey<String>('share-download-${share.shareId}'),
                                  onPressed: _downloading
                                      ? null
                                      : () => _download(share),
                                  icon: const Icon(Icons.download, size: 16),
                                  label: Text(context.t('下载')),
                                ),
                              TextButton.icon(
                                key: ValueKey<String>('share-remove-${share.shareId}'),
                                onPressed: () => _remove(share),
                                icon: const Icon(Icons.delete_outline, size: 16),
                                label: Text(context.t('删除')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 下载目标目录输入对话框。控制器由 State 持有，随对话框元素一起释放，
/// 避免路由关闭动画期间 TextField 仍引用已 dispose 的控制器。
class _DownloadDestDialog extends StatefulWidget {
  const _DownloadDestDialog({required this.initial});

  final String initial;

  @override
  State<_DownloadDestDialog> createState() => _DownloadDestDialogState();
}

class _DownloadDestDialogState extends State<_DownloadDestDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('下载到本机目录')),
      content: responsiveDialogContent(
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.t('本机目标目录绝对路径'),
            isDense: true,
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(context.t('开始下载')),
        ),
      ],
    );
  }
}
