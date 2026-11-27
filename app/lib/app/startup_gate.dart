// 启动服务就绪检测门（T43）。
//
// 痛点：iOS/首次启动时 gomobile 内核要生成主密钥，core.start 较慢；联系人等
// 页面在 initState 立即拉取，早于内核就绪会抛 NOT_STARTED（「通讯录服务尚未
// 接入内核」错误条）。这里在进入主界面前逐项探测内核与关键服务，展示进度与
// 提示；全部就绪后才放行，避免用户看到半成品界面。
//
// 探测失败不中断其余项，全部跑完后汇总；提供「重新检测」与「仍要进入」
// 兜底（内核确实不可用时不让用户死锁在启动页）。
import 'package:material_ui/material_ui.dart';

import '../l10n/l10n.dart';
import '../transport/transport.dart';
import 'core_session.dart';
import 'theme.dart';

/// 单个探测项：label 为 l10n key，probe 抛异常即视为该项未就绪。
class StartupCheckDef {
  const StartupCheckDef({required this.label, required this.probe});

  final String label;
  final Future<void> Function() probe;
}

/// 探测结果。
class StartupCheckResult {
  const StartupCheckResult({
    required this.label,
    required this.ok,
    this.error,
    this.notReady = false,
  });

  final String label;
  final bool ok;
  final Object? error;

  /// 是否为「服务未就绪」(NOT_STARTED)。只有这类失败才阻塞进入主界面；
  /// 其它异常（解析抖动、测试替身空回包等）记录但不拦截。
  final bool notReady;
}

/// 基于真实内核会话构造默认探测项。
///
/// 顺序：内核(bootstrap) → 联系人 → 群聊 → 会话 → 设置。
/// bootstrap 幂等，壳层 _boot() 会再次调用，无副作用。
List<StartupCheckDef> defaultStartupChecks(CoreSession session) =>
    <StartupCheckDef>[
      StartupCheckDef(
        label: '内核服务',
        probe: () async {
          await session.bootstrap();
        },
      ),
      StartupCheckDef(
        label: '联系人服务',
        probe: () async {
          await session.contacts.list();
        },
      ),
      StartupCheckDef(
        label: '群聊服务',
        probe: () async {
          await session.groups.list();
        },
      ),
      StartupCheckDef(
        label: '会话服务',
        probe: () async {
          await session.conversations.list();
        },
      ),
      StartupCheckDef(
        label: '设置服务',
        probe: () async {
          await session.settings.read('startup.check');
        },
      ),
    ];

