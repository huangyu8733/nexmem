// 多语言（i18n）与 RTL 排版验收。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/l10n/l10n.dart';

class _FakeSettings implements LocaleSettings {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

/// 显示当前 Directionality 与一条本地化文案的探针。
class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    return Text(
      '${Directionality.of(context)}|${context.t('关闭')}',
      key: const ValueKey<String>('rtl-probe'),
    );
  }
}

Widget _appWithLocale(Locale locale) {
  return MaterialApp(
    locale: locale,
    supportedLocales: supportedLocales,
    localizationsDelegates: <LocalizationsDelegate<dynamic>>[
      const AppLocalizationsDelegate(),
      ...GlobalMaterialLocalizations.delegates,
    ],
    home: const _Probe(),
  );
}

void main() {
  group('翻译表完整性', () {
    const List<String> languages = <String>['en', 'zh_TW', 'ja', 'ar', 'he', 'ko'];

    test('6 张内置翻译表 key 集合完全一致', () {
      final Set<String> baseline = translationKeys('en');
      expect(baseline.length, greaterThanOrEqualTo(300));
      for (final String language in languages) {
        expect(
          translationTableSizes[language],
          baseline.length,
          reason: '$language 表词条数应与英文表一致',
        );
        expect(
          translationKeys(language).difference(baseline),
          isEmpty,
          reason: '$language 表不应有多余 key',
        );
        expect(
          baseline.difference(translationKeys(language)),
          isEmpty,
          reason: '$language 表不应缺少 key',
        );
      }
    });

    test('核心 UI 文案在全部语种都有译文', () {
      for (final String key in <String>[
        '消息', '联系人', '我的', '设置', '语言', '关闭', '保存',
        '发消息', '拉黑', '本机设备', '未登录设备', '账号已复制',
        '删除会话失败（{0}）', '{0}已复制',
      ]) {
        for (final String language in languages) {
          expect(
            translationHasKey(language, key),
            isTrue,
            reason: '$language 缺少 key: $key',
          );
        }
      }
    });
  });

  group('翻译回退链', () {
    test('中文原文直接回退，不误落到英文表', () {
      expect(lookupTranslation(const Locale('zh', 'CN'), '关闭'), '关闭');
      expect(lookupTranslation(const Locale('zh', 'CN'), '消息'), '消息');
    });

    test('英文命中翻译表', () {
      expect(lookupTranslation(const Locale('en', 'US'), '关闭'), 'Close');
      expect(lookupTranslation(const Locale('en', 'US'), '消息'), 'Messages');
      expect(lookupTranslation(const Locale('en', 'US'), '个人资料'), 'Profile');
    });

    test('繁体中文命中 zh_TW 表', () {
      expect(lookupTranslation(const Locale('zh', 'TW'), '消息'), '訊息');
      expect(lookupTranslation(const Locale('zh', 'TW'), '关闭'), '關閉');
    });

    test('日文 / 阿拉伯文 / 希伯来文命中各自表', () {
      expect(lookupTranslation(const Locale('ja', 'JP'), '消息'), 'メッセージ');
      expect(lookupTranslation(const Locale('ar', 'SA'), '消息'), 'الرسائل');
      expect(lookupTranslation(const Locale('he', 'IL'), '消息'), 'הודעות');
    });

    test('未内置翻译的语种回退英文，再回退原文', () {
      expect(lookupTranslation(const Locale('it', 'IT'), '关闭'), 'Close');
      expect(
        lookupTranslation(const Locale('fr', 'FR'), 'nexmem-不存在的文案-key'),
        'nexmem-不存在的文案-key',
      );
    });

    test('占位符按顺序替换', () {
      final AppLocalizations l = AppLocalizations(const Locale('en', 'US'));
      expect(l.t('删除会话失败（{0}）', ['E01']), contains('E01'));
    });
  });

  group('RTL 语种判定', () {
    test('阿拉伯语 / 希伯来语 / 波斯语 / 乌尔都语为 RTL', () {
      expect(isRtlLocale(const Locale('ar', 'SA')), isTrue);
      expect(isRtlLocale(const Locale('he', 'IL')), isTrue);
      expect(isRtlLocale(const Locale('fa', 'IR')), isTrue);
      expect(isRtlLocale(const Locale('ur', 'PK')), isTrue);
    });

    test('中文 / 英文 / 日文为 LTR', () {
      expect(isRtlLocale(const Locale('zh', 'CN')), isFalse);
      expect(isRtlLocale(const Locale('en', 'US')), isFalse);
      expect(isRtlLocale(const Locale('ja', 'JP')), isFalse);
    });
  });

  group('语言设置编解码', () {
    test('设置值往返：zh_TW / en / system', () {
      expect(formatLocaleSetting(const Locale('zh', 'TW')), 'zh_TW');
      expect(parseLocaleSetting('zh_TW')?.languageCode, 'zh');
      expect(parseLocaleSetting('zh_TW')?.countryCode, 'TW');
      expect(parseLocaleSetting('en')?.languageCode, 'en');
      expect(parseLocaleSetting('system'), isNull);
      expect(parseLocaleSetting(''), isNull);
      expect(parseLocaleSetting(null), isNull);
    });
  });

  group('LocaleController 三态持久化', () {
    test('首次安装默认中文；切换写入设置；跟随系统写 system', () async {
      final _FakeSettings store = _FakeSettings();
      final LocaleController c = LocaleController(store);
      expect(c.locale, LocaleController.defaultLocale);

      await c.restore();
      expect(c.locale, LocaleController.defaultLocale);

      await c.setLocale(const Locale('ar', 'SA'));
      expect(c.locale, const Locale('ar', 'SA'));
      expect(store.values[localeSettingKey], 'ar_SA');

      await c.setLocale(null);
      expect(c.locale, isNull);
      expect(store.values[localeSettingKey], systemLocaleValue);

      // 重启后从 system 恢复为跟随系统（null）
      final LocaleController c2 = LocaleController(store);
      await c2.restore();
      expect(c2.locale, isNull);
      c.dispose();
      c2.dispose();
    });
  });

  group('RTL 排版端到端', () {
    testWidgets('阿拉伯语 locale 下组件树为 RTL 且文案为阿文',
        (WidgetTester tester) async {
      await tester.pumpWidget(_appWithLocale(const Locale('ar', 'SA')));
      await tester.pumpAndSettle();
      final Text t = tester.widget<Text>(find.byKey(const ValueKey<String>('rtl-probe')));
      expect(t.data, contains('rtl'));
      expect(t.data, contains('إغلاق'));
    });

    testWidgets('中文 locale 下组件树为 LTR 且文案为中文',
        (WidgetTester tester) async {
      await tester.pumpWidget(_appWithLocale(const Locale('zh', 'CN')));
      await tester.pumpAndSettle();
      final Text t = tester.widget<Text>(find.byKey(const ValueKey<String>('rtl-probe')));
      expect(t.data, contains('ltr'));
      expect(t.data, contains('关闭'));
    });

    testWidgets('英文 locale 下文案为英文', (WidgetTester tester) async {
      await tester.pumpWidget(_appWithLocale(const Locale('en', 'US')));
      await tester.pumpAndSettle();
      final Text t = tester.widget<Text>(find.byKey(const ValueKey<String>('rtl-probe')));
      expect(t.data, contains('ltr'));
      expect(t.data, contains('Close'));
    });
  });

  group('应用名称本地化', () {
    test('各语种显示名与内置翻译表一致', () {
      expect(appDisplayName(const Locale('zh', 'CN')), '奈讯联');
      expect(appDisplayName(const Locale('zh', 'TW')), '奈訊聯');
      expect(appDisplayName(const Locale('ja', 'JP')), 'ネクスメモ');
      expect(appDisplayName(const Locale('ko', 'KR')), '넥스멤');
      expect(appDisplayName(const Locale('ar', 'SA')), 'نكس ميم');
      expect(appDisplayName(const Locale('he', 'IL')), 'נקסמם');
      expect(appDisplayName(const Locale('fr', 'FR')), 'Nexmem');

      expect(AppLocalizations(const Locale('zh', 'CN')).t('奈讯联'), '奈讯联');
      expect(AppLocalizations(const Locale('zh', 'TW')).t('奈讯联'), '奈訊聯');
      expect(AppLocalizations(const Locale('en', 'US')).t('奈讯联'), 'Nexmem');
      expect(AppLocalizations(const Locale('ja', 'JP')).t('奈讯联'), 'ネクスメモ');
      expect(AppLocalizations(const Locale('ko', 'KR')).t('奈讯联'), '넥스멤');
      expect(AppLocalizations(const Locale('ar', 'SA')).t('奈讯联'), 'نكس ميم');
      expect(AppLocalizations(const Locale('he', 'IL')).t('奈讯联'), 'נקסמם');
    });
  });
}
