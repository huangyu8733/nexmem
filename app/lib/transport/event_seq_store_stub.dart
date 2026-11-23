import 'event_buffer.dart';

/// 非 Web 环境的占位实现：水位持久化由原生环形缓冲负责，这里不需要额外存储。
EventSeqStore? createBrowserEventSeqStore() => null;
