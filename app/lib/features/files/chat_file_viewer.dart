/// 聊天附件的通用查看页。
///
/// 图片 / 音视频由 MediaViewerDialog 处理；这里覆盖其余绝大多数格式：
/// 纯文本与代码直接内联展示，zip/tar 列出内部条目，其他格式给出元信息
/// 与「保存到本机」入口，保存后用系统程序打开。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/chat_message.dart';
import '../../l10n/l10n.dart';
import 'chat_file_actions.dart';

class ChatFileViewer extends StatefulWidget {
  const ChatFileViewer({
    super.key,
    required this.name,
    required this.mime,
    required this.size,
    required this.readBytes,
    required this.onSave,
  });

  final String name;
  final String mime;
  final int size;
  final Future<Uint8List> Function() readBytes;
  final Future<String?> Function() onSave;

  @override
  State<ChatFileViewer> createState() => _ChatFileViewerState();
}

class _ChatFileViewerState extends State<ChatFileViewer> {
  late final bool _text = isTextPreviewable(widget.name, widget.mime);
  late final bool _archive = isArchivePreviewable(widget.name);
  String? _textContent;
  List<String>? _entries;
  String? _error;
  bool _loading = false;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 本地化属于 InheritedWidget，必须等 didChangeDependencies 才能读取；
    // 在 initState 里直接取 context.l10n 会触发断言。
    if (!_started && (_text || _archive)) {
      _started = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final l10n = context.l10n;
    setState(() => _loading = true);
    try {
      final Uint8List bytes = await widget.readBytes();
      if (_text) {
        _textContent = utf8.decode(bytes, allowMalformed: true);
      }
      if (_archive) {
        final Archive archive = ZipDecoder().decodeBytes(bytes);
        _entries = archive.files.map((ArchiveFile file) => file.name).toList();
      }
      _error = null;
    } on Object catch (error) {
      _error = l10n.t('读取文件失败：{0}', [error]);
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final String? saved = await widget.onSave();
    if (!mounted || saved == null || saved.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t('已保存到：{0}', [saved]))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('chat-file-viewer-save'),
            icon: const Icon(Icons.save_alt_outlined),
            tooltip: context.t('保存到本机'),
            onPressed: () => unawaited(_save()),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_text) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          key: const ValueKey<String>('chat-file-text-preview'),
          _textContent ?? '',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      );
    }
    if (_archive) {
      final List<String> entries = _entries ?? const <String>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.t('压缩包内容'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(child: Text(context.t('无文件')))
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (BuildContext context, int index) => ListTile(
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(entries[index]),
                    ),
                  ),
          ),
        ],
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.insert_drive_file_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(widget.name, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(_sizeText),
            const SizedBox(height: 16),
            Text(
              context.t('该格式暂不支持在线查看，请保存到本机后用对应程序打开'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey<String>('chat-file-save'),
              icon: const Icon(Icons.save_alt_outlined),
              label: Text(context.t('保存到本机')),
              onPressed: () => unawaited(_save()),
            ),
          ],
        ),
      ),
    );
  }

  String get _sizeText =>
      widget.size > 0 ? formatFileSize(widget.size) : '';
}
