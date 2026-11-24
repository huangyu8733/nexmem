import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../features/chats/start_chat_sheet.dart';
import '../../features/contacts/contact.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import 'directory_picker.dart';

/// P2P 文件共享管理页：发布本地文件夹、导入分享码、下载并自动做种。
///
/// 无文件大小限制；同一共享可从多个种子并行分片下载，下载完成者自动成为新种子。
class FileSharePage extends StatefulWidget {
  const FileSharePage({super.key, required this.session});

  final CoreSession session;

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
    final String path = _pathController.text.trim();
    if (path.isEmpty) {
      setState(() => _pathError = context.t('请填写或选择本地文件夹路径'));
      return;
    }
    setState(() => _pathError = null);
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
    }
  }

  Future<void> _pickDirectory() async {
    final String? path = await pickShareDirectory(
      platformPicker: widget.session.pickDirectory,
    );
    if (path != null && mounted) {
      setState(() => _pathController.text = path);
    }
  }

  Future<void> _importCode() async {
    final String code = _codeController.text.trim();
    if (code.isEmpty) return;
    try {
      await widget.session.importShare(code);
      if (!mounted) return;
      _codeController.clear();
      setState(() => _notice = context.t('已导入共享，选择下载即可获取文件'));
      await _refresh();
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _showCode(String code, String name) async {
    if (!mounted) return;
    await showDialog<void>(
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
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(share.name.isEmpty ? context.t('共享详情') : share.name),
          content: SizedBox(
            width: 420,
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
                    (FileShareEntry f) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
                      title: Text(f.path, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(_formatSize(f.size), style: const TextStyle(fontSize: 11)),
                    ),
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
    // 目标目录取本机下载目录下以共享名命名的子目录；由用户后续在文件管理器查看。
    final String? dest = await _promptDest(share);
    if (dest == null || dest.trim().isEmpty || !mounted) return;
    try {
      setState(() => _notice = context.t('正在并行下载，可从多个种子加速…'));
      await widget.session.downloadShare(share.shareId, dest.trim());
      if (!mounted) return;
      setState(() => _notice = context.t('下载完成，本机已自动做种，可继续分享给他人'));
      await _refresh();
    } on NexmemException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<String?> _promptDest(FileShare share) async {
    final TextEditingController controller = TextEditingController(
      text: '${_documentsHint()}/${share.name.isEmpty ? share.shareId.substring(0, 8) : share.name}',
    );
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('下载到本机目录')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.t('本机目标目录绝对路径'),
            isDense: true,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(context.t('开始下载')),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  String _documentsHint() {
    return '/path/to/downloads';
  }

  Future<void> _remove(FileShare share) async {
    final bool? confirm = await showDialog<bool>(
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
        PaneHeader(title: context.t('文件共享')),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(NexmemMetrics.space16),
            children: <Widget>[
              Text(
                context.t('发布本地文件夹，生成分享码发给好友；同一共享可从多个种子并行加速下载，下载完成者自动做种。文件大小不设上限。'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: NexmemMetrics.space16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(NexmemMetrics.space12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(context.t('发布文件夹'), style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _pathController,
                              decoration: InputDecoration(
                                labelText: context.t('本机文件夹绝对路径'),
                                hintText: 'D:\\share\\docs',
                                errorText: _pathError,
                                isDense: true,
                              ),
                              onSubmitted: (_) => _publish(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: context.t('选择文件夹'),
                            onPressed: _pickDirectory,
                            icon: const Icon(Icons.folder_open),
                          ),
                          FilledButton(
                            onPressed: _publish,
                            child: Text(context.t('发布')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(NexmemMetrics.space12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(context.t('导入分享码'), style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _codeController,
                              decoration: InputDecoration(
                                labelText: context.t('粘贴 nexmem://fs/ 分享码'),
                                isDense: true,
                              ),
                              onSubmitted: (_) => _importCode(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _importCode,
                            child: Text(context.t('导入')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
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
                    child: ListTile(
                      key: ValueKey<String>('file-share-${share.shareId}'),
                      leading: Icon(
                        share.local ? Icons.folder_shared : Icons.cloud_download_outlined,
                      ),
                      title: Text(share.name.isEmpty ? context.t('未命名共享') : share.name),
                      subtitle: Text(
                        context.t('{0} 个文件 · {1} · {2}', <String>[
                          '${share.fileCount}',
                          _formatSize(share.totalSize),
                          share.isPublished
                              ? context.t('已发布')
                              : share.isDownloaded
                                  ? context.t('已下载并做种')
                                  : context.t('已导入'),
                        ]),
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (String action) {
                          switch (action) {
                            case 'detail':
                              _showDetail(share);
                              break;
                            case 'code':
                              if (share.code.isNotEmpty) _showCode(share.code, share.name);
                              break;
                            case 'send':
                              _sendToFriend(share);
                              break;
                            case 'download':
                              _download(share);
                              break;
                            case 'remove':
                              _remove(share);
                              break;
                          }
                        },
                        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(
                            value: 'detail',
                            child: Text(context.t('查看详情')),
                          ),
                          if (share.code.isNotEmpty)
                            PopupMenuItem<String>(
                              value: 'code',
                              child: Text(context.t('分享码')),
                            ),
                          PopupMenuItem<String>(
                            value: 'send',
                            child: Text(context.t('发给好友')),
                          ),
                          if (!share.local)
                            PopupMenuItem<String>(
                              value: 'download',
                              child: Text(context.t('下载')),
                            ),
                          PopupMenuItem<String>(
                            value: 'remove',
                            child: Text(context.t('删除')),
                          ),
                        ],
                      ),
                      onTap: () => _showDetail(share),
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
