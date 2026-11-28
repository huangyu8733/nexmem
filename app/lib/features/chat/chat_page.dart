import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/avatar.dart';
import '../../app/empty_state.dart';
import '../../app/theme.dart';
import '../browser/browser_page.dart';
import '../browser/browser_url.dart';
import '../chats/conversation.dart';
import '../contacts/contact_service.dart';
import '../files/chat_file_viewer.dart';
import '../files/media_viewer.dart';
import '../group/group_share_link.dart';
import '../group/group_storage.dart';
import '../qr/image_qr_decoder.dart';
import '../qr/qr_result_handler.dart';
import '../settings/diagnostics.dart';
import '../settings/report.dart';
import 'chat_message.dart';
import 'chat_store.dart';
import 'local_image.dart';
import 'video_thumbnail.dart';
import 'voice_recorder.dart';
import 'voice_message_bubble.dart';
import '../../app/app_dialog.dart';

/// 文本正文上限：与内核契约 dm.sendText / dm.sendGroupText / msg.edit 的
/// `text.maxLength = 4096` 保持一致，UI 层提前拦截，避免发送后才失败。
const int kMaxMessageChars = 4096;

/// 输入框字符计数：平时隐藏，接近上限时才提示，避免常驻数字影响美观。
Widget? _messageCounter(
  BuildContext context, {
  required int currentLength,
  required bool isFocused,
  required int? maxLength,
}) {
  if (maxLength == null || currentLength < maxLength - 200) {
    return null;
  }
  return Text(
    '$currentLength/$maxLength',
    style: TextStyle(
      fontSize: 11,
      color: currentLength >= maxLength
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.outline,
    ),
  );
}

/// 发送失败时把内核真实原因显示出来，而不是只留一个不可读的感叹号。
///
/// 异步回调用调用方提前捕获的 [messenger] 与模板，避免跨 async gap 使用
/// BuildContext；调用方负责在挂载状态下取得 messenger。
void _showSendFailure(
  ScaffoldMessengerState messenger,
  String template,
  Object error,
) {
  messenger.showSnackBar(
    SnackBar(content: Text(template.replaceFirst('{0}', '$error'))),
  );
}

/// QQ 风格气泡：圆角矩形 + 朝向发送方的小尖角。
///
/// 尖角位于气泡靠头像一侧的上部。自己发出的消息尖角朝右，对方朝左。
/// 通过自定义 [ShapeBorder] 实现，避免额外叠层影响命中测试与长按菜单。
class _BubbleShape extends ShapeBorder {
  const _BubbleShape({required this.mine, this.borderColor});

  final bool mine;
  final Color? borderColor;

