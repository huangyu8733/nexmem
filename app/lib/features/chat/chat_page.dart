import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/empty_state.dart';
import '../../app/theme.dart';
import '../chats/conversation.dart';
import '../group/group_storage.dart';
import '../settings/diagnostics.dart';
import '../settings/report.dart';
import 'chat_message.dart';
import 'chat_store.dart';
import 'local_image.dart';

/// 群聊 @ 候选成员（七-1）：[account] 是账号公钥 base64，[name] 是展示名。
class MentionCandidate {
  const MentionCandidate({required this.account, required this.name});

  final String account;
  final String name;
}

/// 桌面 / Web 右侧聊天区空态（未选中会话）。
class ChatPlaceholder extends StatelessWidget {
  const ChatPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface.withValues(alpha: 0.4),
      child: const EmptyState(
        icon: Icons.forum_outlined,
        message: '选择一个会话开始聊天',
      ),
    );
  }
}

/// 聊天页（P1-19 / P2-04）：顶部栏 + 消息区 + 输入工具条（ui-spec.md §3）。
class ChatPage extends StatelessWidget {
  const ChatPage({
    super.key,
    required this.conversation,
    required this.store,
    this.onBack,
    this.onSent,
    this.onOpenGroupInfo,
    this.onToggleProfile,
    this.profileOpen = false,
    this.onStartCall,
    this.onPickFile,
    this.onDeleteMessage,
    this.onForwardMessage,
    this.onRecallMessage,
    this.onClearHistory,
    this.onLoadOlder,
    this.highlightMsgUuid,
    this.reportSink = const UnavailableReportSink(),
    this.diagnostics = const UnavailableDiagnosticsService(),
    this.mentionCandidates = const <MentionCandidate>[],
    this.onTypingChanged,
    this.onEditMessage,
  });

  final ConversationItem conversation;
  final ChatStore store;

  /// 群聊可 @ 的成员候选（七-1）；为空时不展示 @ 入口。
  final List<MentionCandidate> mentionCandidates;

  /// 单聊输入状态上报（七-3）；由壳层接到内核 dm.setTyping。
  final ValueChanged<bool>? onTypingChanged;

  /// 编辑消息正文（七-2）；由壳层接到内核 msg.edit。
  final Future<void> Function(String msgUuid, String newText)? onEditMessage;

  /// 移动端返回会话列表；桌面端为空。
  final VoidCallback? onBack;

  /// 发送成功后回写会话摘要与时间（由壳层更新会话列表）。
  final ValueChanged<String>? onSent;

  /// 群聊顶部「群设置」入口（P4-09）；为空或单聊时不展示。
  final VoidCallback? onOpenGroupInfo;

  /// 桌面 / Web 右侧资料面板开关（P6-22）；为空时不展示入口。
  final VoidCallback? onToggleProfile;

  /// 资料面板当前是否展开。
  final bool profileOpen;

  /// 发起音视频通话（P6-28）；仅单聊传入，群聊为空不展示入口。
  /// 参数为是否视频通话。
  final ValueChanged<bool>? onStartCall;

  /// 选择待发送文件（P2-04）；为空时弹出本机路径输入框。
  ///
  /// 返回本机绝对路径文件；用户取消返回 null。桌面端由平台文件选择器注入，
  /// Web / 移动端可注入平台实现。
  final Future<ChatAttachment?> Function()? onPickFile;

  /// 本地删除一条消息（P6-11 长按 / 右键菜单），由壳层调用 `msg.delete`。
  /// 为空（离线模式）时仅从内存移除。
  final Future<void> Function(String msgUuid)? onDeleteMessage;

  /// 转发一文本消息到其他会话（P6-12）；返回 false 表示用户取消或没有目标。
  final Future<bool> Function(ChatMessage message)? onForwardMessage;

  /// 撤回自己 2 分钟内的消息（P6-12），由壳层调用 `msg.recall`；为空时仅本机移除。
  final Future<void> Function(ChatMessage message)? onRecallMessage;

  /// 清空本机历史（P6-13），由壳层调用 `conversation.clear`；为空时仅清空内存列表。
  final Future<void> Function()? onClearHistory;

  /// 向上翻页加载更早消息（P6-07）；返回是否还有更早的历史。
  final Future<bool> Function()? onLoadOlder;

  /// 需要定位并高亮的消息 ID（搜索命中直达）；为空时无高亮。
  final String? highlightMsgUuid;

  /// 举报上报通道与诊断服务，由 `core.start` 注入。
  final ReportSink reportSink;
  final DiagnosticsService diagnostics;

