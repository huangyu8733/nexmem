import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import 'image_crop_page.dart';
import 'profile_avatar.dart';
import 'profile_image.dart';
import 'scrolling_id_text.dart';
import 'settings_service.dart';
import '../../app/app_dialog.dart';

/// 个人资料在本机 KV 表中的键（`settings.get` / `settings.set`）。
///
/// 采用设置键而非新增契约/迁移：内核 `kv` 表随账号备份全库快照导出，
/// 也随 P6-41 设置快照在设备间搬运，介绍、推广信息与图片因此天然跨设备同步。
const String profileNicknameSettingKey = 'profile.nickname';
const String profileIntroSettingKey = 'profile.intro';
const String profilePromoSettingKey = 'profile.promo';

/// 昵称上限；空串回落账号昵称。
const int profileNicknameMaxChars = 32;

/// 单个文本字段的字符上限。内核 `settings.set` 的 value 上限为 4096 UTF-8 字节，
/// 中文按 3 字节计，取 1200 字符留出安全余量（最高 3600 字节）。
const int profileFieldMaxChars = 1200;

/// 个人资料字段读取结果：区分「未设置」与「读取失败」，避免离线时把空串误存。
class _ProfileValues {
  const _ProfileValues({
    this.nickname,
    this.intro,
    this.promo,
    this.avatar,
    this.promoImage,
    this.error,
  });

  final String? nickname;
  final String? intro;
  final String? promo;
  final ProfileImageData? avatar;
  final ProfileImageData? promoImage;
  final String? error;
}

/// 个人详情面板内容：头像 / 昵称 / 完整账号 + 个人介绍 / 推广信息与图片。
///
/// 同时被宽屏右栏 [ProfileDetailPanel] 与窄屏 [ProfileEditorDialog] 复用。
/// 图片选择后立即压缩并分片写入 KV；文本字段点「保存资料」统一写入。
class ProfileBody extends StatefulWidget {
  const ProfileBody({
    super.key,
    required this.account,
    required this.settings,
    this.onSaved,
  });

  final CoreAccount? account;
  final SettingsService settings;

  /// 保存成功后的回调，用于显示提示或刷新外部状态。
  final VoidCallback? onSaved;

  @override
  State<ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends State<ProfileBody> {
  late final TextEditingController _nickname;
  late final TextEditingController _intro;
  late final TextEditingController _promo;
  late final ProfileImageStore _images;
  late Future<_ProfileValues> _loading;

  ProfileImageData? _avatar;
  ProfileImageData? _promoImage;
  bool _saving = false;
  bool _pickingAvatar = false;
  bool _pickingPromo = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nickname = TextEditingController();
    _intro = TextEditingController();
    _promo = TextEditingController();
    _images = ProfileImageStore(widget.settings);
    _loading = _load();
  }

  Future<_ProfileValues> _load() async {
    try {
      final String? nickname = await widget.settings.read(
        profileNicknameSettingKey,
      );
      final String? intro = await widget.settings.read(profileIntroSettingKey);
      final String? promo = await widget.settings.read(profilePromoSettingKey);
      final ProfileImageData? avatar = await _images.load(
        ProfileImageSlot.avatar,
      );
      final ProfileImageData? promoImage = await _images.load(
        ProfileImageSlot.promo,
      );
      _nickname.text = nickname ?? '';
      _intro.text = intro ?? '';
      _promo.text = promo ?? '';
      _avatar = avatar;
      _promoImage = promoImage;
      return _ProfileValues(
        nickname: nickname,
        intro: intro,
        promo: promo,
        avatar: avatar,
        promoImage: promoImage,
      );
    } on Object catch (error) {
      return _ProfileValues(error: '$error');
    }
  }

  @override
  void dispose() {
    _nickname.dispose();
    _intro.dispose();
    _promo.dispose();
    super.dispose();
  }