  static const double _tail = NexmemMetrics.bubbleTail;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  ShapeBorder scale(double t) => this;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _build(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _build(rect);

  Path _build(Rect rect) {
    final double l = rect.left;
    final double t = rect.top;
    final double r = rect.right;
    final double b = rect.bottom;
    final double radius = NexmemMetrics.radiusBubble.toDouble();
    final double tailTop = t + 16;
    final Path path = Path();
    if (mine) {
      // 尖角在右上，朝右。
      path
        ..moveTo(l + radius, t)
        ..lineTo(r - radius, t)
        ..quadraticBezierTo(r, t, r, t + radius)
        ..lineTo(r, tailTop)
        ..lineTo(r + _tail, tailTop + _tail * 0.6)
        ..lineTo(r, tailTop + _tail * 1.2)
        ..lineTo(r, b - radius)
        ..quadraticBezierTo(r, b, r - radius, b)
        ..lineTo(l + radius, b)
        ..quadraticBezierTo(l, b, l, b - radius)
        ..lineTo(l, t + radius)
        ..quadraticBezierTo(l, t, l + radius, t);
    } else {
      // 尖角在左上，朝左。
      path
        ..moveTo(l + radius, t)
        ..lineTo(r - radius, t)
        ..quadraticBezierTo(r, t, r, t + radius)
        ..lineTo(r, b - radius)
        ..quadraticBezierTo(r, b, r - radius, b)
        ..lineTo(l + radius, b)
        ..quadraticBezierTo(l, b, l, b - radius)
        ..lineTo(l, tailTop + _tail * 1.2)
        ..lineTo(l - _tail, tailTop + _tail * 0.6)
        ..lineTo(l, tailTop)
        ..lineTo(l, t + radius)
        ..quadraticBezierTo(l, t, l + radius, t);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final Color? color = borderColor;
    if (color == null) {
      return;
    }
    canvas.drawPath(
      _build(rect),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = color
        ..strokeWidth = 1,
    );
  }
}

/// 群聊 @ 候选成员（七-1）：[account] 是账号公钥 base64，[name] 是展示名。
class MentionCandidate {
  const MentionCandidate({required this.account, required this.name});

  final String account;
  final String name;
}

/// 右侧群成员面板 → 聊天输入框的 @ 插入通道。
///
/// 面板只负责提交候选人；输入框监听版本号并在下一次构建周期取出，
/// 这样两侧不需要互相持有 State，也不会因聊天页重建丢失待插入内容。
class MentionInsertController extends ValueNotifier<int> {
  MentionInsertController() : super(0);

  MentionCandidate? _pending;

  void insert(MentionCandidate candidate) {
    _pending = candidate;
    value++;
  }

  MentionCandidate? take() {
    final MentionCandidate? candidate = _pending;
    _pending = null;
    return candidate;
  }
}

/// 桌面 / Web 右侧聊天区空态（未选中会话）。
class ChatPlaceholder extends StatelessWidget {
  const ChatPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface.withValues(alpha: 0.4),
      child: EmptyState(
        icon: Icons.forum_outlined,
        message: context.t('选择一个会话开始聊天'),
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
    this.onStartRemote,
    this.onPickFile,
    this.onPickImage,
    this.onPickMedia,
    this.onPickVideo,
    this.onPickAudio,
    this.onPickFolder,
    this.voiceRecorder,
    this.onDownloadGroupFile,
    this.onSaveFile,
    this.onReadFileBytes,
    this.mediaSourceUri,
    this.onDeleteMessage,
    this.onForwardMessage,
    this.onForwardMessages,
    this.onRequestGroupJoin,
    this.onRecallMessage,
    this.onClearHistory,
    this.onLoadOlder,
    this.highlightMsgUuid,
    this.reportSink = const UnavailableReportSink(),
    this.diagnostics = const UnavailableDiagnosticsService(),
    this.mentionCandidates = const <MentionCandidate>[],
    this.mentionController,
    this.onTypingChanged,
    this.onEditMessage,
    this.presence,
    this.displayName,
    this.remark = '',
    this.onSetRemark,
    this.initialDraft = '',
    this.onDraftChanged,
  });

  final ConversationItem conversation;
  final ChatStore store;

  /// 在线状态源（十六进制账号 → 是否在线）；传入后聊天头部实时跟随轮询结果。
  final ValueListenable<Map<String, bool>>? presence;

  /// 单聊显示名：备注 > 昵称 > 账号；为空时回退到 [ConversationItem.title]。
  final String? displayName;

  /// 当前备注，供点击标题编辑备注时预填。
  final String remark;

  /// 点击聊天标题设置备注；仅单聊传入。回调参数为新的备注文本。
  final ValueChanged<String>? onSetRemark;

  /// 会话级草稿：由壳层按 conversation.id 保存，避免切换会话串台或丢失。
  final String initialDraft;
  final ValueChanged<String>? onDraftChanged;

  /// 群聊可 @ 的成员候选（七-1）；为空时不展示 @ 入口。
  final List<MentionCandidate> mentionCandidates;

  /// 右侧成员面板点成员时插入 @ 的通道（与 [mentionCandidates] 配套）。
  final MentionInsertController? mentionController;

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

  /// 发起远程控制（仅单聊传入）。
  final VoidCallback? onStartRemote;

  /// 选择待发送文件（P2-04）；为空时弹出本机路径输入框。
  ///
  /// 返回本机绝对路径文件；用户取消返回 null。桌面端由平台文件选择器注入，
  /// Web / 移动端可注入平台实现。
  final Future<ChatAttachment?> Function()? onPickFile;

  /// 选择相册图片：移动端拉起系统相册，桌面/Web 用图片过滤器。
  /// 为空时退回 [onPickFile]，保持旧部署可用。
  final Future<ChatAttachment?> Function()? onPickImage;

  /// 选择视频或音频：移动端拉起系统媒体选择器，桌面/Web 用媒体过滤器。
  /// 为空时退回 [onPickFile]，保持旧部署可用。
  final Future<ChatAttachment?> Function()? onPickMedia;

  /// 选择视频：移动端拉起系统视频库（Android MediaStore / iOS PHPicker），
  /// 桌面/Web 用视频扩展名过滤。为空时退回 [onPickMedia] 或 [onPickFile]。
  final Future<ChatAttachment?> Function()? onPickVideo;

  /// 选择音频：移动端拉起系统音频库（Android MediaStore / iOS 音乐库），
  /// 桌面/Web 用音频扩展名过滤。为空时退回 [onPickMedia] 或 [onPickFile]。
  final Future<ChatAttachment?> Function()? onPickAudio;

  /// 选择文件夹并打包为 ZIP 附件；为空时工具条不展示文件夹入口。
  final Future<ChatAttachment?> Function()? onPickFolder;

  /// 按住说话录音器：由平台注入，为空时工具条不展示录音入口。
  final VoiceRecorder? voiceRecorder;

  /// 下载群文件（A-02）：由壳层注入，参数为消息所属会话与附件元数据。
  /// 返回落盘绝对路径；为空表示回调不可用或用户取消。
  final Future<String?> Function(
    ConversationItem conversation,
    ChatMessage message,
  )?
  onDownloadGroupFile;

  /// 把附件保存到本机：群聊沿用内核解密下载，私聊 / 媒体直接复制已落盘文件。
  final Future<String?> Function(ChatMessage message)? onSaveFile;

  /// 读取附件字节供文本 / 压缩包内联预览；Web 由网关鉴权下载提供。
  final Future<Uint8List> Function(ChatMessage message)? onReadFileBytes;

  /// Web 聊天媒体在线播放源；由壳层把内核服务端路径换成鉴权 inline 链接。
  /// 桌面/移动端为空，气泡保持本地文件预览。
  final Uri? Function(String path)? mediaSourceUri;

  /// 本地删除一条消息（P6-11 长按 / 右键菜单），由壳层调用 `msg.delete`。
  /// 为空（离线模式）时仅从内存移除。
  final Future<void> Function(String msgUuid)? onDeleteMessage;

  /// 转发一文本消息到其他会话（P6-12）；返回 false 表示用户取消或没有目标。
  final Future<bool> Function(ChatMessage message)? onForwardMessage;

  /// 批量转发多条选中消息到目标会话；由壳层一次选择目标后逐条发送。
  final Future<bool> Function(List<ChatMessage> messages)? onForwardMessages;

  /// 从分享群信息的消息发起入群申请；为空时长按菜单不展示该入口。
  final Future<void> Function(GroupShareInfo info)? onRequestGroupJoin;

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
    final String selfName = context.t('我');
    final ChatAttachment? file = await _pickAttachment(context);
    if (file == null || file.path.trim().isEmpty) {
      return;
    }
    try {
      await store.sendFile(file, senderName: selfName);
      onSent?.call(file.name);
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('文件发送失败：{0}', [error]))),
      );
    }
  }

  /// 发送文件夹：平台选择器返回目录后打包为 ZIP，再走普通文件通道。
  Future<void> _pickAndSendFolder(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String selfName = context.t('我');
    final Future<ChatAttachment?> Function()? picker = onPickFolder;
    if (picker == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('当前平台不支持发送文件夹'))),
      );
      return;
    }
    try {
      final ChatAttachment? folder = await picker();
      if (folder == null || folder.path.trim().isEmpty) {
        return;
      }
      await store.sendFile(folder, senderName: selfName);
      onSent?.call(folder.name);
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(context.t('文件夹发送失败：{0}', [error])),
        ),
      );
    }
  }

  /// 发送图片（P6-16）：复用文件通道，按扩展名补齐 MIME 以便内联预览。
  Future<void> _pickAndSendImage(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String selfName = context.t('我');
    final String notImage = context.t('请选择图片文件（png / jpg / gif / webp / bmp / heic / heif / tif / avif）');
    final ChatAttachment? picked = await _pickAttachment(
      context,
      title: context.t('发送图片'),
      picker: onPickImage ?? onPickFile,
    );
    if (picked == null || picked.path.trim().isEmpty) {
      return;
    }
    if (!picked.isImage) {
      messenger.showSnackBar(SnackBar(content: Text(notImage)));
      return;
    }
    try {
      await store.sendFile(picked, senderName: selfName);
      onSent?.call(picked.name);
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('图片发送失败：{0}', [error]))),
      );
    }
  }

  /// 发送视频或音频文件：移动端拉起系统媒体选择器，桌面/Web 用媒体过滤器。
  /// 发送前补齐 MIME，保证接收端能识别为媒体气泡并直接预览/播放。
  Future<void> _pickAndSendMedia(
    BuildContext context, {
    required bool video,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String selfName = context.t('我');
    final String notMedia = video
        ? context.t('请选择视频文件')
        : context.t('请选择音频文件');
    final ChatAttachment? picked = await _pickAttachment(
      context,
      title: context.t('发送文件'),
      picker: video
          ? (onPickVideo ?? onPickMedia ?? onPickFile)
          : (onPickAudio ?? onPickMedia ?? onPickFile),
    );
    if (picked == null || picked.path.trim().isEmpty) {
      return;
    }
    final String mime = mediaMimeFor(name: picked.name, mime: picked.mime);
    final bool valid = video
        ? isVideoAttachment(name: picked.name, mime: mime)
        : isAudioAttachment(name: picked.name, mime: mime);
    if (!valid) {
      messenger.showSnackBar(SnackBar(content: Text(notMedia)));
      return;
    }
    try {
      await store.sendFile(picked.copyWith(mime: mime), senderName: selfName);
      onSent?.call(picked.name);
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('发送失败：{0}', [error]))),
      );
    }
  }

  /// 发送语音消息（A-01）：复用 [onPickFile] 选择本机音频文件，
  /// 经文件通道送达：单聊 `dm.sendFile`，群聊 `dm.sendGroupFile`（A-02）。
  /// 本实现只覆盖「选音频 → 发送 → 展示」闭环，不伪造录音能力
  /// （麦克风采集需原生插件与权限，见剩余开发进度 C-01）。
  Future<void> _pickAndSendVoice(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String selfName = context.t('我');
    final String notAudio = context.t('请选择音频文件（m4a / mp3 / wav / aac 等）');
    final ChatAttachment? picked = await _pickAttachment(
      context,
      title: context.t('发送语音'),
    );
    if (picked == null || picked.path.trim().isEmpty) {
      return;
    }
    // 补齐 MIME：选择器未给出 MIME 时按扩展名推断，便于接收端识别为语音。
    final String mime = picked.mime.trim().isEmpty
        ? audioMimeFor(picked.name)
        : picked.mime;
    if (!isAudioAttachment(name: picked.name, mime: mime)) {
      messenger.showSnackBar(SnackBar(content: Text(notAudio)));
      return;
    }
    try {
      await store.sendFile(picked.copyWith(mime: mime), senderName: selfName);
      onSent?.call(picked.name);
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('语音发送失败：{0}', [error]))),
      );
    }
  }

  /// 调用系统文件选择器；平台选择器失败时给出明确提示而不是静默无反应。
  Future<ChatAttachment?> _pickAttachment(
    BuildContext context, {
    String? title,
    Future<ChatAttachment?> Function()? picker,
  }) async {
    final Future<ChatAttachment?> Function()? effective = picker ?? onPickFile;
    try {
      if (effective != null) {
        return await effective();
      }
      return await showAppDialog<ChatAttachment>(
        context: context,
        builder: (BuildContext context) => FileSendDialog(title: title),
      );
    } on Object catch (error) {
      if (!context.mounted) {
        return null;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.t('选择文件失败：{0}', [error]))));
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String sendFailureTemplate = context.t('发送失败：{0}');
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        children: <Widget>[
          _ChatHeader(
            conversation: conversation,
            store: store,
            presence: presence,
            displayName: displayName,
            remark: remark,
            onSetRemark: onSetRemark,
            onBack: onBack,
            onOpenGroupInfo: onOpenGroupInfo,
            onToggleProfile: onToggleProfile,
            profileOpen: profileOpen,
            onStartCall: onStartCall,
            onStartRemote: onStartRemote,
            onClearHistory: onClearHistory,
            reportSink: reportSink,
            diagnostics: diagnostics,
          ),
          const Divider(height: 1),
          // 点击消息区任意位置收起键盘、输入框失焦（与微信/QQ 一致）。
          // Listener 的 onPointerDown 不参与手势竞技，气泡点击/长按/滚动照常工作。
          Expanded(
            child: Listener(
              key: const ValueKey<String>('chat-message-area'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              child: ListenableBuilder(
                listenable: store,
                builder: (BuildContext context, Widget? _) {
                  return _MessageList(
                    store: store,
                    isGroup: conversation.isGroup,
                    onDownloadGroupFile: onDownloadGroupFile == null
                        ? null
                        : (ChatMessage message) =>
                              onDownloadGroupFile!(conversation, message),
                    onSaveFile: onSaveFile,
                    onReadFileBytes: onReadFileBytes,
                    mediaSourceUri: mediaSourceUri,
                    onDeleteMessage: onDeleteMessage,
                    onForwardMessage: onForwardMessage,
                    onRequestGroupJoin: onRequestGroupJoin,
                    onRecallMessage: onRecallMessage,
                    onEditMessage: onEditMessage,
                    onLoadOlder: onLoadOlder,
                    highlightMsgUuid: highlightMsgUuid,
                    onForwardMessages: onForwardMessages,
                  );
                },
              ),
            ),
          ),
          ChatInputArea(
            conversation: conversation,
            store: store,
            voiceRecorder: voiceRecorder,
            onVoiceSent: (String name) => onSent?.call(name),
            onSend: (String text, List<String> mentions, int ttlHours) {
              // 不等待通道回执，输入框立即清空；状态由消息行自行刷新。
              // 引用 ID 由 InputArea 在清空前捕获，这里再读一次以带 replyTo（P6-32）。
              unawaited(() async {
                try {
                  await store.send(
                    text,
                    senderName: context.t('我'),
                    replyTo: store.quoting?.id,
                    mentions: mentions,
                    ttlHours: ttlHours,
                  );
                  onSent?.call(text);
                } on Object catch (error) {
                  _showSendFailure(messenger, sendFailureTemplate, error);
                }
              }());
            },
            onTypingChanged: onTypingChanged,
            mentionCandidates: mentionCandidates,
            mentionController: mentionController,
            initialDraft: initialDraft,
            onDraftChanged: onDraftChanged,
            onAttachFile: () => _pickAndSendFile(context),
            onAttachFolder: () => _pickAndSendFolder(context),
            onAttachImage: () => _pickAndSendImage(context),
            onAttachVideo: () => _pickAndSendMedia(context, video: true),
            onAttachAudio: () => _pickAndSendMedia(context, video: false),
            onAttachVoice: () => _pickAndSendVoice(context),
          ),
        ],
      ),
    );
  }
}

