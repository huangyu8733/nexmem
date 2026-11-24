/// 在线升级服务统一入口：按平台条件导出 IO 或 Web 实现。
library;

export 'update_model.dart';

export 'update_service_io.dart'
    if (dart.library.html) 'update_service_stub.dart';
