/// 国际化（i18n）统一入口。
///
/// 架构：以中文原文作为翻译 key，`AppLocalizations.t(context, key)` 运行时查表；
/// 未命中的文案按「当前语言 → 语言代码 → 英文 → 中文原文」回退，因此新增语种
/// 无需改动任何界面代码，也不会出现空白文案。
///
/// RTL：阿拉伯语 / 希伯来语 / 波斯语 / 乌尔都语等由 [isRtlLocale] 判定，
/// MaterialApp 依据 locale 自动为整个组件树设置镜像 `Directionality`。
library;

export 'app_localizations.dart';
export 'locale_config.dart';
export 'translations.dart';