/// 兜底的文件选择：输入本机绝对路径（无插件依赖，桌面 / 移动端通用）。
class FileSendDialog extends StatefulWidget {
  const FileSendDialog({super.key, this.title});

  /// 弹窗标题：发送文件 / 发送图片复用同一路径入口。
  final String? title;

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
      title: Text(widget.title ?? context.t('发送文件')),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: context.t('本机文件绝对路径'),
          hintText: 'D:\\docs\\report.pdf',
          isDense: true,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          onPressed: _path.isEmpty ? null : _submit,
          child: Text(context.t('发送')),
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
    this.onAttachFolder,
    this.onAttachImage,
    this.onAttachMedia,
    this.onAttachVideo,
    this.onAttachAudio,
    this.onAttachVoice,
    this.voiceRecorder,
    this.onVoiceSent,
    this.onTypingChanged,
    this.mentionCandidates = const <MentionCandidate>[],
    this.mentionController,
    this.initialDraft = '',
    this.onDraftChanged,
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

  /// 右侧成员面板触发的 @ 插入通道。
  final MentionInsertController? mentionController;

  /// 会话级草稿初值与变化回调。
  final String initialDraft;
  final ValueChanged<String>? onDraftChanged;

  /// 「文件」工具入口；为空时提示功能未开放。
  final VoidCallback? onAttachFile;

  /// 「文件夹」工具入口；为空时工具条不展示。
  final VoidCallback? onAttachFolder;

  /// 「图片」工具入口（P6-16）；为空时提示功能未开放。
  final VoidCallback? onAttachImage;

  /// 「音视频」兼容入口；新 UI 使用下面两个独立入口。
  final VoidCallback? onAttachMedia;

  /// 「视频」工具入口：直接拉起系统视频库。
  final VoidCallback? onAttachVideo;

  /// 「音频」工具入口：直接拉起系统音频库。
  final VoidCallback? onAttachAudio;

  /// 「语音」工具入口（A-01）；为空时提示功能未开放。
  final VoidCallback? onAttachVoice;

  /// 按住说话录音器；为空时输入条不展示长按入口。
  final VoiceRecorder? voiceRecorder;

  /// 录音发送成功后的会话摘要回调。
  final ValueChanged<String>? onVoiceSent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? _) {
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        final String sendFailureTemplate = context.t('发送失败：{0}');
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
                  unawaited(() async {
                    try {
                      await store.send(
                        text,
                        senderName: context.t('我'),
                        replyTo: replyTo,
                        mentions: mentions,
                        ttlHours: ttlHours,
                      );
                    } on Object catch (error) {
                      _showSendFailure(messenger, sendFailureTemplate, error);
                    }
                  }());
                }
                // 引用随本次发送一并清空；无引用时 setQuoting(null) 是无害的空操作。
                store.setQuoting(null);
              },
              onAttachFile: onAttachFile,
              onAttachFolder: onAttachFolder,
              onAttachImage: onAttachImage,
              onAttachMedia: onAttachMedia,
              onAttachVideo: onAttachVideo ?? onAttachMedia,
              onAttachAudio: onAttachAudio ?? onAttachMedia,
              onAttachVoice: onAttachVoice,
              voiceRecorder: voiceRecorder,
              onVoiceSend: (VoiceRecording recording) async {
                try {
                  await store.sendFile(
                    ChatAttachment(
                      name: recording.name,
                      size: recording.size,
                      mime: recording.mime,
                      path: recording.path,
                    ),
                    senderName: context.t('我'),
                  );
                  onVoiceSent?.call(recording.name);
                } on Object catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(context.t('语音发送失败：{0}', [error])),
                    ),
                  );
                }
              },
              onTypingChanged: onTypingChanged,
              mentionCandidates: mentionCandidates,
              mentionController: mentionController,
              initialDraft: initialDraft,
              onDraftChanged: onDraftChanged,
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
              context.t(OfflineStorageNotice.message),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontSize: 12, color: NexmemColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

/// 头部在线状态副标题：有轮询状态源时实时跟随，否则沿用会话快照。
class _PresenceSubtitle extends StatelessWidget {
  const _PresenceSubtitle({
    required this.conversation,
    required this.style,
    this.presence,
  });

  final ConversationItem conversation;
  final TextStyle? style;
  final ValueListenable<Map<String, bool>>? presence;

  @override
  Widget build(BuildContext context) {
    if (conversation.isGroup) {
      return Text(context.t('群聊'), style: style);
    }
    final ValueListenable<Map<String, bool>>? listenable = presence;
    if (listenable == null || conversation.peer.isEmpty) {
      return Text(
        _ChatHeader._presenceLabel(context, conversation.presence),
        style: style,
      );
    }
    return ValueListenableBuilder<Map<String, bool>>(
      valueListenable: listenable,
      builder: (BuildContext context, Map<String, bool> presence, Widget? _) {
        final bool? online = presence[normalizeAccountHex(conversation.peer)];
        final PresenceStatus status = online == null
            ? conversation.presence
            : (online ? PresenceStatus.online : PresenceStatus.offline);
        return Text(_ChatHeader._presenceLabel(context, status), style: style);
      },
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.conversation,
    required this.store,
    this.presence,
    this.displayName,
    this.remark = '',
    this.onSetRemark,
    this.onBack,
    this.onOpenGroupInfo,
    this.onToggleProfile,
    this.profileOpen = false,
    this.onStartCall,
    this.onStartRemote,
    this.onClearHistory,
    this.reportSink = const UnavailableReportSink(),
    this.diagnostics = const UnavailableDiagnosticsService(),
  });

  final ConversationItem conversation;
  final ChatStore store;
  final ValueListenable<Map<String, bool>>? presence;
  final String? displayName;
  final String remark;
  final ValueChanged<String>? onSetRemark;
  final VoidCallback? onBack;
  final VoidCallback? onOpenGroupInfo;
  final VoidCallback? onToggleProfile;
  final bool profileOpen;
  final ValueChanged<bool>? onStartCall;
  final VoidCallback? onStartRemote;
  final Future<void> Function()? onClearHistory;
  final ReportSink reportSink;
  final DiagnosticsService diagnostics;

  Future<void> _openReport(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String submittedText = context.t('举报已提交，感谢反馈');
    final bool? submitted = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => ReportDialog(
        conversationId: conversation.id,
        reportSink: reportSink,
        diagnostics: diagnostics,
      ),
    );
    if (submitted == true) {
      messenger.showSnackBar(SnackBar(content: Text(submittedText)));
    }
  }

  /// 清空聊天记录（P6-13）：先二次确认，内核清空成功后再清空本机列表。
  Future<void> _openClear(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String cleared = context.t('聊天记录已清空');
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('清空聊天记录')),
        content: Text(
          context.t('将删除与「{0}」的本机聊天记录，且无法恢复。', [conversation.title]),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('清空')),
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
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('清空失败：{0}', [error]))),
      );
      return;
    }
    store.clear();
    messenger.showSnackBar(SnackBar(content: Text(cleared)));
  }

  /// 点击标题打开备注编辑；回调交给壳层落库并回填会话标题。
  Future<void> _openRemark(BuildContext context) async {
    final TextEditingController controller = TextEditingController(
      text: remark,
    );
    final String? next = await showAppDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('设置备注')),
        content: TextField(
          key: const ValueKey<String>('chat-header-remark-field'),
          controller: controller,
          autofocus: true,
          maxLines: 1,
          decoration: InputDecoration(
            labelText: context.t('备注'),
            helperText: context.t('仅本机可见，不会发送给对方'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(context.t('保存')),
          ),
        ],
      ),
    );
    if (next == null) {
      return;
    }
    onSetRemark?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? secondary = Theme.of(context).textTheme.bodySmall
        ?.copyWith(
          fontSize: 11,
          color: scheme.onSurface.withValues(alpha: 0.5),
        );
    final String peer = conversation.peer.isNotEmpty
        ? conversation.peer
        : conversation.id;
    final String name = displayName?.trim().isNotEmpty ?? false
        ? displayName!.trim()
        : (conversation.title.trim().isNotEmpty
              ? conversation.title.trim()
              : shortAccountLabel(peer));
    return SizedBox(
      height: 56,
      child: Row(
        children: <Widget>[
          if (onBack != null)
            IconButton(
              tooltip: context.t('返回'),
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              onPressed: onBack,
            ),
          const SizedBox(width: NexmemMetrics.space4),
          Expanded(
            child: InkWell(
              key: const ValueKey<String>('chat-header-identity'),
              onTap: onSetRemark == null ? null : () => _openRemark(context),
              borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NexmemMetrics.space4,
                  vertical: 2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AppAvatar(
                      seed: conversation.id,
                      label: name,
                      icon: conversation.isGroup ? Icons.groups_outlined : null,
                      size: 36,
                      showPresence: !conversation.isGroup,
                      presence: switch (conversation.presence) {
                        PresenceStatus.online => AvatarPresence.online,
                        PresenceStatus.relay => AvatarPresence.relay,
                        PresenceStatus.offline => AvatarPresence.offline,
                      },
                    ),
                    const SizedBox(width: NexmemMetrics.space8),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        _PresenceSubtitle(
                          conversation: conversation,
                          presence: presence,
                          style: secondary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onStartCall != null) ...<Widget>[
            IconButton(
              key: const ValueKey<String>('chat-call-audio'),
              tooltip: context.t('语音通话'),
              icon: const Icon(Icons.call, size: 20),
              onPressed: () => onStartCall!(false),
            ),
            IconButton(
              key: const ValueKey<String>('chat-call-video'),
              tooltip: context.t('视频通话'),
              icon: const Icon(Icons.videocam, size: 20),
              onPressed: () => onStartCall!(true),
            ),
          ],
          if (onStartRemote != null)
            IconButton(
              key: const ValueKey<String>('chat-remote-control'),
              tooltip: context.t('远程控制'),
              icon: const Icon(Icons.desktop_windows_outlined, size: 20),
              onPressed: onStartRemote,
            ),
          if (onToggleProfile != null)
            IconButton(
              key: const ValueKey<String>('chat-profile-toggle'),
              tooltip: context.t(profileOpen ? '收起聊天信息' : '聊天信息'),
              icon: Icon(
                profileOpen ? Icons.info : Icons.info_outline,
                size: 20,
              ),
              onPressed: onToggleProfile,
            ),
          PopupMenuButton<String>(
            tooltip: context.t('更多'),
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
                PopupMenuItem<String>(
                  value: 'groupInfo',
                  child: Text(context.t('群设置')),
                ),
              PopupMenuItem<String>(
                value: 'clear',
                child: Text(context.t('清空聊天记录')),
              ),
              PopupMenuItem<String>(
                value: 'report',
                child: Text(context.t('举报')),
              ),
            ],
          ),
          const SizedBox(width: NexmemMetrics.space4),
        ],
      ),
    );
  }

  static String _presenceLabel(BuildContext context, PresenceStatus status) {
    return switch (status) {
      PresenceStatus.online => context.t('在线'),
      PresenceStatus.relay => context.t('经中继'),
      PresenceStatus.offline => context.t('离线'),
    };
  }
}

