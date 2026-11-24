import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../transport/transport.dart';

/// 一次 P2P 下载任务的状态。
enum TransferStatus { running, done, failed }

/// 传输列表中的一条任务。
class TransferTask {
  TransferTask({
    required this.shareId,
    required this.name,
    required this.dest,
    this.total = 0,
    this.done = 0,
    this.status = TransferStatus.running,
    this.error,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String shareId;
  final String name;
  final String dest;
  int total;
  int done;
  TransferStatus status;
  String? error;
  final DateTime startedAt;

  double get progress => total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;

  TransferTask copy() => TransferTask(
        shareId: shareId,
        name: name,
        dest: dest,
        total: total,
        done: done,
        status: status,
        error: error,
        startedAt: startedAt,
      );
}

/// 全局 P2P 传输任务表。
///
/// `fs.download` 是一次阻塞式 RPC，进度由内核 `fs.progress` 事件推送；
/// 这里只维护本机 UI 状态，不落库；下载完成后仍可从「已下载」共享里打开文件。
class TransferStore extends ChangeNotifier {
  static final TransferStore instance = TransferStore._internal();

  TransferStore._internal();

  final List<TransferTask> _tasks = <TransferTask>[];
  StreamSubscription<CoreEvent>? _subscription;

  List<TransferTask> get tasks => List<TransferTask>.unmodifiable(
        _tasks.map((TransferTask t) => t.copy()).toList(),
      );

  List<TransferTask> get active => _tasks
      .where((TransferTask t) => t.status == TransferStatus.running)
      .toList();

  bool get attached => _subscription != null;

  /// 订阅内核事件；重复调用不会创建多个订阅。
  void attach(CoreTransport transport) {
    if (_subscription != null) return;
    _subscription = transport.events.listen(_onEvent);
  }

  void detach() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _onEvent(CoreEvent event) {
    if (event.type != 'fs.progress') return;
    final Object? shareId = event.data['share_id'];
    if (shareId is! String) return;
    final int done = (event.data['done'] as num?)?.toInt() ?? 0;
    final int total = (event.data['total'] as num?)?.toInt() ?? 0;
    update(shareId, done: done, total: total);
  }

  /// 登记一个下载任务。
  void start({
    required String shareId,
    required String name,
    required String dest,
    int total = 0,
  }) {
    // 同一 share 只保留最新任务，避免重复下载刷屏。
    _tasks.removeWhere((TransferTask t) => t.shareId == shareId);
    _tasks.insert(
      0,
      TransferTask(
        shareId: shareId,
        name: name,
        dest: dest,
        total: total,
      ),
    );
    notifyListeners();
  }

  void update(String shareId, {int? done, int? total, int? statusCode}) {
    bool changed = false;
    for (final TransferTask task in _tasks) {
      if (task.shareId != shareId) continue;
      if (done != null) task.done = done;
      if (total != null && total > 0) task.total = total;
      if (statusCode == 1 && task.done >= task.total && task.total > 0) {
        task.status = TransferStatus.done;
      }
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void finish(String shareId) {
    bool changed = false;
    for (final TransferTask task in _tasks) {
      if (task.shareId != shareId) continue;
      task.status = TransferStatus.done;
      if (task.total > 0) task.done = task.total;
      task.error = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void fail(String shareId, String message) {
    bool changed = false;
    for (final TransferTask task in _tasks) {
      if (task.shareId != shareId) continue;
      task.status = TransferStatus.failed;
      task.error = message;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// 从列表移除单条任务（不取消内核侧下载）。
  void remove(String shareId) {
    final int before = _tasks.length;
    _tasks.removeWhere((TransferTask t) => t.shareId == shareId);
    if (_tasks.length != before) {
      notifyListeners();
    }
  }

  /// 清空全部传输记录（不取消进行中的下载）。
  void clearAll() {
    if (_tasks.isEmpty) return;
    _tasks.clear();
    notifyListeners();
  }

  /// 只清理已完成任务；失败任务保留，方便用户查看原因。
  void clearFinished() {
    _tasks.removeWhere((TransferTask t) => t.status == TransferStatus.done);
    notifyListeners();
  }
}