  Future<void> _pickAndSendFile(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ChatAttachment? file = onPickFile != null
        ? await onPickFile!()
        : await showDialog<ChatAttachment>(
            context: context,
            builder: (BuildContext context) => const FileSendDialog(),
          );
    if (file == null || file.path.trim().isEmpty) {
      return;
    }
    try {
      await store.sendFile(file, senderName: '我');
      onSent?.call(file.name);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('文件发送失败：$error')));
    }
  }

  /// 发送图片（P6-16）：复用文件通道，按扩展名补齐 MIME 以便内联预览。
  Future<void> _pickAndSendImage(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ChatAttachment? picked = onPickFile != null
        ? await onPickFile!()
        : await showDialog<ChatAttachment>(
            context: context,
            builder: (BuildContext context) =>
                const FileSendDialog(title: '发送图片'),
          );
    if (picked == null || picked.path.trim().isEmpty) {
      return;
    }
    if (!picked.isImage) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请选择图片文件（png / jpg / gif / webp）')),
      );
      return;
    }
    try {
      await store.sendFile(picked, senderName: '我');
      onSent?.call(picked.name);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('图片发送失败：$error')));
    }
  }

  /// 发送语音消息（A-01）：复用 [onPickFile] 选择本机音频文件，
  /// 经 `dm.sendFile` 文件通道送达。本实现只覆盖「选音频 → 发送 → 展示」闭环，
  /// 不伪造录音能力（麦克风采集需原生插件与权限，见剩余开发进度 C-01）。
  Future<void> _pickAndSendVoice(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (conversation.isGroup) {
      messenger.showSnackBar(
        const SnackBar(content: Text('群聊暂不支持发送语音')),
      );
      return;
    }
    final ChatAttachment? picked = onPickFile != null
        ? await onPickFile!()
        : await showDialog<ChatAttachment>(
            context: context,
            builder: (BuildContext context) =>
                const FileSendDialog(title: '发送语音'),
          );
    if (picked == null || picked.path.trim().isEmpty) {
      return;
    }
    // 补齐 MIME：选择器未给出 MIME 时按扩展名推断，便于接收端识别为语音。
    final String mime = picked.mime.trim().isEmpty
        ? audioMimeFor(picked.name)
        : picked.mime;
    if (!isAudioAttachment(name: picked.name, mime: mime)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请选择音频文件（m4a / mp3 / wav / aac 等）')),
      );
      return;
    }
    try {
      await store.sendFile(
        picked.copyWith(mime: mime),
        senderName: '我',
      );
      onSent?.call(picked.name);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('语音发送失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        children: <Widget>[
          _ChatHeader(
            conversation: conversation,
            store: store,
            onBack: onBack,
            onOpenGroupInfo: onOpenGroupInfo,
            onToggleProfile: onToggleProfile,
            profileOpen: profileOpen,
            onStartCall: onStartCall,
            onClearHistory: onClearHistory,
            reportSink: reportSink,
            diagnostics: diagnostics,
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: store,
              builder: (BuildContext context, Widget? _) {
                return _MessageList(
                  store: store,
                  isGroup: conversation.isGroup,
                  onDeleteMessage: onDeleteMessage,
                  onForwardMessage: onForwardMessage,
                  onRecallMessage: onRecallMessage,
                  onEditMessage: onEditMessage,
                  onLoadOlder: onLoadOlder,
                  highlightMsgUuid: highlightMsgUuid,
                );
              },
            ),
          ),
          ChatInputArea(
            conversation: conversation,
            store: store,
            onSend: (String text, List<String> mentions, int ttlHours) {
              // 不等待通道回执，输入框立即清空；状态由消息行自行刷新。
              // 引用 ID 由 InputArea 在清空前捕获，这里再读一次以带 replyTo（P6-32）。
              store.send(
                text,
                senderName: '我',
                replyTo: store.quoting?.id,
                mentions: mentions,
                ttlHours: ttlHours,
              );
              onSent?.call(text);
            },
            onTypingChanged: onTypingChanged,
            mentionCandidates: mentionCandidates,
            onAttachFile: () => _pickAndSendFile(context),
            onAttachImage: () => _pickAndSendImage(context),
            onAttachVoice: () => _pickAndSendVoice(context),
          ),
        ],
      ),
    );
  }
}

/// 兜底的文件选择：输入本机绝对路径（无插件依赖，桌面 / 移动端通用）。
class FileSendDialog extends StatefulWidget {
  const FileSendDialog({super.key, this.title = '发送文件'});

  /// 弹窗标题：发送文件 / 发送图片复用同一路径入口。
  final String title;

  @override
  State<FileSendDialog> createState() => _FileSendDialogState();
}

class _FileSendDialogState extends State<FileSendDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _path => _controller.text.trim();

  void _submit() {
    final String path = _path;
    if (path.isEmpty) {
      return;
    }
    final String name = path.split(RegExp(r'[\\/]')).last;
    Navigator.of(context).pop(
      ChatAttachment(name: name.isEmpty ? path : name, size: 0, path: path),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: '本机文件绝对路径',
          hintText: 'D:\\docs\\report.pdf',
          isDense: true,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _path.isEmpty ? null : _submit,
          child: const Text('发送'),
        ),
      ],
    );
  }
}

/// 输入区容器：单聊降级提示（P3-09）与群盘未配置提示（P4-07）常驻在工具条上方。
class ChatInputArea extends StatelessWidget {
  const ChatInputArea({
    super.key,
    required this.conversation,
    required this.store,
    this.onSend,
    this.onAttachFile,
    this.onAttachImage,
    this.onAttachVoice,
    this.onTypingChanged,
    this.mentionCandidates = const <MentionCandidate>[],
  });

  final ConversationItem conversation;
  final ChatStore store;

  /// 发送回调；为空时直接调用 [ChatStore.send]。mentions 为本次 @ 的成员账号，
  /// ttlHours 为定时消息存活小时数（0 表示不开启，七-4）。
  final void Function(String text, List<String> mentions, int ttlHours)? onSend;

  /// 单聊输入状态上报（七-3）。
  final ValueChanged<bool>? onTypingChanged;

  /// 群聊 @ 候选成员（七-1）。
  final List<MentionCandidate> mentionCandidates;

  /// 「文件」工具入口；为空时提示功能未开放。
  final VoidCallback? onAttachFile;

  /// 「图片」工具入口（P6-16）；为空时提示功能未开放。
  final VoidCallback? onAttachImage;

  /// 「语音」工具入口（A-01）；为空时提示功能未开放。
  final VoidCallback? onAttachVoice;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? _) {
        final bool degraded =
            !conversation.isGroup && store.peerOfflineStorageDisabled;
        final bool groupStorageMissing =
            conversation.isGroup &&
            store.groupStorage == GroupStorageStatus.unconfigured;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (groupStorageMissing) const GroupStorageNotice(),
            if (degraded) const OfflineStorageNotice(),
            if (store.quoting != null)
              _QuotePreview(
                quoting: store.quoting!,
                onCancel: () => store.setQuoting(null),
              ),
            ChatInputBar(
              onSend: (String text, List<String> mentions, int ttlHours) {
                final String? replyTo = store.quoting?.id;
                if (onSend != null) {
                  onSend!(text, mentions, ttlHours);
                } else {
                  store.send(
                    text,
                    senderName: '我',
                    replyTo: replyTo,
                    mentions: mentions,
                    ttlHours: ttlHours,
                  );
                }
                // 引用随本次发送一并清空；无引用时 setQuoting(null) 是无害的空操作。
                store.setQuoting(null);
              },
              onAttachFile: onAttachFile,
              onAttachImage: onAttachImage,
              onAttachVoice: onAttachVoice,
              onTypingChanged: onTypingChanged,
              mentionCandidates: mentionCandidates,
            ),
          ],
        );
      },
    );
  }
}

/// 单聊降级提示条：ui-spec.md §3「对方未开启离线存储，仅支持在线发送」。
class OfflineStorageNotice extends StatelessWidget {
  const OfflineStorageNotice({super.key});

