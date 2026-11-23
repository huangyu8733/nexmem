import 'package:material_ui/material_ui.dart';

import '../../transport/transport.dart';
import 'diagnostics.dart';

/// 举报原因（ui-spec.md §3 聊天页更多菜单「举报」）。
enum ReportReason {
  harassment('骚扰辱骂'),
  spam('垃圾广告'),
  fraud('诈骗欺诈'),
  porn('色情低俗'),
  other('其他');

  const ReportReason(this.label);

  final String label;
}

/// 一次举报请求；`conversationId` 为空表示从设置页发起的通用举报。
class ReportRequest {
  const ReportRequest({
    required this.reason,
    this.conversationId,
    this.detail = '',
    this.diagnostics,
  });

  final ReportReason reason;
  final String? conversationId;
  final String detail;

  /// 附带诊断包的绝对路径；为空表示未附带。
  final String? diagnostics;
}

/// 举报上报通道：由 `core.start` 接入内核后注入，未接入时明确失败。
abstract class ReportSink {
  Future<void> submit(ReportRequest request);
}

/// 占位实现：当前阶段未接入上报服务，UI 据此提示稍后再试。
class UnavailableReportSink implements ReportSink {
  const UnavailableReportSink();

  @override
  Future<void> submit(ReportRequest request) async {
    throw const NexmemException('NOT_STARTED', '举报上报服务尚未接入');
  }
}

/// 走内核 `report.submit` 的上报通道（P6-06）：
/// 原因、补充说明与脱敏诊断包路径一并交给 Go 内核，再由内核转发索引服务。
class TransportReportSink implements ReportSink {
  TransportReportSink(
    this.transport, {
    this.timeout = const Duration(seconds: 20),
    this.clientVersion = 'nexmem-app',
  });

  final CoreTransport transport;
  final Duration timeout;
  final String clientVersion;

  @override
  Future<void> submit(ReportRequest request) async {
    final Map<String, dynamic> params = <String, dynamic>{
      'reason': request.reason.name,
      'client_version': clientVersion,
    };
    final String? conversationId = request.conversationId;
    if (conversationId != null && conversationId.isNotEmpty) {
      params['conversation_id'] = conversationId;
    }
    if (request.detail.isNotEmpty) {
      params['detail'] = request.detail;
    }
    final String? diagnostics = request.diagnostics;
    if (diagnostics != null && diagnostics.isNotEmpty) {
      params['diagnostics_path'] = diagnostics;
    }
    await transport.call('report.submit', params: params, timeout: timeout);
  }
}

/// 举报表单：选择原因、补充说明，可选附带脱敏诊断包。
///
/// 提交成功以 `Navigator.pop(true)` 返回，由调用方提示结果；
/// 提交失败保留在弹窗内展示错误，避免用户输入丢失。
class ReportDialog extends StatefulWidget {
  const ReportDialog({
    super.key,
    this.conversationId,
    this.reportSink = const UnavailableReportSink(),
    this.diagnostics = const UnavailableDiagnosticsService(),
  });

  /// 被举报的会话 ID；为空表示通用举报。
  final String? conversationId;

  final ReportSink reportSink;
  final DiagnosticsService diagnostics;

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  final TextEditingController _detail = TextEditingController();
  ReportReason? _reason;
  bool _attachDiagnostics = true;
  bool _submitting = false;
  String? _error;
  String? _diagnosticsNote;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ReportReason? reason = _reason;
    if (reason == null) {
      setState(() => _error = '请选择举报原因');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _diagnosticsNote = null;
    });

    String? diagnosticsPath;
    if (_attachDiagnostics) {
      try {
        diagnosticsPath = await widget.diagnostics.exportBundle();
      } on NexmemException catch (e) {
        // 诊断包不影响举报本身：失败时提交不带诊断信息。
        diagnosticsPath = null;
        _diagnosticsNote = '诊断日志未附带（${e.code}）';
      }
    }

    try {
      await widget.reportSink.submit(
        ReportRequest(
          reason: reason,
          conversationId: widget.conversationId,
          detail: _detail.text.trim(),
          diagnostics: diagnosticsPath,
        ),
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on NexmemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitting = false;
        _error = e.code == 'NOT_STARTED'
            ? '举报上报服务尚未接入，请稍后再试'
            : '举报提交失败（${e.code}），请稍后再试';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitting = false;
        _error = '举报提交失败，请稍后再试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('举报'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('举报原因', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final ReportReason reason in ReportReason.values)
                    ChoiceChip(
                      key: ValueKey<String>('report-reason-${reason.name}'),
                      label: Text(reason.label),
                      selected: _reason == reason,
                      onSelected: (_) => setState(() => _reason = reason),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('report-detail-field'),
                controller: _detail,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(
                  hintText: '补充说明（选填）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              CheckboxListTile(
                key: const ValueKey<String>('report-attach-diagnostics'),
                value: _attachDiagnostics,
                onChanged: (bool? value) =>
                    setState(() => _attachDiagnostics = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('附带脱敏诊断日志'),
                subtitle: const Text('不含聊天正文与密钥'),
              ),
              if (_diagnosticsNote != null)
                Text(
                  _diagnosticsNote!,
                  style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6)),
                ),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey<String>('report-error'),
                  style: TextStyle(color: scheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('report-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('提交'),
        ),
      ],
    );
  }
}
