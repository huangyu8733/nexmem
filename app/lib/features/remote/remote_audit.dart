// 远控审计：仅记录会话元数据与授权项，不记录按键内容或剪贴板正文。
import 'dart:convert';

import 'remote_session.dart';
import 'remote_storage.dart';

class RemoteAuditEntry {
  const RemoteAuditEntry({
    required this.timeMs,
    required this.peer,
    required this.direction,
    required this.permissions,
    required this.action,
    this.durationMs = 0,
    this.reason = '',
  });

  final int timeMs;
  final String peer;

  /// controller / host。
  final String direction;
  final RemotePermissions permissions;
  final String action;
  final int durationMs;
  final String reason;

  factory RemoteAuditEntry.fromJson(Map<String, dynamic> json) =>
      RemoteAuditEntry(
        timeMs: (json['ts'] as num?)?.toInt() ?? 0,
        peer: '${json['peer'] ?? ''}',
        direction: '${json['dir'] ?? ''}',
        permissions: RemotePermissions.fromJson(json),
        action: '${json['action'] ?? ''}',
        durationMs: (json['duration'] as num?)?.toInt() ?? 0,
        reason: '${json['reason'] ?? ''}',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': timeMs,
        'peer': peer,
        'dir': direction,
        ...permissions.toJson(),
        'action': action,
        'duration': durationMs,
        if (reason.isNotEmpty) 'reason': reason,
      };
}

class RemoteAudit {
  RemoteAudit(this._storage);

  static const String _fileName = 'audit.jsonl';
  static const int _maxInMemory = 200;

  final RemoteStorage _storage;
  final List<RemoteAuditEntry> entries = <RemoteAuditEntry>[];

  Future<void> load() async {
    final List<String> lines = await _storage.readLines(_fileName);
    final List<RemoteAuditEntry> loaded = <RemoteAuditEntry>[];
    for (final String line in lines) {
      try {
        final Object? json = jsonDecode(line);
        if (json is Map<String, dynamic>) {
          loaded.add(RemoteAuditEntry.fromJson(json));
        }
      } on Object {
        // 跳过损坏行。
      }
    }
    entries
      ..clear()
      ..addAll(loaded.length <= _maxInMemory
          ? loaded
          : loaded.sublist(loaded.length - _maxInMemory));
  }

  Future<void> add(RemoteAuditEntry entry) async {
    entries.add(entry);
    if (entries.length > _maxInMemory) {
      entries.removeAt(0);
    }
    await _storage.appendLine(_fileName, jsonEncode(entry.toJson()));
  }

  Future<void> clear() async {
    entries.clear();
    await _storage.clear(_fileName);
  }
}