/// 消息区：倒序 `ListView.builder` 保证始终贴底且只构建可视范围。
class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.store,
    required this.isGroup,
    this.onDownloadGroupFile,
    this.onSaveFile,
    this.onReadFileBytes,
    this.mediaSourceUri,
    this.onDeleteMessage,
    this.onForwardMessage,
    this.onRequestGroupJoin,
    this.onRecallMessage,
    this.onEditMessage,
    this.onLoadOlder,
    this.highlightMsgUuid,
    this.onForwardMessages,
  });

  /// 批量转发选中消息到目标会话；返回是否成功。
  final Future<bool> Function(List<ChatMessage> messages)? onForwardMessages;

  final ChatStore store;
  final bool isGroup;
  final Future<String?> Function(ChatMessage message)? onDownloadGroupFile;
  final Future<String?> Function(ChatMessage message)? onSaveFile;
  final Future<Uint8List> Function(ChatMessage message)? onReadFileBytes;
  final Uri? Function(String path)? mediaSourceUri;
  final Future<void> Function(String msgUuid)? onDeleteMessage;
  final Future<bool> Function(ChatMessage message)? onForwardMessage;
  final Future<void> Function(GroupShareInfo info)? onRequestGroupJoin;
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

  /// 多选模式：选中消息 ID 集合。退出时清空。
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  /// 进入多选并勾选首条（长按「多选」入口触发）。
  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(id);
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(widget.store.messages.map((ChatMessage m) => m.id));
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  /// 批量复制：按消息原始顺序拼接选中消息的可复制文本。
  Future<void> _copySelected(BuildContext context) async {
    final List<ChatMessage> selected = widget.store.messages
        .where((ChatMessage m) => _selectedIds.contains(m.id))
        .toList();
    if (selected.isEmpty) {
      return;
    }
    final String text = selected
        .map((ChatMessage m) {
          if (!m.isFile) {
            return m.text;
          }
          final String name = m.attachment?.name.trim() ?? '';
          return name.isNotEmpty ? name : m.text;
        })
        .join('\n');
    final String copied = context.t('已复制 {0} 条', <String>['${selected.length}']);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _exitSelection();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(copied)));
      }
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t('复制失败'))),
        );
      }
    }
  }

  /// 批量转发：一次性把选中消息交给壳层选择目标会话。
  Future<void> _forwardSelected(BuildContext context) async {
    final List<ChatMessage> selected = widget.store.messages
        .where((ChatMessage m) => _selectedIds.contains(m.id))
        .toList();
    final Future<bool> Function(List<ChatMessage>)? forward =
        widget.onForwardMessages;
    if (selected.isEmpty || forward == null) {
      return;
    }
    try {
      final bool ok = await forward(selected);
      if (ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t('已转发 {0} 条', <String>['${selected.length}'])),
          ),
        );
      }
      _exitSelection();
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t('转发失败：{0}', <String>['$error']))),
        );
      }
    }
  }

  /// 多选操作栏：全选 / 复制 / 转发 / 取消。
  Widget _selectionBar(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int count = _selectedIds.length;
    final bool hasForward = widget.onForwardMessages != null;
    return Container(
      color: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('chat-selection-cancel'),
            icon: const Icon(Icons.close),
            color: scheme.onPrimaryContainer,
            onPressed: _exitSelection,
          ),
          Expanded(
            child: Text(
              '${context.t('多选')} · $count',
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey<String>('chat-selection-select-all'),
            onPressed: _selectAll,
            child: Text(
              context.t('全选'),
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('chat-selection-copy'),
            tooltip: context.t('复制'),
            icon: const Icon(Icons.copy),
            color: scheme.onPrimaryContainer,
            onPressed: count == 0
                ? null
                : () => unawaited(_copySelected(context)),
          ),
          if (hasForward)
            IconButton(
              key: const ValueKey<String>('chat-selection-forward'),
              tooltip: context.t('转发'),
              icon: const Icon(Icons.forward),
              color: scheme.onPrimaryContainer,
              onPressed: count == 0
                  ? null
                  : () => unawaited(_forwardSelected(context)),
            ),
        ],
      ),
    );
  }

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
      added = index < 0
          ? messages.length - _count
          : messages.length - index - 1;
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
    try {
      if (call != null) {
        await call(message.id, newText);
      }
      widget.store.updateEdited(
        message.id,
        newText,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t('编辑失败：{0}', <String>['$e']))),
      );
    }
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
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String sendFailureTemplate = context.t('发送失败：{0}');
    final List<ChatMessage> messages = widget.store.messages;
    if (messages.isEmpty) {
      return EmptyState(
        icon: Icons.chat_outlined,
        message: context.t('还没有消息，发送第一条打个招呼'),
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
              onDownloadGroupFile: widget.onDownloadGroupFile,
              onSaveFile: widget.onSaveFile,
              onReadFileBytes: widget.onReadFileBytes,
              mediaSourceUri: widget.mediaSourceUri,
              onRetry: () => unawaited(
                widget.store
                    .retry(message.id)
                    .catchError(
                      (Object error) => _showSendFailure(
                        messenger,
                        sendFailureTemplate,
                        error,
                      ),
                    ),
              ),
              onDelete: () => _deleteMessage(message),
              onForward: widget.onForwardMessage == null
                  ? null
                  : () => widget.onForwardMessage!(message),
              onRequestGroupJoin: widget.onRequestGroupJoin,
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
              selectionMode: _selectionMode,
              selected: _selectedIds.contains(message.id),
              onToggleSelection: _toggleSelection,
              onEnterSelection: _enterSelection,
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
        if (_selectionMode)
          Positioned(
            key: const ValueKey<String>('chat-selection-bar'),
            left: 0,
            right: 0,
            top: 0,
            child: _selectionBar(context),
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('···', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 6),
                      Text(
                        context.t('对方正在输入…'),
                        style: const TextStyle(fontSize: 12),
                      ),
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
                context.t('{0} 条新消息', [count]),
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
/// 把文本里的 `@xxx`（直到空白）渲染为高亮片段（七-1），
/// 并把 http(s) 网址渲染为可点击链接，点击后在内置浏览器打开。
/// @ 的真实身份仍存于 [ChatMessage.mentions]，这里只做视觉提示。

class _MessageTextMark {
  const _MessageTextMark({
    required this.start,
    required this.end,
    this.link,
  });

  final int start;
  final int end;
  final WebUrlMatch? link;
}

TextSpan _buildMessageTextSpan(
  String text, {
  required Color baseColor,
  required Color highlightColor,
  required ValueChanged<String>? onOpenLink,
  required List<TapGestureRecognizer> recognizers,
}) {
  final List<_MessageTextMark> marks = <_MessageTextMark>[
    for (final WebUrlMatch link in extractWebUrls(text))
      _MessageTextMark(start: link.start, end: link.end, link: link),
    for (final Match match in RegExp(r'@[^\s]+').allMatches(text))
      _MessageTextMark(start: match.start, end: match.end),
  ]..sort((_MessageTextMark a, _MessageTextMark b) {
    if (a.start != b.start) {
      return a.start.compareTo(b.start);
    }
    return b.end.compareTo(a.end);
  });

  final List<InlineSpan> spans = <InlineSpan>[];
  int cursor = 0;
  for (final _MessageTextMark mark in marks) {
    if (mark.start < cursor) {
      continue;
    }
    if (mark.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, mark.start)));
    }
    final String piece = text.substring(mark.start, mark.end);
    final WebUrlMatch? link = mark.link;
    if (link == null) {
      spans.add(
        TextSpan(
          text: piece,
          style: TextStyle(color: highlightColor, fontWeight: FontWeight.w600),
        ),
      );
    } else {
      final TapGestureRecognizer recognizer = TapGestureRecognizer()
        ..onTap = () => onOpenLink?.call(link.url);
      recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: piece,
          style: TextStyle(
            color: highlightColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
      );
    }
    cursor = mark.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(
    style: TextStyle(fontSize: 15, height: 1.35, color: baseColor),
    children: spans,
  );
}

/// 持有链接 recognizer，避免每次 build 都创建新的手势对象而无法释放。
class _LinkifiedMessageText extends StatefulWidget {
  const _LinkifiedMessageText({
    required this.text,
    required this.baseColor,
    required this.highlightColor,
    this.onOpenLink,
  });

  final String text;
  final Color baseColor;
  final Color highlightColor;
  final ValueChanged<String>? onOpenLink;

  @override
  State<_LinkifiedMessageText> createState() => _LinkifiedMessageTextState();
}

class _LinkifiedMessageTextState extends State<_LinkifiedMessageText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];
  late final TextSpan _span;

  @override
  void initState() {
    super.initState();
    _span = _makeSpan();
  }

  @override
  void didUpdateWidget(covariant _LinkifiedMessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.onOpenLink != widget.onOpenLink) {
      _disposeRecognizers();
      _span = _makeSpan();
    }
  }

  TextSpan _makeSpan() => _buildMessageTextSpan(
    widget.text,
    baseColor: widget.baseColor,
    highlightColor: widget.highlightColor,
    onOpenLink: widget.onOpenLink,
    recognizers: _recognizers,
  );

  void _disposeRecognizers() {
    for (final TapGestureRecognizer recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RichText(
    key: const ValueKey<String>('message-link-text'),
    text: _span,
  );
}

Widget _highlightMentions(
  String text, {
  required bool mine,
  required Color baseColor,
  required Color highlightColor,
  ValueChanged<String>? onOpenLink,
}) {
  // 无 @、无网址时保持普通 Text（find.text 可命中，且渲染更轻）。
  if (!text.contains('@') && extractWebUrls(text).isEmpty) {
    return Text(
      text,
      style: TextStyle(fontSize: 15, height: 1.35, color: baseColor),
    );
  }
  return _LinkifiedMessageText(
    text: text,
    baseColor: baseColor,
    highlightColor: highlightColor,
    onOpenLink: onOpenLink,
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.showSenderName = false,
    this.highlighted = false,
    this.onDownloadGroupFile,
    this.onPreviewMedia,
    this.onSaveFile,
    this.onReadFileBytes,
    this.mediaSourceUri,
    this.onRetry,
    this.onDelete,
    this.onForward,
    this.onRequestGroupJoin,
    this.onRecall,
    this.onEdit,
    this.onQuote,
    this.quoted,
    this.voicePlayerFactory,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelection,
    this.onEnterSelection,
  });

  final ChatMessage message;
  final bool showSenderName;

  /// 多选模式：点击气泡切换勾选，长按/右键不再弹单条菜单。
  final bool selectionMode;
  final bool selected;
  final ValueChanged<String>? onToggleSelection;

  /// 长按菜单「多选」入口：进入多选并勾选本条。
  final ValueChanged<String>? onEnterSelection;

  /// 搜索命中定位时的高亮底色（P6-07）。
  final bool highlighted;

  /// 下载群文件回调（A-02）；仅群文件气泡且内核会话可用时传入。
  final Future<String?> Function(ChatMessage message)? onDownloadGroupFile;

  /// 覆盖媒体气泡的预览行为；为空时使用内置的 MediaViewerDialog。
  /// 便于测试注入替身，无需真正启动视频/音频播放器。
  final Future<void> Function(ChatMessage message)? onPreviewMedia;

  /// 保存附件到本机 / 读取附件字节，供通用文件查看页使用。
  final Future<String?> Function(ChatMessage message)? onSaveFile;
  final Future<Uint8List> Function(ChatMessage message)? onReadFileBytes;

  /// Web 在线播放源；为空时媒体/图片气泡沿用本地文件或下载降级。
  final Uri? Function(String path)? mediaSourceUri;

  final VoidCallback? onRetry;

  /// 本地删除本条消息（P6-11 长按 / 右键菜单）。
  final Future<void> Function()? onDelete;

  /// 转发本条文本消息（P6-12）；为空时不展示入口。
  final Future<bool> Function()? onForward;

  /// 本条消息是群分享信息时，可直接申请入群；为空时不展示入口。
  final Future<void> Function(GroupShareInfo info)? onRequestGroupJoin;

  /// 撤回本条消息（P6-12，仅自己 2 分钟内，单聊与群聊均可用）；为空时不展示入口。
  final Future<void> Function()? onRecall;

  /// 编辑本条消息正文（七-2，仅自己发出的文本消息）；为空时不展示入口。
  final Future<void> Function(String msgUuid, String newText)? onEdit;

  /// 引用本条消息（P6-32，仅单聊）；为空时不展示入口。
  final VoidCallback? onQuote;

  /// 本条消息引用的原消息（用于气泡内引用条展示）；找不到原消息时为 null。
  final ChatMessage? quoted;

  /// 语音气泡播放器工厂；为空时使用 audioplayers 生产实现。
  final VoiceMessagePlayerFactory? voicePlayerFactory;

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

  bool get _isImageMessage =>
      message.isFile &&
      (message.attachment?.mime.toLowerCase().startsWith('image/') ?? false);

  String? get _linkUrl =>
      message.isFile ? null : extractFirstWebUrl(message.text);

  /// 图片消息长按 / 右键识别二维码。
  Future<void> _recognizeQr(BuildContext context) async {
    final ChatAttachment? attachment = message.attachment;
    if (attachment == null) {
      return;
    }
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    if (!qrImageDecodeSupported) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(context.t('当前平台不支持图片二维码识别，请用摄像头扫码')),
        ),
      );
      return;
    }
    messenger?.showSnackBar(
      SnackBar(content: Text(context.t('正在识别二维码…'))),
    );
    final String? raw = await decodeQrFromImage(
      path: attachment.path,
      sourceUri: mediaSourceUri?.call(attachment.path)?.toString(),
    );
    if (!context.mounted) {
      return;
    }
    if (raw == null || raw.isEmpty) {
      messenger?.showSnackBar(
        SnackBar(content: Text(context.t('未识别到二维码'))),
      );
      return;
    }
    await handleQrResult(context, raw);
  }

  /// 长按（移动端）与右键（桌面端）弹出消息操作菜单。
  Future<void> _showActions(BuildContext context, Offset globalPosition) async {
    final String copyLabel = context.t('复制');
    final String forwardLabel = context.t('转发');
    final String quoteLabel = context.t('引用');
    final String editLabel = context.t('编辑');
    final String recallLabel = context.t('撤回');
    final String deleteLabel = context.t('删除');
    final String selectLabel = context.t('多选');
    final String recognizeLabel = context.t('识别图中二维码');
    final String openLinkLabel = context.t('打开链接');
    final String joinGroupLabel = context.t('申请入群');
    final GroupShareInfo? groupShare =
        parseGroupShareText(message.text);
    final String copied = context.t('已复制');
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        if (onEnterSelection != null)
          PopupMenuItem<String>(value: 'select', child: Text(selectLabel)),
        if (_linkUrl != null)
          PopupMenuItem<String>(
            value: 'open-link',
            child: Text(openLinkLabel),
          ),
        if (groupShare != null && onRequestGroupJoin != null)
          PopupMenuItem<String>(
            value: 'request-group-join',
            child: Text(joinGroupLabel),
          ),
        if (_isImageMessage)
          PopupMenuItem<String>(
            value: 'recognize-qr',
            child: Text(recognizeLabel),
          ),
        if (!message.isFile)
          PopupMenuItem<String>(value: 'copy', child: Text(copyLabel)),
        if (!message.isFile && onForward != null)
          PopupMenuItem<String>(value: 'forward', child: Text(forwardLabel)),
        if (!message.isFile && onQuote != null)
          PopupMenuItem<String>(value: 'quote', child: Text(quoteLabel)),
        if (_canEdit)
          PopupMenuItem<String>(value: 'edit', child: Text(editLabel)),
        if (_canRecall)
          PopupMenuItem<String>(value: 'recall', child: Text(recallLabel)),
        PopupMenuItem<String>(value: 'delete', child: Text(deleteLabel)),
      ],
    );
    if (action == null || !context.mounted) {
      return;
    }
    if (action == 'select') {
      onEnterSelection?.call(message.id);
      return;
    }
    if (action == 'open-link') {
      final String? url = _linkUrl;
      if (url != null) {
        await openInAppBrowser(context, url);
      }
      return;
    }
    if (action == 'request-group-join') {
      final GroupShareInfo? info = groupShare;
      if (info != null) {
        await onRequestGroupJoin?.call(info);
      }
      return;
    }
    if (action == 'recognize-qr') {
      await _recognizeQr(context);
      return;
    }
    if (action == 'copy') {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      await Clipboard.setData(ClipboardData(text: message.text));
      messenger.showSnackBar(SnackBar(content: Text(copied)));
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
    final TextEditingController controller = TextEditingController(
      text: message.text,
    );
    final String? revised = await showAppDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('编辑消息')),
        content: TextField(
          key: const ValueKey<String>('edit-message-field'),
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: kMaxMessageChars,
          buildCounter: _messageCounter,
          decoration: InputDecoration(hintText: context.t('输入新正文')),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t('取消')),
          ),
          TextButton(
            onPressed: () {
              final String text = controller.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(context).pop(text);
              }
            },
            child: Text(context.t('保存')),
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
    final String forwardedText = context.t('已转发');
    try {
      final bool forwarded = await onForward?.call() ?? false;
      if (forwarded) {
        messenger.showSnackBar(SnackBar(content: Text(forwardedText)));
      }
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('转发失败：{0}', [error]))),
      );
    }
  }

  Future<void> _confirmRecall(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String recalled = context.t('已撤回');
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('撤回消息')),
        content: Text(
          message.isGroup
              ? context.t('撤回后群内其他成员也将看不到这条消息。')
              : context.t('撤回后对方也将看不到这条消息。'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('撤回')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await onRecall?.call();
      messenger.showSnackBar(SnackBar(content: Text(recalled)));
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('撤回失败：{0}', [error]))),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String deleted = context.t('已删除');
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('删除消息')),
        content: Text(context.t('仅从本机删除，对方仍可看到这条消息。')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await onDelete?.call();
      messenger.showSnackBar(SnackBar(content: Text(deleted)));
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t('删除失败：{0}', [error]))),
      );
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
          if (selectionMode) ...<Widget>[
            _SelectionCheck(selected: selected),
            const SizedBox(width: NexmemMetrics.space8),
          ],
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
                  onLongPressStart: selectionMode
                      ? null
                      : (LongPressStartDetails details) =>
                          _showActions(context, details.globalPosition),
                  onSecondaryTapDown: selectionMode
                      ? null
                      : (TapDownDetails details) =>
                          _showActions(context, details.globalPosition),
                  onTap: selectionMode && onToggleSelection != null
                      ? () => onToggleSelection!(message.id)
                      : null,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: ShapeDecoration(
                      color: selectionMode && selected
                          ? NexmemColors.primary.withValues(alpha: 0.22)
                          : mine
                              ? NexmemColors.bubbleSelf
                              : scheme.surface,
                      shape: _BubbleShape(
                        mine: mine,
                        borderColor: selectionMode && selected
                            ? NexmemColors.primary
                            : mine
                                ? null
                                : scheme.onSurface.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (message.replyTo.isNotEmpty)
                          _QuotedStrip(
                            label: quoted == null
                                ? context.t('原消息')
                                : (quoted!.isMine
                                      ? context.t('我')
                                      : quoted!.senderName),
                            text: quoted?.text ?? context.t('原消息已不可用'),
                            mine: mine,
                          ),
                        if (message.isFile)
                          _FileBubbleContent(
                            message: message,
                            mine: mine,
                            isGroup: message.isGroup,
                            onDownload: onDownloadGroupFile,
                            onPreview: onPreviewMedia,
                            onSave: onSaveFile,
                            onReadBytes: onReadFileBytes,
                            mediaSourceUri: mediaSourceUri,
                            voicePlayerFactory: voicePlayerFactory,
                          )
                        else
                          _highlightMentions(
                            message.text,
                            mine: mine,
                            baseColor: mine ? Colors.white : scheme.onSurface,
                            highlightColor: mine
                                ? Colors.white
                                : NexmemColors.primary,
                            // 多选态下让点击继续走气泡勾选，不打开链接。
                            onOpenLink: selectionMode
                                ? null
                                : (String url) =>
                                    unawaited(openInAppBrowser(context, url)),
                          ),
                        if (message.edited)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              context.t('已编辑'),
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

/// 多选模式下的勾选圈：选中时填充主题色并显示对勾。
class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Container(
        key: ValueKey<String>(
          selected ? 'chat-selection-checked' : 'chat-selection-unchecked',
        ),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? NexmemColors.primary : Colors.transparent,
          border: Border.all(
            color: selected
                ? NexmemColors.primary
                : scheme.onSurface.withValues(alpha: 0.4),
            width: 2,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 15, color: Colors.white)
            : null,
      ),
    );
  }
}

