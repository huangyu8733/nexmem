import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import 'file_share_page.dart';
import 'media_viewer.dart';
import 'transfer_store.dart';
import '../../app/app_dialog.dart';

/// 「文件与传输」统一入口：共享 / 传输 / 下载三个页签。
///
/// 设置页顶部的文件夹图标直接打开这里；传输页读取 [TransferStore] 中
/// `fs.progress` 驱动的实时进度，下载页从本机已下载的共享里列出可预览文件。
class FileHubPage extends StatefulWidget {
  const FileHubPage({
    super.key,
    required this.session,
    this.mediaSourceUri,
  });

  final CoreSession session;

  /// Web 端内核在网关进程内，预览需走鉴权 inline 链接。
  final Uri? Function(String path)? mediaSourceUri;

  @override
  State<FileHubPage> createState() => _FileHubPageState();
}

class _FileHubPageState extends State<FileHubPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 3, vsync: this, initialIndex: 0);
  final TransferStore _store = TransferStore.instance;
  bool _attachedHere = false;

  /// 刷新时替换子页 key，强制重新 initState 拉取共享/下载列表。
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    if (!_store.attached) {
      _store.attach(widget.session.transport);
      _attachedHere = true;
    }
  }

  @override
  void dispose() {
    if (_attachedHere) _store.detach();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(
          title: context.t('文件与传输'),
          actions: <Widget>[
            IconButton(
              key: const ValueKey<String>('file-hub-refresh'),
              tooltip: context.t('刷新'),
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => setState(() => _revision++),
            ),
          ],
        ),
        TabBar(
          controller: _tabs,
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          tabs: <Widget>[
            Tab(
              icon: const Icon(Icons.folder_shared_outlined, size: 18),
              text: context.t('共享'),
            ),
            Tab(
              icon: const Icon(Icons.swap_vert, size: 18),
              text: context.t('传输'),
            ),
            Tab(
              icon: const Icon(Icons.download_outlined, size: 18),
              text: context.t('下载'),
            ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: <Widget>[
              FileSharePage(
                key: ValueKey<String>('file-share-page-$_revision'),
                session: widget.session,
                showHeader: false,
                mediaSourceUri: widget.mediaSourceUri,
              ),
              _TransferTab(store: _store),
              _DownloadsTab(
                key: ValueKey<String>('downloads-tab-$_revision'),
                session: widget.session,
                mediaSourceUri: widget.mediaSourceUri,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TransferTab extends StatelessWidget {
  const _TransferTab({required this.store});

  final TransferStore store;

  Future<void> _confirmRemove(BuildContext context, TransferTask task) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('确认删除记录')),
        content: Text(context.t('仅从列表移除，不会取消正在进行的下载；确定继续？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('transfer-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (ok == true) {
      store.remove(task.shareId);
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('确认清空记录')),
        content: Text(context.t('仅从列表移除，不会取消正在进行的下载；确定继续？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('transfer-clear-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('清空')),
          ),
        ],
      ),
    );
    if (ok == true) {
      store.clearAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (BuildContext context, Widget? _) {
        final List<TransferTask> tasks = store.tasks;
        if (tasks.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(NexmemMetrics.space24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.swap_vert_circle_outlined,
                    size: 48,
                    color: Theme.of(context).disabledColor,
                  ),
                  const SizedBox(height: NexmemMetrics.space12),
                  Text(
                    context.t('还没有传输任务，在「共享」中下载一个共享即可看到进度'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        }
        final int running = tasks
            .where((TransferTask t) => t.status == TransferStatus.running)
            .length;
        final int done = tasks
            .where((TransferTask t) => t.status == TransferStatus.done)
            .length;
        final int failed = tasks
            .where((TransferTask t) => t.status == TransferStatus.failed)
            .length;
        return Column(
          children: <Widget>[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(
                NexmemMetrics.space16,
                NexmemMetrics.space12,
                NexmemMetrics.space12,
                NexmemMetrics.space12,
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.sync_outlined,
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: NexmemMetrics.space8),
                  // 窄屏下吸收剩余宽度并省略，避免把两个按钮挤出屏幕。
                  Expanded(
                    child: Text(
                      context.t('进行中 {0} · 已完成 {1} · 失败 {2}', <String>[
                        '$running',
                        '$done',
                        '$failed',
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (done > 0)
                    TextButton.icon(
                      onPressed: store.clearFinished,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: Text(context.t('清空已完成')),
                    ),
                  TextButton.icon(
                    key: const ValueKey<String>('transfer-clear-all'),
                    onPressed: () => _confirmClear(context),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: Text(context.t('清空传输任务')),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(NexmemMetrics.space12),
                itemCount: tasks.length,
                itemBuilder: (BuildContext context, int index) {
                  final TransferTask task = tasks[index];
                  final Color color = task.status == TransferStatus.failed
                      ? NexmemColors.danger
                      : Theme.of(context).colorScheme.primary;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(NexmemMetrics.space12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                task.status == TransferStatus.done
                                    ? Icons.check_circle_outline
                                    : task.status == TransferStatus.failed
                                        ? Icons.error_outline
                                        : Icons.downloading,
                                color: color,
                                size: 20,
                              ),
                              const SizedBox(width: NexmemMetrics.space8),
                              Expanded(
                                child: Text(
                                  task.name.isEmpty
                                      ? task.shareId.substring(
                                          0, task.shareId.length.clamp(0, 12))
                                      : task.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              Text(_statusLabel(context, task.status)),
                              IconButton(
                                key: ValueKey<String>(
                                    'transfer-delete-${task.shareId}'),
                                tooltip: context.t('删除传输任务'),
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => _confirmRemove(context, task),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: task.progress,
                            backgroundColor:
                                color.withValues(alpha: 0.12),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            context.t('{0} / {1} · {2}', <String>[
                              _formatSize(task.done),
                              _formatSize(task.total),
                              task.dest,
                            ]),
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (task.error != null)
                            Text(
                              task.error!,
                              style: TextStyle(
                                color: NexmemColors.danger,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  String _statusLabel(BuildContext context, TransferStatus status) {
    switch (status) {
      case TransferStatus.running:
        return context.t('进行中');
      case TransferStatus.done:
        return context.t('已完成');
      case TransferStatus.failed:
        return context.t('失败');
    }
  }
}

class _DownloadsTab extends StatefulWidget {
  const _DownloadsTab({
    super.key,
    required this.session,
    this.mediaSourceUri,
  });

  final CoreSession session;
  final Uri? Function(String path)? mediaSourceUri;

  @override
  State<_DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<_DownloadsTab> {
  List<FileShare> _shares = <FileShare>[];
  final Map<String, FileShareDetail?> _details = <String, FileShareDetail?>{};
  bool _loading = true;
  String? _error;

  /// 0 全部 / 1 图片 / 2 视频 / 3 音乐 / 4 其他。
  int _filter = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final List<FileShare> all = await widget.session.listShares();
      final List<FileShare> downloaded = all
          .where((FileShare s) => s.local && s.localRoot.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _shares = downloaded;
        _loading = false;
        _error = null;
      });
      for (final FileShare share in downloaded) {
        unawaited(_loadDetail(share));
      }
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

  Future<void> _loadDetail(FileShare share) async {
    try {
      final FileShareDetail detail = await widget.session.getShare(share.shareId);
      if (!mounted) return;
      setState(() => _details[share.shareId] = detail);
    } on NexmemException {
      // 单个共享详情失败不影响其它条目。
    }
  }

  List<FileShare> get _visibleShares {
    if (_filter == 0) return _shares;
    return _shares.where((FileShare share) {
      final FileShareDetail? detail = _details[share.shareId];
      // 详情未到时先保留条目，避免筛选过程中列表闪烁。
      if (detail == null) return true;
      return _filesFor(share, detail).isNotEmpty;
    }).toList();
  }

  List<FileShareEntry> _filesFor(FileShare share, FileShareDetail detail) {
    if (_filter == 0) return detail.files;
    return detail.files.where((FileShareEntry file) {
      return _filterOf(mediaKindOf(file.path, mime: file.mime)) == _filter;
    }).toList();
  }

  static int _filterOf(MediaKind kind) {
    switch (kind) {
      case MediaKind.image:
        return 1;
      case MediaKind.video:
        return 2;
      case MediaKind.audio:
        return 3;
      case MediaKind.other:
        return 4;
    }
  }

  Widget _buildFilters(BuildContext context) {
    final List<String> labels = <String>[
      context.t('全部'),
      context.t('图片'),
      context.t('视频'),
      context.t('音乐'),
      context.t('其他'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        NexmemMetrics.space12,
        NexmemMetrics.space8,
        NexmemMetrics.space12,
        0,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: NexmemMetrics.space8),
              child: ChoiceChip(
                key: ValueKey<String>('download-filter-$i'),
                label: Text(labels[i]),
                selected: _filter == i,
                onSelected: (bool selected) {
                  if (selected) setState(() => _filter = i);
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NexmemMetrics.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(context.t('重试')),
              ),
            ],
          ),
        ),
      );
    }
    final List<FileShare> shown = _visibleShares;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildFilters(context),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(NexmemMetrics.space24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.folder_off_outlined,
                          size: 48,
                          color: Theme.of(context).disabledColor,
                        ),
                        const SizedBox(height: NexmemMetrics.space12),
                        Text(
                          _shares.isEmpty
                              ? context.t('还没有已下载的文件，下载后即可在这里预览图片、视频和音乐')
                              : context.t('没有符合条件的文件'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(NexmemMetrics.space12),
                    itemCount: shown.length,
                    itemBuilder: (BuildContext context, int index) {
                      final FileShare share = shown[index];
                      final FileShareDetail? detail = _details[share.shareId];
                      final List<FileShareEntry> files = detail == null
                          ? const <FileShareEntry>[]
                          : _filesFor(share, detail);
                      return Card(
                        child: ExpansionTile(
                          key: ValueKey<String>('download-${share.shareId}'),
                          leading: const Icon(Icons.download_done_outlined),
                          title: Text(
                            share.name.isEmpty ? context.t('已下载共享') : share.name,
                          ),
                          subtitle: Text(
                            context.t('{0} 个文件 · {1}', <String>[
                              '${detail == null ? share.fileCount : files.length}',
                              share.localRoot,
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          children: <Widget>[
                            if (detail == null)
                              const Padding(
                                padding: EdgeInsets.all(NexmemMetrics.space12),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              for (final FileShareEntry file in files)
                                ListTile(
                                  dense: true,
                                  leading: Icon(
                                    mediaIcon(mediaKindOf(file.path, mime: file.mime)),
                                    size: 20,
                                  ),
                                  title: Text(
                                    file.path,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  subtitle: Text(
                                    _formatSize(file.size),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  trailing: const Icon(Icons.play_arrow, size: 18),
                                  onTap: () => _preview(share, file),
                                ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _preview(FileShare share, FileShareEntry file) async {
    final String path = p.join(share.localRoot, file.path);
    final Uri? source = widget.mediaSourceUri == null
        ? null
        : widget.mediaSourceUri!(path);
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => MediaViewerDialog(
        path: path,
        mime: file.mime,
        title: file.path,
        sourceUri: source,
      ),
    );
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
