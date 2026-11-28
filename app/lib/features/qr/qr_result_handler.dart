/// 二维码识别结果的统一处理：网址进入内置浏览器，其它内容展示可复制文本。
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_dialog.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../browser/browser_page.dart';
import '../browser/browser_url.dart';

/// 返回 true 表示结果被识别为网址并已打开内置浏览器。
Future<bool> handleQrResult(BuildContext context, String raw) async {
  final String value = raw.trim();
  if (value.isEmpty) {
    return false;
  }
  final String? url = normalizeWebUrl(value);
  if (url != null) {
    await openInAppBrowser(context, url);
    return true;
  }
  final String title = context.t('二维码内容');
  final String copyLabel = context.t('复制');
  final String closeLabel = context.t('关闭');
  final String copied = context.t('已复制');
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: responsiveDialogContent(
        maxWidth: 320,
        child: SelectableText(
          value,
          key: const ValueKey<String>('qr-result-text'),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(closeLabel),
        ),
        FilledButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              Navigator.of(context).pop();
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text(copied)),
              );
            }
          },
          child: Text(copyLabel),
        ),
      ],
    ),
  );
  return false;
}
