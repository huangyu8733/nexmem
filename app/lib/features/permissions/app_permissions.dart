// 权限中心入口：按编译目标选择原生或浏览器实现。
import 'app_permission_types.dart';
export 'app_permission_types.dart';

import 'app_permissions_io.dart'
    if (dart.library.js_interop) 'app_permissions_web.dart' as impl;

/// 构造当前平台的应用权限入口。
AppPermissions makeAppPermissions() => impl.makeAppPermissions();
