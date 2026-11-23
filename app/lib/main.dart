import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'app/core_session.dart';
import 'transport/android_transport.dart';
import 'transport/ios_transport.dart';
import 'transport/native_transport_stub.dart'
    if (dart.library.io) 'transport/native_transport.dart';
import 'transport/ws_transport.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final CoreSession? session = await _sessionFromEnvironment();
  runApp(NexmemApp(session: session));
}

/// 按平台建立内核会话（P1-07 / P1-16 / P1-20）。
///
/// Android 经 `io.nexmem/core` MethodChannel 调用 gomobile 内核，数据目录取
/// `Context.filesDir`；桌面端直接经 `dart:ffi` 加载 c-shared 内核（P1-09），
/// 并在 `account.me` 返回 `NOT_STARTED` 时用 [nativeStartConfig] 启动；Web 端由
/// `nexmem-webd` 托管内核，客户端经 WebSocket 接入，优先读编译期
/// `--dart-define=NEXMEM_WEB_URL/NEXMEM_WEB_TOKEN`，其次读页面查询参数
/// `?core=ws://.../ws&token=...`。均不可用时返回 null，应用以离线空态启动。
Future<CoreSession?> _sessionFromEnvironment() async {
  if (!kIsWeb) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final CoreSession? android = await openAndroidSession();
      if (android != null) {
        return android;
      }
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final CoreSession? ios = await openIOSSession();
      if (ios != null) {
        return ios;
      }
    } else {
      final CoreSession? native = openNativeSession();
      if (native != null) {
        return native;
      }
    }
  }
  const String builtUrl = String.fromEnvironment('NEXMEM_WEB_URL');
  const String builtToken = String.fromEnvironment('NEXMEM_WEB_TOKEN');
  String? url = builtUrl.isEmpty ? null : builtUrl;
  String? token = builtToken.isEmpty ? null : builtToken;
  if (kIsWeb) {
    final Map<String, String> query = Uri.base.queryParameters;
    url ??= query['core'];
    token ??= query['token'];
    if (url == null && token != null) {
      final Uri base = Uri.base;
      final String scheme = base.scheme == 'https' ? 'wss' : 'ws';
      url = '$scheme://${base.authority}/ws';
    }
  }
  if (url == null || token == null) {
    return null;
  }
  final WsTransport transport = WsTransport(
    endpoint: Uri.parse(url),
    token: token,
  );
  unawaited(transport.connect().catchError((Object _) {}));
  return CoreSession(transport);
}