  String _displayName(BuildContext context) {
    final String nickname = _nickname.text.trim();
    if (nickname.isNotEmpty) {
      return nickname;
    }
    final String? name = widget.account?.displayName.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return widget.account == null
        ? context.t('未登录设备')
        : context.t('本机设备');
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    final String nickname = _nickname.text.trim();
    final String intro = _intro.text.trim();
    final String promo = _promo.text.trim();
    if (nickname.length > profileNicknameMaxChars ||
        intro.length > profileFieldMaxChars ||
        promo.length > profileFieldMaxChars) {
      setState(() {
        _error = context.t('昵称不超过 {0} 字；介绍与推广信息各不超过 {1} 字', [
          profileNicknameMaxChars,
          profileFieldMaxChars,
        ]);
        _status = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _status = null;
    });
    try {
      await widget.settings.write(profileNicknameSettingKey, nickname);
      await widget.settings.write(profileIntroSettingKey, intro);
      await widget.settings.write(profilePromoSettingKey, promo);
      if (!mounted) {
        return;
      }
      setState(() => _status = context.t('已保存'));
      // 头像变更即时同步到全局缓存，左栏 / 我的页头像无需重建即可刷新。
      unawaited(ProfileAvatarStore.instance.reload());
      widget.onSaved?.call();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = context.t('保存失败：{0}', [error]));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _pickImage(ProfileImageSlot slot) async {
    final bool picking = slot == ProfileImageSlot.avatar
        ? _pickingAvatar
        : _pickingPromo;
    if (picking) {
      return;
    }
    setState(() {
      if (slot == ProfileImageSlot.avatar) {
        _pickingAvatar = true;
      } else {
        _pickingPromo = true;
      }
      _error = null;
      _status = null;
    });
    try {
      final PickedProfileImage? picked = await pickProfileImageFile();
      if (picked == null) {
        return;
      }
      if (!mounted || !context.mounted) {
        return;
      }
      final Uint8List? cropped = await showImageCropPage(
        context: context,
        bytes: picked.bytes,
        fileName: picked.name,
        square: slot == ProfileImageSlot.avatar,
      );
      if (cropped == null) {
        return;
      }
      if (!mounted || !context.mounted) {
        return;
      }
      final ProfileImageData data = await prepareProfileImage(
        cropped,
        picked.name,
      );
      await _images.save(slot, data);
      if (!mounted) {
        return;
      }
      setState(() {
        if (slot == ProfileImageSlot.avatar) {
          _avatar = data;
        } else {
          _promoImage = data;
        }
        _status = context.t('{0}已更新（{1}×{2}）', [
          slot.label,
          data.width,
          data.height,
        ]);
      });
      // 头像变更即时同步到全局缓存，左栏 / 我的页头像无需重建即可刷新。
      unawaited(ProfileAvatarStore.instance.reload());
      widget.onSaved?.call();
    } on ProfileImageException catch (error) {
      if (mounted) {
        setState(() => _error = context.t('{0}：{1}', [slot.label, error.message]));
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = context.t('{0}处理失败：{1}', [slot.label, error]));
      }
    } finally {
      if (mounted) {
        setState(() {
          _pickingAvatar =
              slot == ProfileImageSlot.avatar ? false : _pickingAvatar;
          _pickingPromo =
              slot == ProfileImageSlot.promo ? false : _pickingPromo;
        });
      }
    }
  }

  /// 对已保存的图片重新裁剪（头像仍固定 1:1 方形，推广图自由比例）。
  Future<void> _cropImage(ProfileImageSlot slot) async {
    final ProfileImageData? current = slot == ProfileImageSlot.avatar
        ? _avatar
        : _promoImage;
    if (current == null || !context.mounted) {
      return;
    }
    setState(() {
      _error = null;
      _status = null;
    });
    try {
      final Uint8List? cropped = await showImageCropPage(
        context: context,
        bytes: current.bytes,
        fileName: '${slot.name}.jpg',
        square: slot == ProfileImageSlot.avatar,
      );
      if (cropped == null) {
        return;
      }
      if (!mounted || !context.mounted) {
        return;
      }
      final ProfileImageData data = await prepareProfileImage(
        cropped,
        '${slot.name}.jpg',
      );
      await _images.save(slot, data);
      if (!mounted) {
        return;
      }
      setState(() {
        if (slot == ProfileImageSlot.avatar) {
          _avatar = data;
        } else {
          _promoImage = data;
        }
        _status = context.t('{0}已更新（{1}×{2}）', [
          slot.label,
          data.width,
          data.height,
        ]);
      });
      // 头像变更即时同步到全局缓存，左栏 / 我的页头像无需重建即可刷新。
      unawaited(ProfileAvatarStore.instance.reload());
      widget.onSaved?.call();
    } on ProfileImageException catch (error) {
      if (mounted) {
        setState(() => _error = context.t('{0}处理失败：{1}', [slot.label, error.message]));
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = context.t('{0}处理失败：{1}', [slot.label, error]));
      }
    }
  }

