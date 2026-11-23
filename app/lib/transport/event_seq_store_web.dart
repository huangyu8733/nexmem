import 'package:web/web.dart' as web;

import 'event_buffer.dart';

/// Web 端水位存储：页面刷新后从 `localStorage` 恢复 `lastSeq`，
/// 重连时作为 `since` 让网关从事件环形缓冲补齐。
EventSeqStore? createBrowserEventSeqStore() =>
    _LocalStorageEventSeqStore(web.window.localStorage);

class _LocalStorageEventSeqStore implements EventSeqStore {
  _LocalStorageEventSeqStore(this._storage);

  static const String _key = 'nexmem.event.last_seq';

  final web.Storage _storage;

  @override
  int? load() {
    final String? raw = _storage.getItem(_key);
    if (raw == null) {
      return null;
    }
    return int.tryParse(raw);
  }

  @override
  void save(int seq) {
    _storage.setItem(_key, '$seq');
  }

  @override
  void clear() {
    _storage.removeItem(_key);
  }
}