  static const String message = '对方未开启离线存储，仅支持在线发送';

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
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontSize: 12, color: NexmemColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.conversation,
    required this.store,
    this.onBack,
    this.onOpenGroupInfo,
    this.onToggleProfile,
    this.profileOpen = false,
    this.onStartCall,
    this.onClearHistory,
    this.reportSink = const UnavailableReportSink(),
    this.diagnostics = const UnavailableDiagnosticsService(),
  });

  final ConversationItem conversation;
  final ChatStore store;
  final VoidCallback? onBack;
  final VoidCallback? onOpenGroupInfo;
  final VoidCallback? onToggleProfile;
  final bool profileOpen;
  final ValueChanged<bool>? onStartCall;
  final Future<void> Function()? onClearHistory;
  final ReportSink reportSink;
  final DiagnosticsService diagnostics;

  Future<void> _openReport(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? submitted = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => ReportDialog(
        conversationId: conversation.id,
        reportSink: reportSink,
        diagnostics: diagnostics,
      ),
    );
    if (submitted == true) {
      messenger.showSnackBar(const SnackBar(content: Text('举报已提交，感谢反馈')));
    }
  }

  /// 清空聊天记录（P6-13）：先二次确认，内核清空成功后再清空本机列表。
  Future<void> _openClear(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: Text('将删除与「${conversation.title}」的本机聊天记录，且无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await onClearHistory?.call();
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('清空失败：$error')));
      return;
    }
    store.clear();
    messenger.showSnackBar(const SnackBar(content: Text('聊天记录已清空')));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? secondary = Theme.of(context).textTheme.bodySmall
        ?.copyWith(
          fontSize: 11,
          color: scheme.onSurface.withValues(alpha: 0.5),
        );
    return SizedBox(
      height: 52,
      child: Row(
        children: <Widget>[
          if (onBack != null)
            IconButton(
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              onPressed: onBack,
            ),
          const SizedBox(width: NexmemMetrics.space12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                Text(
                  conversation.isGroup
                      ? '群聊'
                      : _presenceLabel(conversation.presence),
                  style: secondary,
                ),
              ],
            ),
          ),
          if (!conversation.isGroup && onStartCall != null) ...<Widget>[
            IconButton(
              key: const ValueKey<String>('chat-call-audio'),
              tooltip: '语音通话',
              icon: const Icon(Icons.call, size: 20),
              onPressed: () => onStartCall!(false),
            ),
            IconButton(
              key: const ValueKey<String>('chat-call-video'),
              tooltip: '视频通话',
              icon: const Icon(Icons.videocam, size: 20),
              onPressed: () => onStartCall!(true),
            ),
          ],
          if (onToggleProfile != null)
            IconButton(
              key: const ValueKey<String>('chat-profile-toggle'),
              tooltip: profileOpen ? '收起聊天信息' : '聊天信息',
              icon: Icon(
                profileOpen ? Icons.info : Icons.info_outline,
                size: 20,
              ),
              onPressed: onToggleProfile,
            ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz, size: 22),
            onSelected: (String value) {
              if (value == 'clear') {
                _openClear(context);
                return;
              }
              if (value == 'groupInfo') {
                onOpenGroupInfo?.call();
                return;
              }
              if (value == 'report') {
                _openReport(context);
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              if (conversation.isGroup && onOpenGroupInfo != null)
                const PopupMenuItem<String>(
                  value: 'groupInfo',
                  child: Text('群设置'),
                ),
              const PopupMenuItem<String>(
                value: 'clear',
                child: Text('清空聊天记录'),
              ),
              const PopupMenuItem<String>(value: 'report', child: Text('举报')),
            ],
          ),
          const SizedBox(width: NexmemMetrics.space4),
        ],
      ),
    );
  }

  static String _presenceLabel(PresenceStatus status) {
    return switch (status) {
      PresenceStatus.online => '在线',
      PresenceStatus.relay => '经中继',
      PresenceStatus.offline => '离线',
    };
  }
}

