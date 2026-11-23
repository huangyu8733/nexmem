import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/pane_header.dart';
import '../../app/theme.dart';
import 'settings_service.dart';

/// 个人资料在本机 KV 表中的键（`settings.get` / `settings.set`）。
///
/// 采用设置键而非新增契约/迁移：内核 `kv` 表随账号备份全库快照导出，
/// 也随 P6-41 设置快照在设备间搬运，介绍与推广信息因此天然跨设备同步。
const String profileIntroSettingKey = 'profile.intro';
const String profilePromoSettingKey = 'profile.promo';

/// 单个字段的字符上限。内核 `settings.set` 的 value 上限为 4096 UTF-8 字节，
/// 中文按 3 字节计，取 1200 字符留出安全余量（最高 3600 字节）。
const int profileFieldMaxChars = 1200;

/// 个人资料字段读取结果：区分「未设置」与「读取失败」，避免离线时把空串误存。
class _ProfileValues {
  const _ProfileValues({this.intro, this.promo, this.error});

  final String? intro;
  final String? promo;
  final String? error;
}

/// 个人详情面板内容：账号信息 + 个人介绍 / 个人推广信息编辑。
///
/// 同时被宽屏右栏 [ProfileDetailPanel] 与窄屏 [ProfileEditorDialog] 复用。
/// [account] 为空时账号区显示离线占位，但介绍/推广仍可编辑（写入本机 KV）。
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
  late final TextEditingController _intro;
  late final TextEditingController _promo;
  late Future<_ProfileValues> _loading;
  bool _saving = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _intro = TextEditingController();
    _promo = TextEditingController();
    _loading = _load();
  }

  Future<_ProfileValues> _load() async {
    try {
      final String? intro = await widget.settings.read(profileIntroSettingKey);
      final String? promo = await widget.settings.read(profilePromoSettingKey);
      _intro.text = intro ?? '';
      _promo.text = promo ?? '';
      return _ProfileValues(intro: intro, promo: promo);
    } on Object catch (error) {
      return _ProfileValues(error: '$error');
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _promo.dispose();
    super.dispose();
  }

  String get _displayName {
    final String? name = widget.account?.displayName.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return widget.account == null ? '未登录设备' : '本机设备';
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    final String intro = _intro.text.trim();
    final String promo = _promo.text.trim();
    if (intro.length > profileFieldMaxChars ||
        promo.length > profileFieldMaxChars) {
      setState(() {
        _error = '个人介绍与个人推广信息各不超过 $profileFieldMaxChars 字';
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
      await widget.settings.write(profileIntroSettingKey, intro);
      await widget.settings.write(profilePromoSettingKey, promo);
      setState(() => _status = '已保存');
      widget.onSaved?.call();
    } on Object catch (error) {
      setState(() => _error = '保存失败：$error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

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
                  '读取本机资料失败：$error',
                  key: const ValueKey<String>('profile-read-error'),
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            _field(
              context: context,
              label: '个人介绍',
              hint: '介绍一下自己，最多 $profileFieldMaxChars 字',
              keyName: 'profile-intro',
              controller: _intro,
              icon: Icons.person_outline,
            ),
            const SizedBox(height: NexmemMetrics.space16),
            _field(
              context: context,
              label: '个人推广信息',
              hint: '填写你的推广/引流信息，最多 $profileFieldMaxChars 字',
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
                label: Text(_saving ? '保存中…' : '保存资料'),
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
              '资料保存在本机并随账号备份/设置快照迁移到其他设备；'
              '当前版本仅自己可见，不会自动发布给联系人。',
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
    return Container(
      padding: const EdgeInsets.all(NexmemMetrics.space16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(NexmemMetrics.radiusListItem),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: NexmemMetrics.avatarSize / 2,
            backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
            child: Icon(
              Icons.person_outline,
              size: 24,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: NexmemMetrics.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _displayName,
                  key: const ValueKey<String>('profile-display-name'),
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                _infoRow('账号', account?.accountId ?? '—', 'profile-account-id'),
                const SizedBox(height: 2),
                _infoRow('设备', account?.deviceId ?? '—', 'profile-device-id'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, String keyName) {
    final String short = value.isEmpty
        ? '—'
        : value.length <= 24
            ? value
            : '${value.substring(0, 20)}…';
    return Row(
      children: <Widget>[
        SizedBox(
          width: 32,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: NexmemColors.lightTextSecondary),
          ),
        ),
        Expanded(
          child: Text(
            short,
            key: ValueKey<String>(keyName),
            style: const TextStyle(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _field({
    required BuildContext context,
    required String label,
    required String hint,
    required String keyName,
    required TextEditingController controller,
    required IconData icon,
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
          maxLines: 4,
          maxLength: profileFieldMaxChars,
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
        const PaneHeader(title: '个人资料'),
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
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      return Dialog.fullscreen(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AppBar(
              title: const Text('个人资料'),
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