/// 文件气泡内容（P2-04）：图标 + 文件名 + 大小 / 传输进度。
///
/// 图片可点开缩放预览；语音/视频点开用 MediaViewerDialog 播放；
/// 其余文件点击复制本机路径，便于定位落盘位置。
class _FileBubbleContent extends StatelessWidget {
  const _FileBubbleContent({
    required this.message,
    required this.mine,
    required this.isGroup,
    this.onDownload,
    this.onPreview,
    this.onSave,
    this.onReadBytes,
    this.mediaSourceUri,
    this.voicePlayerFactory,
  });

  final ChatMessage message;
  final bool mine;
  final bool isGroup;
  final Future<String?> Function(ChatMessage)? onDownload;
  final Future<void> Function(ChatMessage)? onPreview;
  final Future<String?> Function(ChatMessage)? onSave;
  final Future<Uint8List> Function(ChatMessage)? onReadBytes;
  final Uri? Function(String path)? mediaSourceUri;
  final VoiceMessagePlayerFactory? voicePlayerFactory;

  /// 两端都可能有真实传输进度（接收端消息状态是 sent，不能只看 sending）。
  /// 发送完成（status 不再是 sending）后即使进度未刷新也不再显示进度条。
  bool get _hasTransfer =>
      message.transferTotal > 0 && message.transferDone < message.transferTotal;

