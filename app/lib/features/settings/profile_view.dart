import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import 'profile_image.dart';
import 'profile_panel.dart';
import 'scrolling_id_text.dart';
import 'settings_service.dart';
import '../../app/app_dialog.dart';

/// 只读资料展示数据：本机资料与联系人公开档案都映射到这里，共用同一套展示样式。
///
/// [intro] / [promo] / [avatar] / [promoImage] 为空时不展示对应区块，
/// 因此对方只发布了部分字段时也不会出现空白卡片。
class ProfileViewData {
  const ProfileViewData({
    required this.displayName,
    required this.accountId,
    required this.deviceId,
    this.intro = '',
    this.promo = '',
    this.avatar,
    this.promoImage,
  });

  final String displayName;
  final String accountId;
  final String deviceId;
  final String intro;
  final String promo;
  final Uint8List? avatar;
  final Uint8List? promoImage;
}

/// 只读资料卡：头像 / 昵称 / 账号 / 设备 / 个人介绍 / 推广图 / 推广信息。
///
/// 账号与设备为完整单行 + 左右箭头平移 + 一键复制（见 [ScrollingIdText]），
/// 全部只读，不含任何输入框——与「个人资料」菜单进入的编辑面板分离。
class ProfileViewCard extends StatelessWidget {
  const ProfileViewCard({
    super.key,
    required this.data,
    this.onCopyAccount,
    this.onCopyDevice,
  });

  final ProfileViewData data;

  /// 复制回调；为空时不显示复制按钮。默认实现由 [ProfileViewBody] 提供。
  final VoidCallback? onCopyAccount;
  final VoidCallback? onCopyDevice;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String accountId = data.accountId;
    final String deviceId = data.deviceId;
    return ListView(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(NexmemMetrics.space16),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _avatar(data.avatar, scheme),
              const SizedBox(width: NexmemMetrics.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      data.displayName.isEmpty ? context.t('未登录设备') : data.displayName,
                      key: const ValueKey<String>('profile-view-name'),
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    if (accountId.isNotEmpty)
                      ScrollingIdText(
                        text: accountId,
                        keyName: 'profile-view-account',
                        label: context.t('账号'),
                        onCopy: onCopyAccount,
                        copyKeyName: 'profile-view-copy-account',
                      ),
                    if (deviceId.isNotEmpty)
                      ScrollingIdText(
                        text: deviceId,
                        keyName: 'profile-view-device',
                        label: context.t('设备'),
                        onCopy: onCopyDevice,
                        copyKeyName: 'profile-view-copy-device',
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (data.intro.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: NexmemMetrics.space16),
          _section(
            context: context,
            icon: Icons.person_outline,
            label: context.t('个人介绍'),
            child: Text(
              data.intro.trim(),
              key: const ValueKey<String>('profile-view-intro'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
        if (data.promoImage != null) ...<Widget>[
          const SizedBox(height: NexmemMetrics.space16),
          _section(
            context: context,
            icon: Icons.image_outlined,
            label: context.t('推广图片'),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
              child: Image.memory(
                data.promoImage!,
                key: const ValueKey<String>('profile-view-promo-image'),
                height: 160,
                width: double.infinity,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ],
        if (data.promo.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: NexmemMetrics.space16),
          _section(
            context: context,
            icon: Icons.campaign_outlined,
            label: context.t('个人推广信息'),
            child: Text(
              data.promo.trim(),
              key: const ValueKey<String>('profile-view-promo'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ],
    );
  }

  Widget _avatar(Uint8List? bytes, ColorScheme scheme) {
    return CircleAvatar(
      radius: NexmemMetrics.avatarSize / 2 + 8,
      backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
      child: bytes == null
          ? Icon(
              Icons.person_outline,
              size: 26,
              color: scheme.onSurface.withValues(alpha: 0.45),
            )
          : ClipOval(
              child: Image.memory(
                bytes,
                key: const ValueKey<String>('profile-view-avatar'),
                width: NexmemMetrics.avatarSize + 16,
                height: NexmemMetrics.avatarSize + 16,
                fit: BoxFit.cover,
              ),
            ),
    );
  }

  Widget _section({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
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
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: NexmemMetrics.space8),
              Text(label, style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: NexmemMetrics.space8),
          child,
        ],
      ),
    );
  }
}

/// 从本机 KV 与内核账号加载只读资料，并提供复制能力。
class ProfileViewBody extends StatefulWidget {
  const ProfileViewBody({
    super.key,
    required this.account,
    required this.settings,
  });

  final CoreAccount? account;
  final SettingsService settings;

  @override
  State<ProfileViewBody> createState() => _ProfileViewBodyState();
}

class _ProfileViewBodyState extends State<ProfileViewBody> {
  late final Future<ProfileViewData?> _loading = _load();

  Future<ProfileViewData?> _load() async {
    // 文案在 await 之前取好，避免 async gap 后使用 context。
    final String localDeviceLabel = context.t('本机设备');
    try {
      final String? nickname = await widget.settings.read(
        profileNicknameSettingKey,
      );
      final String? intro = await widget.settings.read(profileIntroSettingKey);
      final String? promo = await widget.settings.read(profilePromoSettingKey);
      final ProfileImageStore images = ProfileImageStore(widget.settings);
      final ProfileImageData? avatar = await images.load(ProfileImageSlot.avatar);
      final ProfileImageData? promoImage = await images.load(ProfileImageSlot.promo);
      final String? kernelName = widget.account?.displayName.trim();
      final String displayName = (nickname?.trim().isNotEmpty ?? false)
          ? nickname!.trim()
          : (kernelName?.isNotEmpty ?? false)
              ? kernelName!
              : (widget.account == null ? '' : localDeviceLabel);
      return ProfileViewData(
        displayName: displayName,
        accountId: widget.account?.accountId ?? '',
        deviceId: widget.account?.deviceId ?? '',
        intro: intro ?? '',
        promo: promo ?? '',
        avatar: avatar?.bytes,
        promoImage: promoImage?.bytes,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _copy(String value, String label) async {
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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ProfileViewData?>(
      future: _loading,
      builder: (BuildContext context, AsyncSnapshot<ProfileViewData?> snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final ProfileViewData data = snap.data ??
            const ProfileViewData(
              displayName: '',
              accountId: '',
              deviceId: '',
            );
        return ProfileViewCard(
          data: data,
          onCopyAccount: data.accountId.isEmpty
              ? null
              : () => _copy(data.accountId, '账号'),
          onCopyDevice:
              data.deviceId.isEmpty ? null : () => _copy(data.deviceId, '设备'),
        );
      },
    );
  }
}

/// 独立使用时的只读资料弹窗（壳层未接入右栏回调时的兜底）。
Future<void> showProfileViewDialog({
  required BuildContext context,
  required CoreAccount? account,
  required SettingsService settings,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext context) {
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
            ),
            Expanded(
              child: ProfileViewBody(account: account, settings: settings),
            ),
          ],
        ),
      );
    },
  );
}

/// 桌面三栏右栏使用的只读资料面板（带标题栏）。
class ProfileViewPanel extends StatelessWidget {
  const ProfileViewPanel({
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
          child: ProfileViewBody(account: account, settings: settings),
        ),
      ],
    );
  }
}
