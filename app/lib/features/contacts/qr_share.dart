/// 二维码交换 PeerID 加好友（P6-39，本地可闭环部分）。
///
/// 「我的二维码」用纯 Dart `qr` 包把内核签发的名片文本渲染为二维码；对方
/// 扫码后把文本粘贴到「从二维码添加」即可经内核验签解析账号 ID 并预填
/// 添加好友弹窗。相机扫码依赖真机权限，按 R-17 挂起，本文件不伪造扫码能力。
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart' as dartqr;

import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../../app/core_session.dart';
import 'add_friend_dialog.dart';
import 'contact_service.dart';

/// 打开「我的二维码」弹窗：展示当前账号名片二维码 + 可复制的文本。
Future<void> showMyQrDialog(
  BuildContext context,
  CoreSession session,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => _MyQrDialog(session: session),
  );
}

class _MyQrDialog extends StatefulWidget {
  const _MyQrDialog({required this.session});

  final CoreSession session;

  @override
  State<_MyQrDialog> createState() => _MyQrDialogState();
}

class _MyQrDialogState extends State<_MyQrDialog> {
  Future<QrPayload>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.session.qrPayload();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('我的二维码'),
      content: SizedBox(
        width: 260,
        child: FutureBuilder<QrPayload>(
          future: _future,
          builder: (BuildContext context, AsyncSnapshot<QrPayload> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return SizedBox(
                height: 240,
                child: Center(
                  child: Text('二维码生成失败：${snapshot.error ?? '未知错误'}'),
                ),
              );
            }
            final QrPayload card = snapshot.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  key: const ValueKey<String>('qr-code-image'),
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrMatrixView(data: card.payload, size: 208),
                ),
                const SizedBox(height: 12),
                Text(
                  card.accountId,
                  key: const ValueKey<String>('qr-account-id'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  key: const ValueKey<String>('qr-copy-button'),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制名片文本'),
                  onPressed: () async {
                    final ScaffoldMessengerState messenger =
                        ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: card.payload));
                    messenger.showSnackBar(
                      const SnackBar(content: Text('已复制，可发给对方扫码或粘贴')),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 打开「从二维码添加」弹窗：粘贴对方名片文本 → 内核验签 → 预填添加好友。
Future<void> showQrImportDialog(
  BuildContext context,
  CoreSession session,
  ContactService service,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        _QrImportDialog(session: session, service: service),
  );
}

class _QrImportDialog extends StatefulWidget {
  const _QrImportDialog({required this.session, required this.service});

  final CoreSession session;
  final ContactService service;

  @override
  State<_QrImportDialog> createState() => _QrImportDialogState();
}

class _QrImportDialogState extends State<_QrImportDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final String payload = _controller.text.trim();
    if (payload.isEmpty) {
      setState(() => _error = '请粘贴对方的二维码名片文本');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final QrCard card = await widget.session.qrParse(payload);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
      // 解析成功：把账号 ID 与昵称预填到既有添加好友弹窗。
      await showAddFriendDialogWithPreset(
        context,
        widget.service,
        account: card.accountId,
        alias: card.displayName,
      );
    } on NexmemException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.code == 'INVALID_ARG'
              ? '二维码无效或验签失败，请确认为 Nexmem 名片'
              : (error.message.isEmpty ? error.code : error.message);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '解析失败：$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('从二维码添加好友'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            '扫描对方二维码后，把识别出的文本粘贴到下方（相机扫码需真机权限）。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: NexmemMetrics.space12),
          TextField(
            key: const ValueKey<String>('qr-import-payload'),
            controller: _controller,
            maxLines: 3,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '二维码名片文本',
              hintText: 'nexmem://add/...',
              border: OutlineInputBorder(),
              errorText: null,
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              key: const ValueKey<String>('qr-import-error'),
              style: const TextStyle(color: NexmemColors.danger, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('qr-import-submit'),
          onPressed: _busy ? null : _parse,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('解析'),
        ),
      ],
    );
  }
}

/// 用纯 Dart 把文本编码为二维码矩阵并绘制。无平台依赖，六端一致。
class QrMatrixView extends StatelessWidget {
  const QrMatrixView({super.key, required this.data, this.size = 200});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dartqr.QrCode code = dartqr.QrCode(
      payload: dartqr.QrPayload.fromString(data),
      errorCorrectLevel: dartqr.QrErrorCorrectLevel.medium,
    );
    final dartqr.QrImage image = dartqr.QrImage(code);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        key: const ValueKey<String>('qr-matrix'),
        painter: _QrPainter(image),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final dartqr.QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final double side = size.width < size.height ? size.width : size.height;
    final double cell = side / image.moduleCount;
    final Paint dark = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    final Paint light = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, light);
    for (int row = 0; row < image.moduleCount; row++) {
      for (int col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) {
          canvas.drawRect(
            Rect.fromLTWH(col * cell, row * cell, cell + 0.5, cell + 0.5),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.image != image;
}