/// 启动检测门：跑完所有探测后回调 [onReady] 进入主界面。
///
/// [checks] 可注入以替换默认探测（测试用）；[onReport] 便于测试观察进度。
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.session,
    required this.onReady,
    this.checks,
    this.onReport,
  });

  final CoreSession session;
  final VoidCallback onReady;

  /// 测试注入点：为空时用 [defaultStartupChecks]。
  final List<StartupCheckDef>? checks;

  /// 进度回报（测试用），参数为 (已完成数, 总数, 结果列表)。
  final void Function(int, int, List<StartupCheckResult>)? onReport;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  late final List<StartupCheckDef> _checks;
  final List<StartupCheckResult> _results = <StartupCheckResult>[];
  int _current = 0;
  bool _running = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _checks = widget.checks ?? defaultStartupChecks(widget.session);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _run();
      }
    });
  }

  Future<void> _run() async {
    if (_running) {
      return;
    }
    setState(() {
      _running = true;
      _finished = false;
      _results.clear();
      _current = 0;
    });

    for (int i = 0; i < _checks.length; i++) {
      if (!mounted) {
        return;
      }
      final StartupCheckDef check = _checks[i];
      setState(() => _current = i);
      Object? error;
      bool notReady = false;
      try {
        // 单项超时保护：内核卡死时不让启动页无限等待。
        await check.probe().timeout(const Duration(seconds: 12));
      } on NexmemException catch (e) {
        error = e;
        // 只有 NOT_STARTED 代表「服务尚未接入内核」，才真正阻塞进入。
        // 其它契约错误（网络、权限等）交给页面自身处理，不拦截启动。
        notReady = e.code == 'NOT_STARTED';
      } on Object catch (e) {
        error = e;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _results.add(
          StartupCheckResult(
            label: check.label,
            ok: error == null || !notReady,
            error: error,
            notReady: notReady,
          ),
        );
        _current = i + 1;
      });
      widget.onReport?.call(_results.length, _checks.length, _results);
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _running = false;
      _finished = true;
    });
    if (_results.every((StartupCheckResult r) => r.ok)) {
      widget.onReady();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int done = _results.length;
    final int total = _checks.length;
    final bool allOk = _finished && _results.every((StartupCheckResult r) => r.ok);
    // 只有「服务未就绪」才计入阻塞项并展示错误提示。
    final List<StartupCheckResult> failed = _results
        .where((StartupCheckResult r) => r.notReady)
        .toList(growable: false);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexmemMetrics.space24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: NexmemMetrics.space24),
                Text(
                  context.t('正在检查服务'),
                  key: const ValueKey<String>('startup-gate-title'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: NexmemMetrics.space8),
                Text(
                  context.t('已完成 {0}/{1}', [done, total]),
                  key: const ValueKey<String>('startup-gate-progress-text'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: NexmemMetrics.space12),
                LinearProgressIndicator(
                  key: const ValueKey<String>('startup-gate-progress'),
                  value: total == 0 ? null : done / total,
                ),
                const SizedBox(height: NexmemMetrics.space16),
                ..._checks.map((StartupCheckDef check) {
                  final int index = _results.indexWhere(
                    (StartupCheckResult r) => r.label == check.label,
                  );
                  final StartupCheckResult? result =
                      index >= 0 ? _results[index] : null;
                  final bool active = _running && _current == index;
                  final IconData icon;
                  final Color color;
                  if (result != null && result.ok) {
                    icon = Icons.check_circle_outline;
                    color = scheme.primary;
                  } else if (result != null && !result.ok) {
                    icon = Icons.error_outline;
                    color = scheme.error;
                  } else if (active) {
                    icon = Icons.hourglass_top;
                    color = scheme.primary;
                  } else {
                    icon = Icons.radio_button_unchecked;
                    color = scheme.onSurface.withValues(alpha: 0.4);
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: NexmemMetrics.space4,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(icon, size: 18, color: color),
                        const SizedBox(width: NexmemMetrics.space12),
                        Expanded(
                          child: Text(
                            context.t(check.label),
                            style: TextStyle(
                              color: result != null && !result.ok
                                  ? scheme.error
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (_finished && failed.isNotEmpty) ...<Widget>[
                  const SizedBox(height: NexmemMetrics.space16),
                  Text(
                    context.t('部分服务尚未就绪，请检查内核或网络后重试'),
                    key: const ValueKey<String>('startup-gate-error'),
                    style: TextStyle(color: scheme.error, fontSize: 13),
                  ),
                  const SizedBox(height: NexmemMetrics.space16),
                  FilledButton.icon(
                    key: const ValueKey<String>('startup-gate-retry'),
                    onPressed: _running ? null : _run,
                    icon: const Icon(Icons.refresh),
                    label: Text(context.t('重新检测')),
                  ),
                  const SizedBox(height: NexmemMetrics.space8),
                  TextButton(
                    key: const ValueKey<String>('startup-gate-skip'),
                    onPressed: widget.onReady,
                    child: Text(context.t('仍要进入（部分功能可能不可用）')),
                  ),
                ],
                if (allOk) ...<Widget>[
                  const SizedBox(height: NexmemMetrics.space16),
                  Text(
                    context.t('服务已就绪'),
                    key: const ValueKey<String>('startup-gate-ready'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.primary),
                  ),
                ],
                const SizedBox(height: NexmemMetrics.space24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
