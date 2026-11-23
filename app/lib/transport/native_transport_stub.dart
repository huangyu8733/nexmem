import '../app/core_session.dart';

/// Web 端没有本地 c-shared 内核：Dart 运行时无法加载动态库，
/// 内核由 `nexmem-webd` 在服务端运行，客户端经 WebSocket 接入。
CoreSession? openNativeSession() => null;
