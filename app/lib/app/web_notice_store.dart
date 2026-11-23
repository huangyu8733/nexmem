import 'web_notice_store_stub.dart'
    if (dart.library.js_interop) 'web_notice_store_web.dart'
    as impl;

/// Web 端「仅在线接收」提示的首次展示标记（ui-spec.md §5 / §7）。
///
/// Web 端由浏览器承载 UI，关闭标签页后没有实时通道，因此首次进入时给出一条
/// 可关闭的说明。标记在 Web 端落 `localStorage`，非 Web 端恒为未读且不落盘。
class WebNoticeStore {
  const WebNoticeStore();

  /// 是否已经展示过（Web 端刷新后不再重复弹出）。
  bool get seen => impl.loadSeen();

  /// 记录已展示。
  void markSeen() => impl.saveSeen();
}