  Future<void> _clearImage(ProfileImageSlot slot) async {
    try {
      await _images.clear(slot);
      if (!mounted) {
        return;
      }
      setState(() {
        if (slot == ProfileImageSlot.avatar) {
          _avatar = null;
        } else {
          _promoImage = null;
        }
        _status = context.t('{0}已移除', [slot.label]);
        _error = null;
      });
      // 头像变更即时同步到全局缓存，左栏 / 我的页头像无需重建即可刷新。
      unawaited(ProfileAvatarStore.instance.reload());
      widget.onSaved?.call();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = context.t('移除{0}失败：{1}', [slot.label, error]));
      }
    }
  }

  Future<void> _copyValue(String value, String label) async {
    if (value.isEmpty) {
      return;
    }
    // 文案在 await 之前取好，避免 async gap 后使用 context。
    final String message = context.t('{0}已复制', [label]);
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _copyAccount() => _copyValue(widget.account?.accountId ?? '', '账号');
  Future<void> _copyDevice() => _copyValue(widget.account?.deviceId ?? '', '设备');

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FutureBuilder<_ProfileValues>(
      future: _loading,
      builder: (BuildContext context, AsyncSnapshot<_ProfileValues> snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final _ProfileValues values = snap.data!;
        return ListView(
          padding: const EdgeInsets.all(NexmemMetrics.space16),
          children: <Widget>[
            _accountCard(context, scheme),
            const SizedBox(height: NexmemMetrics.space16),
            if (values.error case final String error)
              Padding(
                padding: const EdgeInsets.only(bottom: NexmemMetrics.space12),
                child: Text(
                  context.t('读取本机资料失败：{0}', [error]),
                  key: const ValueKey<String>('profile-read-error'),
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            _field(
              context: context,
              label: context.t('昵称'),
              hint: context.t('设置展示昵称，最多 {0} 字', [profileNicknameMaxChars]),
              keyName: 'profile-nickname',
              controller: _nickname,
              icon: Icons.badge_outlined,
              maxLines: 1,
            ),
            const SizedBox(height: NexmemMetrics.space16),
            _field(
              context: context,
              label: context.t('个人介绍'),
              hint: context.t('介绍一下自己，最多 {0} 字', [profileFieldMaxChars]),
              keyName: 'profile-intro',
              controller: _intro,
              icon: Icons.person_outline,
            ),
            const SizedBox(height: NexmemMetrics.space16),
            _promoImageCard(context, scheme),
            const SizedBox(height: NexmemMetrics.space16),
            _field(
              context: context,
              label: context.t('个人推广信息'),
              hint: context.t('填写你的推广/引流信息，最多 {0} 字', [profileFieldMaxChars]),
              keyName: 'profile-promo',
              controller: _promo,
              icon: Icons.campaign_outlined,
            ),
            const SizedBox(height: NexmemMetrics.space16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey<String>('profile-save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(_saving ? context.t('保存中…') : context.t('保存资料')),
              ),
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                child: Text(
                  _status!,
                  key: const ValueKey<String>('profile-status'),
                  style: TextStyle(
                    color: NexmemColors.success,
                    fontSize: 12,
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: NexmemMetrics.space8),
                child: Text(
                  _error!,
                  key: const ValueKey<String>('profile-error'),
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            const SizedBox(height: NexmemMetrics.space12),
            Text(
              context.t(
                '头像与推广图片使用 base64 压缩存储（等比不超过 '
                '{0}×{0}，不支持 GIF，统一 JPEG），选择后立即保存；'
                '资料随账号备份/设置快照迁移，当前版本仅自己可见。',
                [profileImageMaxDimension],
              ),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _accountCard(BuildContext context, ColorScheme scheme) {
    final CoreAccount? account = widget.account;
    final String accountId = account?.accountId ?? '';
    final String deviceId = account?.deviceId ?? '';
    return Container(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _avatarPicker(scheme),
          const SizedBox(width: NexmemMetrics.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _displayName(context),
                  key: const ValueKey<String>('profile-display-name'),
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                ScrollingIdText(
                  text: accountId.isEmpty ? '—' : accountId,
                  keyName: 'profile-account-id-full',
                  label: context.t('账号'),
                  onCopy: accountId.isEmpty ? null : _copyAccount,
                  copyKeyName: 'profile-copy-account',
                ),
                const SizedBox(height: 4),
                ScrollingIdText(
                  text: deviceId.isEmpty ? '—' : deviceId,
                  keyName: 'profile-device-id',
                  label: context.t('设备'),
                  onCopy: deviceId.isEmpty ? null : _copyDevice,
                  copyKeyName: 'profile-copy-device',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarPicker(ColorScheme scheme) {
    final ProfileImageData? data = _avatar;
    final bool busy = _pickingAvatar;
    return Column(
      children: <Widget>[
        Stack(
          children: <Widget>[
            InkWell(
              key: const ValueKey<String>('profile-avatar-pick'),
              onTap: busy ? null : () => _pickImage(ProfileImageSlot.avatar),
              borderRadius: BorderRadius.circular(40),
              child: CircleAvatar(
                radius: NexmemMetrics.avatarSize / 2 + 8,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
                child: data == null
                    ? (busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.person_outline,
                            size: 26,
                            color: scheme.onSurface.withValues(alpha: 0.45),
                          ))
                    : ClipOval(
                        child: Image.memory(
                          data.bytes,
                          key: const ValueKey<String>('profile-avatar-image'),
                          width: NexmemMetrics.avatarSize + 16,
                          height: NexmemMetrics.avatarSize + 16,
                          fit: BoxFit.cover,
                        ),
                      ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.camera_alt_outlined,
                  size: 13,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ],
        ),
        if (data != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton(
                key: const ValueKey<String>('profile-avatar-crop'),
                onPressed: () => _cropImage(ProfileImageSlot.avatar),
                child: Text(
                  context.t('裁剪'),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              TextButton(
                key: const ValueKey<String>('profile-avatar-clear'),
                onPressed: () => _clearImage(ProfileImageSlot.avatar),
                child: Text(
                  context.t('移除'),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _promoImageCard(BuildContext context, ColorScheme scheme) {
    final ProfileImageData? data = _promoImage;
    final bool busy = _pickingPromo;
    return Container(
      padding: const EdgeInsets.all(NexmemMetrics.space12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.image_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: NexmemMetrics.space8),
              Text(context.t('推广图片'), style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey<String>('profile-promo-image-pick'),
                onPressed:
                    busy ? null : () => _pickImage(ProfileImageSlot.promo),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: Text(data == null ? context.t('选择图片') : context.t('更换')),
              ),
              if (data != null)
                IconButton(
                  key: const ValueKey<String>('profile-promo-crop'),
                  onPressed: () => _cropImage(ProfileImageSlot.promo),
                  icon: const Icon(Icons.crop, size: 18),
                  tooltip: context.t('裁剪'),
                ),
              if (data != null)
                IconButton(
                  key: const ValueKey<String>('profile-promo-image-clear'),
                  onPressed: () => _clearImage(ProfileImageSlot.promo),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: context.t('移除推广图片'),
                ),
            ],
          ),
          const SizedBox(height: NexmemMetrics.space8),
          if (busy)
            const SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (data != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
              child: Image.memory(
                data.bytes,
                key: const ValueKey<String>('profile-promo-image'),
                height: 160,
                width: double.infinity,
                fit: BoxFit.contain,
              ),
            )
          else
            Container(
              height: 96,
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
              ),
              child: Center(
                child: Text(
                  context.t('未设置推广图片'),
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          if (data != null)
            Padding(
              padding: const EdgeInsets.only(top: NexmemMetrics.space8),
              child: Text(
                '${data.width}×${data.height} · '
                '${(data.encodedBytes / 1024).round()} KB · JPEG/base64',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            context.t(
              '仅 PNG / JPG / BMP，等比压缩至 {0}×{0} 以内，GIF 不支持。',
              [profileImageMaxDimension],
            ),
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required BuildContext context,
    required String label,
    required String hint,
    required String keyName,
    required TextEditingController controller,
    required IconData icon,
    int maxLines = 4,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: NexmemMetrics.space8),
            Text(label, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: NexmemMetrics.space8),
        TextField(
          key: ValueKey<String>(keyName),
          controller: controller,
          maxLines: maxLines,
          maxLength:
              maxLines == 1 ? profileNicknameMaxChars : profileFieldMaxChars,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }
}

/// 宽屏三栏布局右栏使用的个人资料面板（带标题栏）。
class ProfileDetailPanel extends StatelessWidget {
  const ProfileDetailPanel({
    super.key,
    required this.account,
    required this.settings,
  });

  final CoreAccount? account;
  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PaneHeader(title: context.t('个人资料')),
        Expanded(
          child: ProfileBody(account: account, settings: settings),
        ),
      ],
    );
  }
}

/// 窄屏（单栏）设置页点击「个人资料」时弹出的全屏编辑对话框。
Future<void> showProfileEditorDialog({
  required BuildContext context,
  required CoreAccount? account,
  required SettingsService settings,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext context) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      return Dialog.fullscreen(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AppBar(
              title: Text(context.t('个人资料')),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
              backgroundColor: scheme.surface,
            ),
            Expanded(
              child: ProfileBody(account: account, settings: settings),
            ),
          ],
        ),
      );
    },
  );
}