  bool get _showProgress =>
      message.status == MessageStatus.sending ||
      (!message.isMine && _hasTransfer);

  /// 有进度数据时显示确定进度；发送中但首条进度未到时显示不确定进度。
  double? get _progressRatio => _hasTransfer ? message.transferRatio : null;

  /// 打开媒体预览：桌面/移动端直接播本地文件；Web 端有鉴权播放源时在线
  /// 流式播放，没有时才退化为下载后用本地播放器打开，并给出明确提示。
  Future<void> _preview(BuildContext context, ChatAttachment file) async {
    final Future<void> Function(ChatMessage)? injected = onPreview;
    if (injected != null) {
      await injected(message);
      return;
    }
    final Uri? source = mediaSourceUri == null || file.path.isEmpty
        ? null
        : mediaSourceUri!(file.path);
    if (source != null) {
      await showAppDialog<void>(
        context: context,
        builder: (BuildContext _) => MediaViewerDialog(
          path: file.path,
          mime: file.mime,
          title: file.name,
          sourceUri: source,
        ),
      );
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // 文案在 await 之前取好，避免跨异步间隔使用 BuildContext。
    final String downloadedHint = context.t('已下载 {0}，请用本地播放器打开', [file.name]);
    final String downloadHint = context.t('请下载后使用本地播放器打开');
    if (kIsWeb || file.path.isEmpty) {
      if (onDownload != null) {
        final String? saved = await onDownload!.call(message);
        if (!context.mounted || saved == null || saved.isEmpty) {
          return;
        }
        messenger.showSnackBar(SnackBar(content: Text(downloadedHint)));
      } else {
        // 私聊文件在 Web 端没有下载回调；复制落盘路径并明确说明限制，
        // 避免用户点了却没有任何反馈。
        await Clipboard.setData(ClipboardData(text: file.path));
        messenger.showSnackBar(SnackBar(content: Text(downloadHint)));
      }
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext _) =>
          MediaViewerDialog(path: file.path, mime: file.mime, title: file.name),
    );
  }

