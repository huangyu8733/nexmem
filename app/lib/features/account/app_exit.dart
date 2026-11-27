import 'app_exit_stub.dart'
    if (dart.library.io) 'app_exit_native.dart'
    if (dart.library.js_interop) 'app_exit_web.dart'
    as impl;

/// 退出应用进程。Web 端浏览器不允许脚本关闭非脚本打开的标签页，
/// 因此由界面展示退出页；原生端按平台请求关闭窗口/退出进程。
Future<void> exitProcess() => impl.exitProcess();
