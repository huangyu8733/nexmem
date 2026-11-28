// 群头像与群介绍编辑弹窗。
//
// 群头像走系统文件选择 → 交互式 1:1 裁剪 → 512x512 JPEG 归一化；
// 群介绍限 512 字。两者都只返回待提交值，实际落库与广播由 GroupService 完成。

import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../app/app_dialog.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../settings/image_crop_page.dart';
import '../settings/profile_image.dart';

const int groupDescriptionMaxRunes = 512;

/// 选择图片、裁剪并返回群头像 base64；取消返回 null。
///
/// 图片解码、压缩失败抛 [ProfileImageException] 或 [FormatException]，
/// 由调用方统一提示，避免弹窗静默关闭。
Future<String?> pickAndCropGroupAvatar(BuildContext context) async {
  final PickedProfileImage? picked = await pickProfileImageFile();
  if (picked == null) {
    return null;
  }
  if (!context.mounted) {
    return null;
  }
  final Uint8List? cropped = await showImageCropPage(
    context: context,
    bytes: picked.bytes,
    fileName: picked.name,
    square: true,
  );
  if (cropped == null) {
    return null;
  }
  final Uint8List jpeg = prepareGroupAvatarJpeg(cropped);
  return base64.encode(jpeg);
}

/// 编辑群介绍；返回 null 表示取消，空串表示清除。
Future<String?> showGroupDescriptionDialog(
  BuildContext context, {
  required String current,
}) {
  final TextEditingController controller =
      TextEditingController(text: current);
  return showAppDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      key: const ValueKey<String>('group-description-dialog'),
      title: Text(context.t('群介绍')),
      content: responsiveDialogContent(
        maxWidth: 420,
        child: TextField(
          key: const ValueKey<String>('group-description-field'),
          controller: controller,
          maxLines: 6,
          maxLength: groupDescriptionMaxRunes,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.t('群介绍'),
            hintText: context.t('介绍一下这个群，最多 512 字'),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.t('取消')),
        ),
        if (current.isNotEmpty)
          TextButton(
            key: const ValueKey<String>('group-description-clear'),
            onPressed: () => Navigator.pop(context, ''),
            child: Text(context.t('清除')),
          ),
        FilledButton(
          key: const ValueKey<String>('group-description-save'),
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(context.t('保存')),
        ),
      ],
    ),
  );
}
