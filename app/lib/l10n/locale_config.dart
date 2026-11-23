import 'dart:ui' show Locale;

/// 界面语言设置键（`settings.get` / `settings.set`）。空串或 `system` 表示跟随系统。
const String localeSettingKey = 'ui.locale';

/// 「跟随系统」的设置值。
const String systemLocaleValue = 'system';

/// 内置语言：中文为基准（翻译 key 本身即中文），其余为可切换目标。
///
/// 「支持所有语种」的实现方式：框架不限制 locale，任何 [Locale] 均可被
/// [LocaleController] 接受并驱动界面；内置语言包覆盖主流语种，未命中的
/// 文案回退英文（中文则回退原文），因此任意语种下界面都不会出现空白。
/// RTL 语种由 [isRtlLocale] 判定，由 MaterialApp 的 locale 自动镜像布局。
const List<Locale> supportedLocales = <Locale>[
  Locale('zh', 'CN'),
  Locale('zh', 'TW'),
  Locale('en', 'US'),
  Locale('ja', 'JP'),
  Locale('ko', 'KR'),
  Locale('es', 'ES'),
  Locale('fr', 'FR'),
  Locale('de', 'DE'),
  Locale('pt', 'BR'),
  Locale('ru', 'RU'),
  Locale('it', 'IT'),
  Locale('nl', 'NL'),
  Locale('pl', 'PL'),
  Locale('tr', 'TR'),
  Locale('vi', 'VN'),
  Locale('th', 'TH'),
  Locale('id', 'ID'),
  Locale('ms', 'MY'),
  Locale('hi', 'IN'),
  Locale('ar', 'SA'),
  Locale('he', 'IL'),
  Locale('fa', 'IR'),
  Locale('ur', 'PK'),
  Locale('bn', 'BD'),
  Locale('uk', 'UA'),
  Locale('sv', 'SE'),
  Locale('da', 'DK'),
  Locale('fi', 'FI'),
  Locale('nb', 'NO'),
  Locale('cs', 'CZ'),
  Locale('el', 'GR'),
  Locale('ro', 'RO'),
  Locale('hu', 'HU'),
];

/// 需要从右到左排版（RTL）的语言代码。
const Set<String> rtlLanguageCodes = <String>{
  'ar',
  'he',
  'fa',
  'ur',
  'yi',
  'ps',
  'ku',
  'sd',
};

bool isRtlLocale(Locale locale) => rtlLanguageCodes.contains(locale.languageCode);

/// 分隔符：设置值使用 `language[_COUNTRY]`，例如 `zh_TW`。
String formatLocaleSetting(Locale locale) {
  final String countryCode = locale.countryCode ?? '';
  final String country = countryCode.isEmpty ? '' : '_$countryCode';
  return '${locale.languageCode}$country';
}

/// 从设置值解析 locale；空串 / `system` / 非法值返回 null（跟随系统）。
Locale? parseLocaleSetting(String? value) {
  if (value == null || value.isEmpty || value == systemLocaleValue) {
    return null;
  }
  final List<String> parts = value.split('_');
  if (parts.isEmpty || parts.first.isEmpty) {
    return null;
  }
  final String country = parts.length > 1 ? parts[1] : '';
  return Locale(parts.first, country);
}

/// 语言在自身语言中的显示名，供语言选择列表使用。
String localeDisplayName(Locale locale) {
  final String key = '${locale.languageCode}_${locale.countryCode ?? ''}';
  switch (key) {
    case 'zh_CN':
    case 'zh_':
      return '简体中文';
    case 'zh_TW':
      return '繁體中文';
    case 'en_US':
    case 'en_':
      return 'English';
    case 'ja_JP':
      return '日本語';
    case 'ko_KR':
      return '한국어';
    case 'es_ES':
      return 'Español';
    case 'fr_FR':
      return 'Français';
    case 'de_DE':
      return 'Deutsch';
    case 'pt_BR':
      return 'Português';
    case 'ru_RU':
      return 'Русский';
    case 'it_IT':
      return 'Italiano';
    case 'nl_NL':
      return 'Nederlands';
    case 'pl_PL':
      return 'Polski';
    case 'tr_TR':
      return 'Türkçe';
    case 'vi_VN':
      return 'Tiếng Việt';
    case 'th_TH':
      return 'ไทย';
    case 'id_ID':
      return 'Bahasa Indonesia';
    case 'ms_MY':
      return 'Bahasa Melayu';
    case 'hi_IN':
      return 'हिन्दी';
    case 'ar_SA':
      return 'العربية';
    case 'he_IL':
      return 'עברית';
    case 'fa_IR':
      return 'فارسی';
    case 'ur_PK':
      return 'اردو';
    case 'bn_BD':
      return 'বাংলা';
    case 'uk_UA':
      return 'Українська';
    case 'sv_SE':
      return 'Svenska';
    case 'da_DK':
      return 'Dansk';
    case 'fi_FI':
      return 'Suomi';
    case 'nb_NO':
      return 'Norsk';
    case 'cs_CZ':
      return 'Čeština';
    case 'el_GR':
      return 'Ελληνικά';
    case 'ro_RO':
      return 'Română';
    case 'hu_HU':
      return 'Magyar';
    default:
      return locale.languageCode.toUpperCase();
  }
}

/// 应用名称在各语种中的写法。
///
/// 中文使用官方中文名「奈讯联」，日文 / 韩文 / 阿拉伯文 / 希伯来文使用
/// Nexmem 的本地音译；其余语种沿用国际品牌名 Nexmem。
String appDisplayName(Locale locale) {
  final String key = '${locale.languageCode}_${locale.countryCode ?? ''}';
  switch (key) {
    case 'zh_CN':
    case 'zh_':
      return '奈讯联';
    case 'zh_TW':
    case 'zh_HK':
    case 'zh_MO':
      return '奈訊聯';
    case 'ja_JP':
    case 'ja_':
      return 'ネクスメモ';
    case 'ko_KR':
    case 'ko_':
      return '넥스멤';
    case 'ar_SA':
    case 'ar_':
      return 'نكس ميم';
    case 'he_IL':
    case 'he_':
      return 'נקסמם';
    default:
      return 'Nexmem';
  }
}
