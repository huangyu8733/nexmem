// 本机位置：按编译目标选择宿主定位实现。
import 'local_location_platform_io.dart'
    if (dart.library.js_interop) 'local_location_platform_web.dart' as impl;
import 'local_location_platform_types.dart';

export 'local_location_platform_types.dart';

/// 构造当前平台的系统定位入口。
SystemLocationPlatform makeSystemLocationPlatform() =>
    impl.makeSystemLocationPlatform();
