import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';

/// 语言选择对话框：跟随系统 + 全部内置语种。
///
/// 选择后立即通过 [LocaleController.setLocale] 切换并持久化；MaterialApp 依据
/// 新 locale 重建组件树，RTL 语种（阿拉伯语等）随之切换为从右到左排版。
/// 列表语种跨度大，对话框固定较高并滚动，避免在小屏溢出。
class LanguageDialog extends StatelessWidget {
  const LanguageDialog({super.key, this.closeOnSelect = true});

  /// 选择后是否关闭。独立弹窗为 true；内嵌设置面板传 false，
  /// 让用户切换语言后仍停留在语言界面（选中态随 LocaleScope 自动刷新）。
  final bool closeOnSelect;

  void _onSelect(BuildContext context, LocaleController controller, Locale? locale) {
    unawaited(controller.setLocale(locale));
    if (closeOnSelect) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final LocaleController controller = LocaleScope.of(context);
    final Locale? current = controller.locale;
    return AlertDialog(
      title: Text(context.t('语言')),
      content: responsiveDialogContent(
        maxWidth: 320,
        height: 420,
        child: ListView(
          children: <Widget>[
            _LanguageTile(
              label: context.t('跟随系统'),
              selected: current == null,
              onTap: () => _onSelect(context, controller, null),
            ),
            const Divider(height: 1),
            for (final Locale locale in supportedLocales)
              _LanguageTile(
                label: localeDisplayName(locale),
                selected: current != null &&
                    current.languageCode == locale.languageCode &&
                    (current.countryCode ?? '') == locale.countryCode,
                onTap: () => _onSelect(context, controller, locale),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('关闭')),
        ),
      ],
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey<String>('language-$label'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      selected: selected,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 20,
        color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.5),
      ),
      title: Text(label),
      onTap: onTap,
    );
  }
}