/// 消息区：倒序 `ListView.builder` 保证始终贴底且只构建可视范围。
class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.store,
    required this.isGroup,
    this.onDeleteMessage,
    this.onForwardMessage,
    this.onRecallMessage,
    this.onEditMessage,
    this.onLoadOlder,
    this.highlightMsgUuid,
  });

  final ChatStore store;
  final bool isGroup;
  final Future<void> Function(String msgUuid)? onDeleteMessage;
  final Future<bool> Function(ChatMessage message)? onForwardMessage;
  final Future<void> Function(ChatMessage message)? onRecallMessage;
  final Future<void> Function(String msgUuid, String newText)? onEditMessage;
  final Future<bool> Function()? onLoadOlder;
  final String? highlightMsgUuid;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  /// 距底部小于该距离视为「贴底」，新消息自动跟随。
  static const double _bottomThreshold = 64;

  /// 距「更早」方向小于该距离时预取上一页（P6-07）。
  static const double _olderThreshold = 240;

  final ScrollController _controller = ScrollController();

  /// 搜索命中消息的定位锚点（P6-07）。
  final GlobalKey _highlightKey = GlobalKey();

  bool _atBottom = true;
  int _unseen = 0;

  /// 上一次构建时的消息条数；`store` 为同一实例，不能从 `oldWidget` 取长度。
  int _count = 0;

  /// 当前最新一条消息的 ID，用于区分「收到新消息」与「加载更早历史」。
  String _newestId = '';

  bool _loadingOlder = false;
  bool _noMoreOlder = false;
  bool _focusedHighlight = false;

  @override
  void initState() {
    super.initState();
    final List<ChatMessage> messages = widget.store.messages;
    _count = messages.length;
    _newestId = messages.isEmpty ? '' : messages.last.id;
    _controller.addListener(_onScroll);
    if ((widget.highlightMsgUuid ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusHighlight();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlightMsgUuid != widget.highlightMsgUuid) {
      _focusedHighlight = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusHighlight();
        }
      });
    }
    final List<ChatMessage> messages = widget.store.messages;
    final String newestId = messages.isEmpty ? '' : messages.last.id;
    final bool newTail =
        newestId.isNotEmpty && (_newestId.isEmpty || newestId != _newestId);
    int added = 0;
    if (newTail) {
      final int index = messages.indexWhere(
        (ChatMessage message) => message.id == _newestId,
      );
      added = index < 0 ? messages.length - _count : messages.length - index - 1;
      if (added < 0) {
        added = 0;
      }
    }
    _count = messages.length;
    _newestId = newestId;
    if (added <= 0) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_atBottom) {
        _scrollToLatest();
      } else {
        setState(() => _unseen += added);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) {
      return;
    }
    final ScrollPosition position = _controller.position;
    final bool atBottom = position.pixels <= _bottomThreshold;
    _atBottom = atBottom;
    if (atBottom && _unseen > 0) {
      setState(() => _unseen = 0);
    }
    // reverse 列表的「更早」方向对应 maxScrollExtent 一侧。
    if (position.pixels >= position.maxScrollExtent - _olderThreshold) {
      unawaited(_loadOlder());
    }
  }

  /// 向上翻页加载更早消息；返回是否还有更早的历史（P6-07）。
  Future<bool> _loadOlder() async {
    final Future<bool> Function()? call = widget.onLoadOlder;
    if (call == null || _loadingOlder || _noMoreOlder || widget.store.isEmpty) {
      return !_noMoreOlder;
    }
    _loadingOlder = true;
    try {
      final bool more = await call();
      if (!mounted) {
        return more;
      }
      _noMoreOlder = !more;
      return more;
    } finally {
      _loadingOlder = false;
    }
  }

  /// 搜索命中定位：估算命中项位置后滚动，并在气泡构建后精确居中高亮。
  void _focusHighlight() {
    final String id = widget.highlightMsgUuid ?? '';
    if (id.isEmpty || _focusedHighlight) {
      return;
    }
    final List<ChatMessage> messages = widget.store.messages;
    final int position = messages.indexWhere(
      (ChatMessage message) => message.id == id,
    );
    if (position < 0) {
      return;
    }
    if (!_controller.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusHighlight();
        }
      });
      return;
    }
    _focusedHighlight = true;
    final ScrollPosition scroll = _controller.position;
    final int index = messages.length - 1 - position;
    final double estimate = messages.length <= 1
        ? 0
        : scroll.maxScrollExtent * (index / (messages.length - 1));
    _controller.jumpTo(estimate.clamp(0.0, scroll.maxScrollExtent));
    _atBottom = _controller.offset <= _bottomThreshold;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final BuildContext? target = _highlightKey.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.5,
            duration: const Duration(milliseconds: 250),
          ),
        );
      }
    });
  }

  /// 本地删除：先落库（`msg.delete`），成功后再移除内存记录（P6-11）。
  Future<void> _deleteMessage(ChatMessage message) async {
    final Future<void> Function(String)? call = widget.onDeleteMessage;
    if (call != null) {
      await call(message.id);
    }
    widget.store.remove(message.id);
  }

  /// 撤回：先经内核 `msg.recall` 删除本机并通知对端，成功后再移除气泡（P6-12）。
  Future<void> _recallMessage(ChatMessage message) async {
    final Future<void> Function(ChatMessage)? call = widget.onRecallMessage;
    if (call != null) {
      await call(message);
    }
    widget.store.remove(message.id);
  }

  /// 编辑：经内核 `msg.edit` 更新正文，成功后即时刷新本地气泡（七-2）。
  Future<void> _editMessage(ChatMessage message, String newText) async {
    final Future<void> Function(String, String)? call = widget.onEditMessage;
    if (call != null) {
      await call(message.id, newText);
    }
    widget.store.updateEdited(message.id, newText, DateTime.now().millisecondsSinceEpoch);
  }

  void _scrollToLatest() {
    if (!_controller.hasClients) {
      return;
    }
    _controller.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<ChatMessage> messages = widget.store.messages;
    if (messages.isEmpty) {
      return const EmptyState(
        icon: Icons.chat_outlined,
        message: '还没有消息，发送第一条打个招呼',
      );
    }
    return Stack(
      children: <Widget>[
        ListView.builder(
          controller: _controller,
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: NexmemMetrics.space12),
          itemCount: messages.length,
          itemBuilder: (BuildContext context, int index) {
            final int position = messages.length - 1 - index;
            final ChatMessage message = messages[position];
            final ChatMessage? previous = position > 0
                ? messages[position - 1]
                : null;
            final bool showTime = shouldShowTimeSeparator(
              previous?.sentAt,
              message.sentAt,
            );
            final bool showSender =
                widget.isGroup &&
                !message.isMine &&
                (previous == null ||
                    showTime ||
                    previous.senderId != message.senderId);
            final bool highlighted = widget.highlightMsgUuid == message.id;
            final Widget bubble = MessageBubble(
              key: ValueKey<String>('message-${message.id}'),
              message: message,
              showSenderName: showSender,
              highlighted: highlighted,
              onRetry: () => widget.store.retry(message.id),
              onDelete: () => _deleteMessage(message),
              onForward: widget.onForwardMessage == null
                  ? null
                  : () => widget.onForwardMessage!(message),
              onRecall: widget.onRecallMessage == null
                  ? null
                  : () => _recallMessage(message),
              onEdit: widget.onEditMessage == null
                  ? null
                  : (String uuid, String newText) =>
                        _editMessage(message, newText),
              onQuote: widget.isGroup
                  ? null
                  : () => widget.store.setQuoting(message),
              quoted: message.replyTo.isEmpty
                  ? null
                  : widget.store.byId(message.replyTo),
            );
            return Column(
              children: <Widget>[
                if (showTime) MessageTimeSeparator(time: message.sentAt),
                if (highlighted)
                  KeyedSubtree(key: _highlightKey, child: bubble)
                else
                  bubble,
              ],
            );
          },
        ),
        if (_unseen > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: NexmemMetrics.space12,
            child: Center(
              child: _NewMessagePill(
                count: _unseen,
                onTap: () => _scrollToLatest(),
              ),
            ),
          ),
        if (_unseen == 0)
          Positioned(
            left: NexmemMetrics.space12,
            bottom: NexmemMetrics.space8,
            child: ListenableBuilder(
              listenable: widget.store,
              builder: (BuildContext context, Widget? child) {
                if (!widget.store.typing) {
                  return const SizedBox.shrink();
                }
                final ColorScheme localScheme = Theme.of(context).colorScheme;
                return Container(
                  key: const ValueKey<String>('typing-indicator'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: localScheme.surfaceContainerHighest.withValues(
                      alpha: 0.9,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('···', style: TextStyle(fontSize: 16)),
                      SizedBox(width: 6),
                      Text('对方正在输入…', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// 「N 条新消息」浮标，仅在用户上翻查看历史时出现。
class _NewMessagePill extends StatelessWidget {
  const _NewMessagePill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NexmemColors.primary,
      borderRadius: BorderRadius.circular(16),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.arrow_downward, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                '$count 条新消息',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 时间分隔条：今天 `HH:mm`、昨天 `昨天 HH:mm`、更早带日期。
class MessageTimeSeparator extends StatelessWidget {
  const MessageTimeSeparator({super.key, required this.time});

  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NexmemMetrics.space8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space8,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            formatMessageTime(time),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单条消息：自己靠右主色气泡，对方靠左浅色气泡，群聊显示发送者昵称。
/// 把文本里的 `@xxx`（直到空白）渲染为高亮片段（七-1）。
/// 仅做视觉提示，@ 的真实身份存于 [ChatMessage.mentions]。
TextSpan _mentionTextSpan(
  String text, {
  required Color baseColor,
  required Color highlightColor,
}) {
  final List<InlineSpan> spans = <InlineSpan>[];
  final RegExp re = RegExp(r'@[^\s]+');
  int cursor = 0;
  for (final Match match in re.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    spans.add(TextSpan(
      text: match.group(0),
      style: TextStyle(color: highlightColor, fontWeight: FontWeight.w600),
    ));
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(
    style: TextStyle(fontSize: 15, height: 1.35, color: baseColor),
    children: spans,
  );
}

Widget _highlightMentions(
  String text, {
  required bool mine,
  required Color baseColor,
  required Color highlightColor,
}) {
  // 无 @ 时保持普通 Text（find.text 可命中，且渲染更轻）；含 @ 才用 RichText 高亮。
  if (!text.contains('@')) {
    return Text(
      text,
      style: TextStyle(fontSize: 15, height: 1.35, color: baseColor),
    );
  }
  return RichText(
    text: _mentionTextSpan(
      text,
      baseColor: baseColor,
      highlightColor: highlightColor,
    ),
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.showSenderName = false,
    this.highlighted = false,
    this.onRetry,
    this.onDelete,
    this.onForward,
    this.onRecall,
    this.onEdit,
    this.onQuote,
    this.quoted,
  });

  final ChatMessage message;
  final bool showSenderName;

  /// 搜索命中定位时的高亮底色（P6-07）。
  final bool highlighted;
  final VoidCallback? onRetry;

  /// 本地删除本条消息（P6-11 长按 / 右键菜单）。
  final Future<void> Function()? onDelete;

  /// 转发本条文本消息（P6-12）；为空时不展示入口。
  final Future<bool> Function()? onForward;

  /// 撤回本条消息（P6-12，仅自己 2 分钟内，单聊与群聊均可用）；为空时不展示入口。
  final Future<void> Function()? onRecall;

  /// 编辑本条消息正文（七-2，仅自己发出的文本消息）；为空时不展示入口。
  final Future<void> Function(String msgUuid, String newText)? onEdit;

  /// 引用本条消息（P6-32，仅单聊）；为空时不展示入口。
  final VoidCallback? onQuote;

  /// 本条消息引用的原消息（用于气泡内引用条展示）；找不到原消息时为 null。
  final ChatMessage? quoted;

  /// 撤回有效期：ui-spec.md §3「仅自己，2 分钟内」。
  static const Duration _recallWindow = Duration(minutes: 2);

  /// 编辑有效期与内核 msg.edit 的 24 小时窗口一致（七-2）。
  static const Duration _editWindow = Duration(hours: 24);

  bool get _canRecall =>
      onRecall != null &&
      message.isMine &&
      DateTime.now().difference(message.sentAt) <= _recallWindow;

  bool get _canEdit =>
      onEdit != null &&
      !message.isFile &&
      message.isMine &&
      DateTime.now().difference(message.sentAt) <= _editWindow;

  /// 长按（移动端）与右键（桌面端）弹出消息操作菜单。
  Future<void> _showActions(BuildContext context, Offset globalPosition) async {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        if (!message.isFile)
          const PopupMenuItem<String>(value: 'copy', child: Text('复制')),
        if (!message.isFile && onForward != null)
          const PopupMenuItem<String>(value: 'forward', child: Text('转发')),
        if (!message.isFile && onQuote != null)
          const PopupMenuItem<String>(value: 'quote', child: Text('引用')),
        if (_canEdit)
          const PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
        if (_canRecall)
          const PopupMenuItem<String>(value: 'recall', child: Text('撤回')),
        const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
      ],
    );
    if (action == null || !context.mounted) {
      return;
    }
    if (action == 'copy') {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      await Clipboard.setData(ClipboardData(text: message.text));
      messenger.showSnackBar(const SnackBar(content: Text('已复制')));
      return;
    }
    if (action == 'forward') {
      await _forward(context);
      return;
    }
    if (action == 'quote') {
      onQuote?.call();
      return;
    }
    if (action == 'edit') {
      await _editMessage(context);
      return;
    }
    if (action == 'recall') {
      await _confirmRecall(context);
      return;
    }
    await _confirmDelete(context);

  }

  /// 弹出编辑框，确认后经 onEdit 交给内核 msg.edit（七-2）。
  Future<void> _editMessage(BuildContext context) async {
    final TextEditingController controller =
        TextEditingController(text: message.text);
    final String? revised = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          key: const ValueKey<String>('edit-message-field'),
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '输入新正文'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final String text = controller.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(context).pop(text);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (revised != null && revised != message.text) {
      await onEdit?.call(message.id, revised);
    }
  }

  Future<void> _forward(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final bool forwarded = await onForward?.call() ?? false;
      if (forwarded) {
        messenger.showSnackBar(const SnackBar(content: Text('已转发')));
      }
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('转发失败：$error')));
    }
  }

  Future<void> _confirmRecall(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('撤回消息'),
        content: Text(message.isGroup ? '撤回后群内其他成员也将看不到这条消息。' : '撤回后对方也将看不到这条消息。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤回'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await onRecall?.call();
      messenger.showSnackBar(const SnackBar(content: Text('已撤回')));
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('撤回失败：$error')));
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('仅从本机删除，对方仍可看到这条消息。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await onDelete?.call();
      messenger.showSnackBar(const SnackBar(content: Text('已删除')));
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('删除失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool mine = message.isMine;
    final double maxWidth = math.min(
      520,
      MediaQuery.sizeOf(context).width * 0.72,
    );
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NexmemMetrics.space12,
        vertical: 3,
      ),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!mine) ...<Widget>[
            _BubbleAvatar(message: message),
            const SizedBox(width: NexmemMetrics.space8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: <Widget>[
                if (showSenderName)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: NexmemMetrics.space4,
                    ),
                    child: Text(
                      message.senderName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (LongPressStartDetails details) =>
                      _showActions(context, details.globalPosition),
                  onSecondaryTapDown: (TapDownDetails details) =>
                      _showActions(context, details.globalPosition),
                  child: Container(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: mine ? NexmemColors.primary : scheme.surface,
                      borderRadius: BorderRadius.circular(
                        NexmemMetrics.radiusBubble,
                      ),
                      border: mine
                          ? null
                          : Border.all(
                              color: scheme.onSurface.withValues(alpha: 0.08),
                            ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (message.replyTo.isNotEmpty)
                          _QuotedStrip(
                            label: quoted == null
                                ? '原消息'
                                : (quoted!.isMine ? '我' : quoted!.senderName),
                            text: quoted?.text ?? '原消息已不可用',
                            mine: mine,
                          ),
                        if (message.isFile)
                          _FileBubbleContent(message: message, mine: mine)
                        else
                          _highlightMentions(
                            message.text,
                            mine: mine,
                            baseColor: mine ? Colors.white : scheme.onSurface,
                            highlightColor: mine
                                ? Colors.white
                                : NexmemColors.primary,
                          ),
                        if (message.edited)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '已编辑',
                              key: const ValueKey<String>('edited-marker'),
                              style: TextStyle(
                                fontSize: 11,
                                color: mine
                                    ? Colors.white.withValues(alpha: 0.7)
                                    : scheme.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        if (message.isEphemeral)
                          _ExpiryBadge(
                            expiresAt: message.expiresAt,
                            mine: mine,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      formatBubbleTime(message.sentAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: scheme.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                    if (mine) ...<Widget>[
                      const SizedBox(width: NexmemMetrics.space4),
                      _StatusIndicator(
                        status: message.status,
                        onRetry: onRetry,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (mine) ...<Widget>[
            const SizedBox(width: NexmemMetrics.space8),
            _BubbleAvatar(message: message),
          ],
        ],
      ),
    );
    if (!highlighted) {
      return content;
    }
    return Container(
      decoration: BoxDecoration(
        color: NexmemColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusBubble),
      ),
      child: content,
    );
  }
}

/// 文件气泡内容（P2-04）：图标 + 文件名 + 大小 / 传输进度。
///
/// 点击复制本机路径，便于在内核尚未提供「打开文件」能力时定位落盘位置。
class _FileBubbleContent extends StatelessWidget {
  const _FileBubbleContent({required this.message, required this.mine});

  final ChatMessage message;
  final bool mine;

  IconData _icon(String name, String mime) {
    final String lowerName = name.toLowerCase();
    if (mime.startsWith('image/') ||
        RegExp(r'\.(png|jpe?g|gif|webp|bmp|heic)$').hasMatch(lowerName)) {
      return Icons.image_outlined;
    }
    if (mime.startsWith('video/')) {
      return Icons.movie_outlined;
    }
    if (mime.startsWith('audio/')) {
      return Icons.audiotrack_outlined;
    }
    if (RegExp(r'\.(zip|rar|7z|tar|gz)$').hasMatch(lowerName)) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  /// 图片气泡（P6-16）：缩略图 + 发送进度覆盖层 + 文件名/大小说明。
  Widget _imageContent(BuildContext context, ChatAttachment file) {
    final bool transferring = message.status == MessageStatus.sending;
    final double? ratio = message.transferRatio;
    final double side = math.min(
      180,
      MediaQuery.sizeOf(context).width * 0.5,
    );
    final Widget thumb = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LocalImage(
        key: ValueKey<String>('chat-image-${message.id}'),
        path: file.path,
        width: side,
        height: side,
        fit: BoxFit.cover,
      ),
    );
    final Widget body = transferring
        ? Stack(
            children: <Widget>[
              thumb,
              Container(
                width: side,
                height: side,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      ratio == null ? '发送中' : '${(ratio * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          )
        : thumb;
    final Color noteColor = mine
        ? Colors.white.withValues(alpha: 0.8)
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        body,
        const SizedBox(height: 4),
        SizedBox(
          width: side,
          child: Text(
            file.size > 0
                ? '${file.name} · ${formatFileSize(file.size)}'
                : file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: noteColor),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ChatAttachment file = message.attachment!;
    if (file.isImage && file.path.isNotEmpty) {
      return _imageContent(context, file);
    }
    final Color fg = mine
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final Color muted = fg.withValues(alpha: 0.75);
    final double? ratio = message.transferRatio;
    final bool transferring = message.status == MessageStatus.sending;
    final String sizeText = file.size > 0 ? formatFileSize(file.size) : '大小未知';
    final String detail = transferring && ratio != null
        ? '${(ratio * 100).round()}% · $sizeText'
        : sizeText;
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _icon(file.name, file.mime.toLowerCase()),
              size: 28,
              color: fg,
            ),
            const SizedBox(width: NexmemMetrics.space8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(detail, style: TextStyle(fontSize: 11, color: muted)),
                ],
              ),
            ),
          ],
        ),
        if (transferring)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 3,
              backgroundColor: muted.withValues(alpha: 0.3),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
      ],
    );
    if (file.path.isEmpty) {
      return content;
    }
    return Tooltip(
      message: file.path,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
            context,
          );
          await Clipboard.setData(ClipboardData(text: file.path));
          messenger.showSnackBar(const SnackBar(content: Text('已复制文件路径')));
        },
        child: content,
      ),
    );
  }
}

/// 定时消息气泡内的剩余时间徽标（七-4）：按构建时的 expiresAt 计算剩余
/// 时间，随时间推移在下次列表刷新时更新；到期由内核物理删除并发
/// `message.expired`，客户端据此移除气泡。不使用周期计时器以免干扰
/// widget 测试的 pumpAndSettle。
class _ExpiryBadge extends StatelessWidget {
  const _ExpiryBadge({required this.expiresAt, required this.mine});

  final int expiresAt;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final String label = formatExpiryRemaining(expiresAt);
    if (label.isEmpty) {
      return const SizedBox.shrink();
    }
    final Color color = mine
        ? Colors.white.withValues(alpha: 0.85)
        : NexmemColors.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.timer_outlined, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            key: const ValueKey<String>('expiry-countdown'),
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }
}

class _BubbleAvatar extends StatelessWidget {
  const _BubbleAvatar({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final Color base =
        NexmemColors.avatarPalette[(message.senderId.isEmpty
                    ? message.conversationId
                    : message.senderId)
                .hashCode
                .abs() %
            NexmemColors.avatarPalette.length];
    final String initial = message.senderName.isEmpty
        ? '?'
        : message.senderName.substring(0, 1);
    return CircleAvatar(
      radius: 18,
      backgroundColor: base.withValues(alpha: 0.16),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: base,
        ),
      ),
    );
  }
}

/// 发送状态：转圈 / 单勾 / 双勾 / 红叹号重发（ui-spec.md §3）。
class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator({required this.status, this.onRetry});

  final MessageStatus status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final Color muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.45);
    return switch (status) {
      MessageStatus.sending => const Tooltip(
        message: '发送中',
        child: SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      ),
      MessageStatus.sent => Tooltip(
        message: '已发送',
        child: Icon(Icons.check, size: 14, color: muted),
      ),
      MessageStatus.delivered => Tooltip(
        message: '已送达',
        child: Icon(Icons.done_all, size: 14, color: muted),
      ),
      MessageStatus.read => const Tooltip(
        message: '已读',
        child: Icon(Icons.done_all, size: 14, color: NexmemColors.primary),
      ),
      MessageStatus.failed => Tooltip(
        message: '发送失败，点击重发',
        child: InkWell(
          onTap: onRetry,
          borderRadius: BorderRadius.circular(2),
          child: const Icon(Icons.error, size: 14, color: NexmemColors.danger),
        ),
      ),
    };
  }
}