  /// 打开通用文件查看页：文本 / 压缩包内联预览，其他格式展示元信息并提供保存。
  Future<void> _openViewer(BuildContext context, ChatAttachment file) async {
    final Future<Uint8List> Function(ChatMessage)? reader = onReadBytes;
    final Future<String?> Function(ChatMessage)? saver = onSave;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext routeContext) => ChatFileViewer(
          name: file.name,
          mime: file.mime,
          size: file.size,
          readBytes: () => reader != null
              ? reader(message)
              : Future<Uint8List>.value(Uint8List(0)),
          onSave: () =>
              saver != null ? saver(message) : Future<String?>.value(null),
        ),
      ),
    );
  }

  /// 保存媒体附件到本机（与查看页共用同一回调）。
  Future<void> _save(BuildContext context) async {
    final Future<String?> Function(ChatMessage)? saver = onSave;
    if (saver == null) return;
    final l10n = context.l10n;
    final String? saved = await saver(message);
    if (!context.mounted || saved == null || saved.isEmpty) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.t('已保存到：{0}', [saved]))));
  }

  IconData _icon(String name, String mime) {
    final String lowerName = name.toLowerCase();
    if (mime.startsWith('image/') ||
        RegExp(r'\.(png|jpe?g|jfif|gif|webp|bmp|heic|heif|tiff?|avif|ico)$')
            .hasMatch(lowerName)) {
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

  /// 语音/视频气泡：语音内联播放（微信/QQ 风格），视频仍打开播放器弹窗。
  Widget _mediaContent(
    BuildContext context,
    ChatAttachment file,
    MediaKind kind,
  ) {
    if (kind == MediaKind.audio) {
      final Color fg = mine
          ? Colors.white
          : Theme.of(context).colorScheme.onSurface;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          VoiceMessageBubble(
            id: message.id,
            name: file.name,
            path: file.path,
            mine: mine,
            sourceUri: mediaSourceUri == null || file.path.isEmpty
                ? null
                : mediaSourceUri!(file.path),
            playerFactory: voicePlayerFactory,
            onSave: onSave == null
                ? null
                : () => unawaited(_save(context)),
          ),
          if (_showProgress)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                key: ValueKey<String>('chat-file-progress-${message.id}'),
                value: _progressRatio,
                minHeight: 3,
                backgroundColor: fg.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(fg),
              ),
            ),
        ],
      );
    }
    final Color fg = mine
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final Color muted = fg.withValues(alpha: 0.75);
    final double side = math.min(180, MediaQuery.sizeOf(context).width * 0.5);
    final bool showProgress = _showProgress;
    final double? ratio = _progressRatio;
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (kind == MediaKind.video)
          VideoThumbnail(
            path: file.path,
            sourceUri: mediaSourceUri == null || file.path.isEmpty
                ? null
                : mediaSourceUri!(file.path),
            width: side,
            height: side,
            color: fg,
          )
        else
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Icon(
                Icons.audiotrack_outlined,
                size: 48,
                color: fg,
              ),
            ),
          ),
        const SizedBox(height: 4),
        SizedBox(
          width: side,
          child: Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: muted),
          ),
        ),
        if (showProgress)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SizedBox(
              width: side,
              child: LinearProgressIndicator(
                key: ValueKey<String>('chat-file-progress-${message.id}'),
                value: ratio,
                minHeight: 3,
                backgroundColor: fg.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(fg),
              ),
            ),
          ),
      ],
    );
    return Stack(
      alignment: Alignment.topRight,
      children: <Widget>[
        InkWell(
          key: ValueKey<String>('chat-media-preview-${message.id}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => unawaited(_preview(context, file)),
          child: content,
        ),
        if (onSave != null)
          IconButton(
            key: ValueKey<String>('chat-file-save-${message.id}'),
            icon: const Icon(Icons.save_alt_outlined, size: 18),
            tooltip: context.t('保存到本机'),
            color: fg,
            onPressed: () => unawaited(_save(context)),
          ),
      ],
    );
  }

  /// 图片气泡（P6-16）：缩略图 + 发送进度覆盖层 + 文件名/大小说明。
  Widget _imageContent(BuildContext context, ChatAttachment file) {
    final bool transferring = _showProgress;
    final double? ratio = _progressRatio;
    final double side = math.min(180, MediaQuery.sizeOf(context).width * 0.5);
    final Widget thumb = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LocalImage(
        key: ValueKey<String>('chat-image-${message.id}'),
        path: file.path,
        width: side,
        height: side,
        fit: BoxFit.cover,
        sourceUri: mediaSourceUri == null || file.path.isEmpty
            ? null
            : mediaSourceUri!(file.path),
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
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        key: ValueKey<String>(
                          'chat-file-progress-${message.id}',
                        ),
                        value: ratio,
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      ratio == null
                          ? context.t(
                              message.status == MessageStatus.sending
                                  ? '发送中'
                                  : '接收中',
                            )
                          : '${(ratio * 100).round()}%',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
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

  Future<void> _download(BuildContext context) async {
    final String? saved = await onDownload?.call(message);
    if (!context.mounted || saved == null || saved.isEmpty) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.t('群文件已保存到：{0}', [saved]))));
  }

  @override
  Widget build(BuildContext context) {
    final ChatAttachment file = message.attachment!;
    final Widget body = _buildBody(context, file);
    final bool canDownload =
        isGroup && file.canDownloadGroupFile && onDownload != null;
    if (!canDownload) {
      return body;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        body,
        const SizedBox(height: 6),
        SizedBox(
          height: 32,
          child: OutlinedButton.icon(
            key: ValueKey<String>('group-file-download-${message.id}'),
            onPressed: () => _download(context),
            icon: const Icon(Icons.download_outlined, size: 16),
            label: Text(
              context.t('下载群文件'),
              style: const TextStyle(fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, ChatAttachment file) {
    if (file.isImage && file.path.isNotEmpty) {
      return Stack(
        alignment: Alignment.topRight,
        children: <Widget>[
          InkWell(
            key: ValueKey<String>('chat-image-preview-${message.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => unawaited(_preview(context, file)),
            child: _imageContent(context, file),
          ),
          if (onSave != null)
            IconButton(
              key: ValueKey<String>('chat-file-save-${message.id}'),
              icon: const Icon(Icons.save_alt_outlined, size: 18),
              tooltip: context.t('保存到本机'),
              color: mine ? Colors.white : null,
              onPressed: () => unawaited(_save(context)),
            ),
        ],
      );
    }
    final MediaKind kind = mediaKindOf(file.path, mime: file.mime);
    // 接收端在文件落盘前 path 为空：此时先按普通文件气泡展示，
    // 等 transfer.progress(done==total) 补全路径后再切换成可预览媒体气泡。
    // 否则点击会打开一个 path 为空的播放器，看起来就是「点了没反应」。
    final bool playable =
        file.path.isNotEmpty &&
        (kind == MediaKind.audio || kind == MediaKind.video);
    if (playable) {
      return _mediaContent(context, file, kind);
    }
    final Color fg = mine
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final Color muted = fg.withValues(alpha: 0.75);
    // 发送与接收都可能有进度：接收端消息状态是 sent，不能只看 sending。
    final bool showProgress = _showProgress;
    final double? ratio = _progressRatio;
    final String sizeText = file.size > 0
        ? formatFileSize(file.size)
        : context.t('大小未知');
    final String detail = ratio != null
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
        if (showProgress)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
              key: ValueKey<String>('chat-file-progress-${message.id}'),
              value: ratio,
              minHeight: 3,
              backgroundColor: fg.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(fg),
            ),
          ),
      ],
    );
    if (file.path.isEmpty) {
      return content;
    }
    // 注入了通用查看 / 保存通道时，普通文件点击打开查看页；离线模式仍
    // 保留原来的复制路径行为，避免没有内核时误报「读取失败」。
    if (onSave != null || onReadBytes != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Tooltip(
            message: file.path,
            child: InkWell(
              key: ValueKey<String>('chat-file-viewer-${message.id}'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => unawaited(_openViewer(context, file)),
              child: content,
            ),
          ),
          if (onSave != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: ValueKey<String>('chat-file-save-${message.id}'),
                icon: Icon(Icons.save_alt_outlined, size: 18, color: fg),
                tooltip: context.t('保存到本机'),
                onPressed: () => unawaited(_save(context)),
              ),
            ),
        ],
      );
    }
    return Tooltip(
      message: file.path,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
            context,
          );
          final String copiedPath = context.t('已复制文件路径');
          await Clipboard.setData(ClipboardData(text: file.path));
          messenger.showSnackBar(SnackBar(content: Text(copiedPath)));
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
    final String label = formatExpiryRemaining(expiresAt, l10n: context.l10n);
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
    return AppAvatar(
      seed: message.senderId.isEmpty
          ? message.conversationId
          : message.senderId,
      label: message.senderName,
      size: 36,
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
      MessageStatus.sending => Tooltip(
        message: context.t('发送中'),
        child: SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      ),
      MessageStatus.sent => Tooltip(
        message: context.t('已发送'),
        child: Icon(Icons.check, size: 14, color: muted),
      ),
      MessageStatus.delivered => Tooltip(
        message: context.t('已送达'),
        child: Icon(Icons.done_all, size: 14, color: muted),
      ),
      MessageStatus.read => Tooltip(
        message: context.t('已读'),
        child: Icon(Icons.done_all, size: 14, color: NexmemColors.primary),
      ),
      MessageStatus.failed => Tooltip(
        message: context.t('发送失败，点击重发'),
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
    this.onAttachFolder,
    this.onAttachImage,
    this.onAttachMedia,
    this.onAttachVideo,
    this.onAttachAudio,
    this.onAttachVoice,
    this.voiceRecorder,
    this.onVoiceSend,
    this.onTypingChanged,
    this.mentionCandidates = const <MentionCandidate>[],
    this.mentionController,
    this.initialDraft = '',
    this.onDraftChanged,
  });

  /// 发送回调：[mentions] 为本次文本中 @ 到的成员账号 ID（七-1），
  /// [ttlHours] 为本次定时消息的存活小时数（0 表示普通消息，七-4）。
  final void Function(String text, List<String> mentions, int ttlHours) onSend;

  /// 输入状态变化回调（七-3）；仅单聊传入，节流后上报内核。
  final ValueChanged<bool>? onTypingChanged;

  /// 群聊可 @ 的成员候选（七-1）；为空时不展示 @ 入口。
  final List<MentionCandidate> mentionCandidates;

  /// 右侧成员面板点成员时触发插入；本组件只消费一次候选。
  final MentionInsertController? mentionController;

  /// 「文件」工具入口（P2-04）；为空时提示功能未开放。
  final VoidCallback? onAttachFile;

  /// 「文件夹」工具入口；为空时工具条不展示。
  final VoidCallback? onAttachFolder;

  /// 「图片」工具入口（P6-16）；为空时提示功能未开放。
  final VoidCallback? onAttachImage;

  /// 「音视频」兼容入口；为空时提示功能未开放。
  final VoidCallback? onAttachMedia;

  /// 「视频」入口：拉起系统视频库。
  final VoidCallback? onAttachVideo;

  /// 「音频」入口：拉起系统音频库。
  final VoidCallback? onAttachAudio;

  /// 「语音」工具入口（A-01）；为空时提示功能未开放。
  final VoidCallback? onAttachVoice;

  /// 按住说话录音器与发送回调。
  final VoiceRecorder? voiceRecorder;
  final Future<void> Function(VoiceRecording recording)? onVoiceSend;

  /// 会话级草稿初值与变化回调。
  final String initialDraft;
  final ValueChanged<String>? onDraftChanged;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  /// 表情面板候选（P6-18）：只做字符插入，不引入图片素材或第三方插件。
  static const List<String> _emojis = <String>[
    '😀',
    '😁',
    '😂',
    '🤣',
    '😊',
    '😍',
    '🤔',
    '😎',
    '😭',
    '😅',
    '😘',
    '😡',
    '😴',
    '😇',
    '🥳',
    '🤝',
    '👍',
    '👎',
    '👏',
    '🙏',
    '💪',
    '🎉',
    '🔥',
    '❤️',
    '💔',
    '✨',
    '🌹',
    '🍀',
    '☀️',
    '🌙',
    '⭐',
    '🎁',
    '☕',
    '🍺',
    '🚀',
    '✅',
    '❌',
    '📌',
    '💡',
    '👀',
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

  /// 输入模式：语音态时长按输入框录音、松开发送；文字态正常输入。
  bool _voiceMode = false;

  /// 按住说话：录音中状态、上滑取消与最长 60 秒自动发送。
  bool _recording = false;
  bool _recordCancelled = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  /// 录音启动可能等待权限弹窗；松手时必须等待同一次启动完成再判定，
  /// 否则「按下即松」会在权限通过后留下无人停止的录音。
  Future<bool>? _recordStartFuture;
  int _recordStartSerial = 0;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialDraft;
    _controller.addListener(_onChanged);
    widget.mentionController?.addListener(_onMentionRequested);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    widget.mentionController?.removeListener(_onMentionRequested);
    _typingTimer?.cancel();
    _recordTimer?.cancel();
    final VoiceRecorder? recorder = widget.voiceRecorder;
    if (recorder != null && recorder.isRecording) {
      unawaited(recorder.cancel());
    }
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 右侧成员面板提交了候选人：在光标处插入 `@名字 ` 并登记提及账号。
  void _onMentionRequested() {
    final MentionCandidate? candidate = widget.mentionController?.take();
    if (candidate == null || !mounted) {
      return;
    }
    _insertMention(candidate);
    _focus.requestFocus();
  }

  void _onChanged() {
    widget.onDraftChanged?.call(_controller.text);
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
                      ? context.t('关闭（普通消息）')
                      : context.t('{0}后销毁', [
                          ephemeralTtlLabel(hours, context.l10n),
                        ]),
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
            ListTile(title: Text(context.t('选择要 @ 的成员'))),
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
    final int start = selection.start < 0
        ? _controller.text.length
        : selection.start;
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.t('{0}功能将在后续版本开放', [name]))));
  }

  void _showVoiceNotice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 按住说话：检查权限并开始录音，最多 60 秒后自动发送。
  Future<void> _startRecording() async {
    final VoiceRecorder? recorder = widget.voiceRecorder;
    if (recorder == null) {
      _notImplemented(context.t('按住说话'));
      return;
    }
    if (!recorder.supported) {
      _showVoiceNotice(
        context.t('当前平台不支持按住说话，请用音频按钮选择音频文件'),
      );
      return;
    }
    if (_recording || _recordStartFuture != null) {
      return;
    }
    final int serial = ++_recordStartSerial;
    if (mounted) {
      setState(() => _recordCancelled = false);
    }
    final Future<bool> startFuture = recorder.start();
    _recordStartFuture = startFuture;
    bool started = false;
    try {
      started = await startFuture;
    } on Object {
      started = false;
    } finally {
      if (_recordStartSerial == serial) {
        _recordStartFuture = null;
      }
    }
    if (!mounted || serial != _recordStartSerial) {
      if (started) {
        unawaited(recorder.cancel());
      }
      return;
    }
    if (!started) {
      _showVoiceNotice(context.t('无法开始录音，请检查麦克风权限'));
      return;
    }
    setState(() {
      _recording = true;
      _recordSeconds = 0;
    });
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _recordSeconds++);
      if (_recordSeconds >= 60) {
        unawaited(_finishRecording());
      }
    });
  }

  /// 松手结束录音：上滑取消则丢弃，否则发送。
  Future<void> _finishRecording() async {
    final VoiceRecorder? recorder = widget.voiceRecorder;
    if (recorder == null) return;
    // 权限弹窗期间松手：等当前 start 完成后统一收尾，避免录音失控。
    final Future<bool>? pending = _recordStartFuture;
    if (pending != null) {
      await pending.catchError((Object _) => false);
    }
    if (!_recording) return;
    _recordTimer?.cancel();
    _recordTimer = null;
    final bool cancelled = _recordCancelled;
    if (mounted) {
      setState(() {
        _recording = false;
        _recordCancelled = false;
      });
    }
    if (cancelled) {
      await recorder.cancel();
      return;
    }
    final VoiceRecording? recording = await recorder.stop();
    if (!mounted) return;
    if (recording == null) {
      _showVoiceNotice(context.t('录音时间太短，未发送'));
      return;
    }
    await widget.onVoiceSend?.call(recording);
  }

  void _cancelRecording() {
    final VoiceRecorder? recorder = widget.voiceRecorder;
    _recordTimer?.cancel();
    _recordTimer = null;
    final Future<bool>? pending = _recordStartFuture;
    if (mounted) {
      setState(() => _recording = false);
    }
    if (pending != null) {
      // 权限弹窗期间取消：等 start 落地后再 cancel，避免录音稍后自行启动。
      _recordCancelled = true;
      unawaited(
        pending.then((_) => recorder?.cancel()).catchError((Object _) {}),
      );
      return;
    }
    if (mounted) {
      setState(() => _recordCancelled = false);
    }
    if (recorder != null) unawaited(recorder.cancel());
  }

  void _onRecordMove(LongPressMoveUpdateDetails details) {
    final bool cancelled = details.localOffsetFromOrigin.dy < -60;
    if (cancelled != _recordCancelled && mounted) {
      setState(() => _recordCancelled = cancelled);
    }
  }

  /// 输入模式切换：语音态收起键盘，文字态正常输入。
  void _toggleInputMode() {
    if (_recording) {
      _cancelRecording();
    }
    setState(() {
      _voiceMode = !_voiceMode;
      _emojiOpen = false;
    });
    if (_voiceMode) {
      _focus.unfocus();
    }
  }

  /// 展开 / 收起表情面板（ui-spec.md §3 输入工具条）。
  void _toggleEmoji() {
    setState(() => _emojiOpen = !_emojiOpen);
  }

  /// 在光标处插入表情；有选区时替换选区，光标无效时追加到末尾。
  void _insertEmoji(String emoji) {
    final TextEditingValue value = _controller.value;
    final TextSelection sel = value.selection;
    final bool valid =
        sel.isValid && sel.start >= 0 && sel.end <= value.text.length;
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
                icon: _emojiOpen
                    ? Icons.keyboard_alt_outlined
                    : Icons.emoji_emotions_outlined,
                tooltip: context.t('表情'),
                onTap: _toggleEmoji,
              ),
              if (widget.mentionCandidates.isNotEmpty)
                _ToolButton(
                  icon: Icons.alternate_email,
                  tooltip: context.t('@ 成员'),
                  onTap: _showMentionPicker,
                ),
              _ToolButton(
                icon: Icons.timer_outlined,
                tooltip: _ttlHours == 0
                    ? context.t('定时销毁')
                    : context.t('定时销毁：{0}', [
                        ephemeralTtlLabel(_ttlHours, context.l10n),
                      ]),
                onTap: _showTtlPicker,
              ),
              _ToolButton(
                icon: Icons.image_outlined,
                tooltip: context.t('图片'),
                onTap:
                    widget.onAttachImage ??
                    () => _notImplemented(context.t('图片')),
              ),
              _ToolButton(
                icon: Icons.movie_outlined,
                tooltip: context.t('视频'),
                onTap:
                    widget.onAttachVideo ??
                    () => _notImplemented(context.t('视频')),
              ),
              _ToolButton(
                icon: Icons.audiotrack_outlined,
                tooltip: context.t('音频'),
                onTap:
                    widget.onAttachAudio ??
                    () => _notImplemented(context.t('音频')),
              ),
              _ToolButton(
                icon: Icons.attach_file,
                tooltip: context.t('文件'),
                onTap:
                    widget.onAttachFile ??
                    () => _notImplemented(context.t('文件')),
              ),
              if (widget.onAttachFolder != null)
                _ToolButton(
                  icon: Icons.folder_outlined,
                  tooltip: context.t('发送文件夹'),
                  onTap: widget.onAttachFolder!,
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
                    context.t('定时销毁：{0}后', [
                      ephemeralTtlLabel(_ttlHours, context.l10n),
                    ]),
                    key: const ValueKey<String>('ttl-active-chip'),
                    style: TextStyle(fontSize: 11, color: NexmemColors.warning),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              IconButton(
                key: const ValueKey<String>('chat-input-mode-toggle'),
                tooltip: context.t(_voiceMode ? '文字输入' : '语音输入'),
                icon: Icon(
                  _voiceMode ? Icons.keyboard_outlined : Icons.mic_none,
                ),
                onPressed: _toggleInputMode,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: _voiceMode
                    ? GestureDetector(
                        key: const ValueKey<String>('chat-voice-input'),
                        behavior: HitTestBehavior.opaque,
                        onLongPressStart: (_) => unawaited(_startRecording()),
                        onLongPressEnd: (_) => unawaited(_finishRecording()),
                        onLongPressMoveUpdate: _onRecordMove,
                        onLongPressCancel: _cancelRecording,
                        child: Container(
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _recordCancelled
                                ? scheme.error.withValues(alpha: 0.10)
                                : scheme.onSurface.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(
                              NexmemMetrics.radiusListItem,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                _recordCancelled ? Icons.close : Icons.mic_none,
                                size: 18,
                                color: _recordCancelled
                                    ? scheme.error
                                    : scheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _recordCancelled
                                    ? context.t('松开取消录音')
                                    : _recording
                                        ? context.t(
                                            '录音中 {0} 秒 · 松开发送，上滑取消',
                                            [_recordSeconds],
                                          )
                                        : context.t('按住说话'),
                                style: TextStyle(
                                  fontSize: 14,
                                  color: _recordCancelled
                                      ? scheme.error
                                      : scheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : CallbackShortcuts(
                        // 桌面/Web：Enter 发送，Shift+Enter 交给输入框换行。
                        bindings: <ShortcutActivator, VoidCallback>{
                          const SingleActivator(LogicalKeyboardKey.enter):
                              _submit,
                          const SingleActivator(LogicalKeyboardKey.numpadEnter):
                              _submit,
                        },
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: kMaxMessageChars,
                          buildCounter: _messageCounter,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _submit(),
                          style: const TextStyle(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: context.t('输入消息'),
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
              if (!_voiceMode) ...<Widget>[
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
                  child: Text(context.t('发送')),
                ),
              ],
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
        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 20))),
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
    // 自己气泡是主色深底用白字；对方气泡跟随主题，暗色下不能用近黑色。
    final Color foreground = mine
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
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
            style: TextStyle(
              fontSize: 12,
              color: foreground.withValues(alpha: 0.85),
            ),
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
            margin: const EdgeInsetsDirectional.only(end: 8),
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
                  context.t('引用 {0}', [
                    quoting.isMine ? context.t('我') : quoting.senderName,
                  ]),
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
            tooltip: context.t('取消引用'),
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