/// 底部输入区：工具条 + 多行输入 + 主色发送按钮（ui-spec.md §3）。
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.onSend,
    this.onAttachFile,
    this.onAttachImage,
    this.onAttachVoice,
    this.onTypingChanged,
    this.mentionCandidates = const <MentionCandidate>[],
  });

  /// 发送回调：[mentions] 为本次文本中 @ 到的成员账号 ID（七-1），
  /// [ttlHours] 为本次定时消息的存活小时数（0 表示普通消息，七-4）。
  final void Function(String text, List<String> mentions, int ttlHours) onSend;

  /// 输入状态变化回调（七-3）；仅单聊传入，节流后上报内核。
  final ValueChanged<bool>? onTypingChanged;

  /// 群聊可 @ 的成员候选（七-1）；为空时不展示 @ 入口。
  final List<MentionCandidate> mentionCandidates;

  /// 「文件」工具入口（P2-04）；为空时提示功能未开放。
  final VoidCallback? onAttachFile;

  /// 「图片」工具入口（P6-16）；为空时提示功能未开放。
  final VoidCallback? onAttachImage;

  /// 「语音」工具入口（A-01）；为空时提示功能未开放。
  final VoidCallback? onAttachVoice;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  /// 表情面板候选（P6-18）：只做字符插入，不引入图片素材或第三方插件。
  static const List<String> _emojis = <String>[
    '😀', '😁', '😂', '🤣', '😊', '😍', '🤔', '😎',
    '😭', '😅', '😘', '😡', '😴', '😇', '🥳', '🤝',
    '👍', '👎', '👏', '🙏', '💪', '🎉', '🔥', '❤️',
    '💔', '✨', '🌹', '🍀', '☀️', '🌙', '⭐', '🎁',
    '☕', '🍺', '🚀', '✅', '❌', '📌', '💡', '👀',
  ];

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _emojiOpen = false;

  /// 本次输入已选的 @ 成员账号（七-1）；发送后清空。
  final List<String> _selectedMentions = <String>[];

  /// 本次输入选中的定时消息存活小时数（七-4）；0 表示普通消息，发送后重置。
  int _ttlHours = 0;

  /// typing 上报节流：文本变化时上报 true，停止 3 秒后上报 false（七-3）。
  Timer? _typingTimer;
  bool _typingActive = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _typingTimer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    _reportTyping();
  }

  void _reportTyping() {
    final ValueChanged<bool>? cb = widget.onTypingChanged;
    if (cb == null) {
      return;
    }
    if (_controller.text.trim().isEmpty) {
      if (_typingActive) {
        _typingActive = false;
        cb(false);
      }
      _typingTimer?.cancel();
      return;
    }
    if (!_typingActive) {
      _typingActive = true;
      cb(true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      if (_typingActive) {
        _typingActive = false;
        cb(false);
      }
    });
  }

  bool get _canSend => _controller.text.trim().isNotEmpty;

  void _submit() {
    final String text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }
    final List<String> mentions = List<String>.from(_selectedMentions);
    _controller.clear();
    _selectedMentions.clear();
    _typingTimer?.cancel();
    if (_typingActive) {
      _typingActive = false;
      widget.onTypingChanged?.call(false);
    }
    final int ttlHours = _ttlHours;
    _ttlHours = 0;
    widget.onSend(text, mentions, ttlHours);
    _focus.requestFocus();
  }

  /// 定时消息 TTL 选择（七-4）：关闭 / 1 小时 / 1 天 / 7 天。
  Future<void> _showTtlPicker() async {
    final int? picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.sizeOf(context).width - 200,
        kToolbarHeight + 40,
        12,
        MediaQuery.sizeOf(context).height,
      ),
      items: <PopupMenuEntry<int>>[
        for (final int hours in ephemeralTtlOptions)
          PopupMenuItem<int>(
            key: ValueKey<String>('ttl-option-$hours'),
            value: hours,
            child: Row(
              children: <Widget>[
                Icon(
                  hours == _ttlHours
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                ),
                const SizedBox(width: NexmemMetrics.space8),
                Text(
                  hours == 0
                      ? '关闭（普通消息）'
                      : '${ephemeralTtlLabel(hours)}后销毁',
                ),
              ],
            ),
          ),
      ],
    );
    if (picked != null && mounted) {
      setState(() => _ttlHours = picked);
    }
  }

  /// 群聊 @：弹出候选成员，选中后插入 `@名字 ` 并记录账号（七-1）。
  void _showMentionPicker() {
    final List<MentionCandidate> candidates = widget.mentionCandidates;
    if (candidates.isEmpty) {
      return;
    }
    final MentionCandidate? picked = candidates.length == 1
        ? candidates.first
        : null;
    if (picked != null) {
      _insertMention(picked);
      return;
    }
    showModalBottomSheet<MentionCandidate>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            const ListTile(title: Text('选择要 @ 的成员')),
            for (final MentionCandidate candidate in candidates)
              ListTile(
                key: ValueKey<String>('mention-${candidate.account}'),
                leading: const Icon(Icons.alternate_email),
                title: Text(candidate.name),
                onTap: () => Navigator.of(context).pop(candidate),
              ),
          ],
        ),
      ),
    ).then((MentionCandidate? chosen) {
      if (chosen != null) {
        _insertMention(chosen);
      }
    });
  }

  void _insertMention(MentionCandidate candidate) {
    final String token = '@${candidate.name} ';
    final TextSelection selection = _controller.selection;
    final int start = selection.start < 0 ? _controller.text.length : selection.start;
    final int end = selection.end < 0 ? _controller.text.length : selection.end;
    _controller.value = _controller.value.copyWith(
      text: _controller.text.replaceRange(start, end, token),
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    if (!_selectedMentions.contains(candidate.account)) {
      _selectedMentions.add(candidate.account);
    }
  }

  void _notImplemented(String name) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$name功能将在后续版本开放')));
  }

  /// 展开 / 收起表情面板（ui-spec.md §3 输入工具条）。
  void _toggleEmoji() {
    setState(() => _emojiOpen = !_emojiOpen);
  }

  /// 在光标处插入表情；有选区时替换选区，光标无效时追加到末尾。
  void _insertEmoji(String emoji) {
    final TextEditingValue value = _controller.value;
    final TextSelection sel = value.selection;
    final bool valid = sel.isValid &&
        sel.start >= 0 &&
        sel.end <= value.text.length;
    final int start = valid ? sel.start : value.text.length;
    final int end = valid ? sel.end : value.text.length;
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, emoji),
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.08)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        NexmemMetrics.space8,
        6,
        NexmemMetrics.space8,
        NexmemMetrics.space8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              _ToolButton(
                icon: Icons.mic_none,
                tooltip: '语音',
                onTap:
                    widget.onAttachVoice ?? () => _notImplemented('语音'),
              ),
              _ToolButton(
                icon: _emojiOpen
                    ? Icons.keyboard_alt_outlined
                    : Icons.emoji_emotions_outlined,
                tooltip: '表情',
                onTap: _toggleEmoji,
              ),
              if (widget.mentionCandidates.isNotEmpty)
                _ToolButton(
                  icon: Icons.alternate_email,
                  tooltip: '@ 成员',
                  onTap: _showMentionPicker,
                ),
              _ToolButton(
                icon: Icons.timer_outlined,
                tooltip: _ttlHours == 0
                    ? '定时销毁'
                    : '定时销毁：${ephemeralTtlLabel(_ttlHours)}',
                onTap: _showTtlPicker,
              ),
              _ToolButton(
                icon: Icons.image_outlined,
                tooltip: '图片',
                onTap:
                    widget.onAttachImage ?? () => _notImplemented('图片'),
              ),
              _ToolButton(
                icon: Icons.attach_file,
                tooltip: '文件',
                onTap: widget.onAttachFile ?? () => _notImplemented('文件'),
              ),
            ],
          ),
          if (_ttlHours > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.timer_outlined,
                    size: 14,
                    color: NexmemColors.warning,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '定时销毁：${ephemeralTtlLabel(_ttlHours)}后',
                    key: const ValueKey<String>('ttl-active-chip'),
                    style: TextStyle(
                      fontSize: 11,
                      color: NexmemColors.warning,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: CallbackShortcuts(
                  // 桌面/Web：Enter 发送，Shift+Enter 交给输入框换行。
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.enter): _submit,
                    const SingleActivator(LogicalKeyboardKey.numpadEnter):
                        _submit,
                  },
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: '输入消息',
                      isDense: true,
                      filled: true,
                      fillColor: scheme.onSurface.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: NexmemMetrics.space12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          NexmemMetrics.radiusListItem,
                        ),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: NexmemMetrics.space8),
              FilledButton(
                onPressed: _canSend ? _submit : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 40),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      NexmemMetrics.radiusListItem,
                    ),
                  ),
                ),
                child: const Text('发送'),
              ),
            ],
          ),
          if (_emojiOpen) ...<Widget>[
            const SizedBox(height: 6),
            SizedBox(
              key: const ValueKey<String>('chat-emoji-panel'),
              height: 132,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Wrap(
                    spacing: 2,
                    runSpacing: 2,
                    children: <Widget>[
                      for (final String emoji in _emojis)
                        _EmojiButton(
                          emoji: emoji,
                          onTap: () => _insertEmoji(emoji),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 表情面板单元格：纯字符按钮，尺寸固定以保持网格整齐。
class _EmojiButton extends StatelessWidget {
  const _EmojiButton({required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: InkWell(
        key: ValueKey<String>('chat-emoji-$emoji'),
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Center(
          child: Text(emoji, style: const TextStyle(fontSize: 20)),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}

/// 气泡内引用条（P6-32）：展示被引用消息的发送者与正文摘要。
class _QuotedStrip extends StatelessWidget {
  const _QuotedStrip({
    required this.label,
    required this.text,
    required this.mine,
  });

  final String label;
  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final Color foreground = mine ? Colors.white : Colors.black87;
    return Container(
      key: const ValueKey<String>('chat-quoted-strip'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: foreground.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            text.replaceAll('\n', ' '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: foreground.withValues(alpha: 0.85)),
          ),
        ],
      ),
    );
  }
}

/// 输入区上方的引用预览条（P6-32）：显示正在引用的消息并可取消。
class _QuotePreview extends StatelessWidget {
  const _QuotePreview({required this.quoting, required this.onCancel});

  final ChatMessage quoting;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('chat-quote-preview'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.primary.withValues(alpha: 0.06),
      child: Row(
        children: <Widget>[
          Container(
            width: 3,
            height: 30,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  quoting.isMine ? '引用 我' : '引用 ${quoting.senderName}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
                Text(
                  quoting.text.replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('chat-quote-cancel'),
            tooltip: '取消引用',
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
