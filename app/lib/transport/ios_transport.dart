import 'package:flutter/foundation.dart';

import '../app/core_session.dart';
import '../features/chat/voice_recorder.dart';
import '../features/files/chat_file_actions.dart';
import '../features/files/folder_attachment.dart';
import 'android_transport.dart';

/// iOS 端传输实现（P1-08）。
///
/// 与 Android 共用 `io.nexmem/core` MethodChannel 契约：Swift 插件
/// 把请求信封交给 gomobile 内核，事件按 seq 写入原生 `EventBuffer` 后
/// 反向推给 Dart。区别仅在数据目录（应用沙盒 Application Support）与
/// 无前台服务，因此复用 [AndroidTransport] 的信封/事件逻辑。
class IOSTransport extends AndroidTransport {
  IOSTransport({super.channel, super.requestTimeout, super.eventBufferSize})
    : super(platformLabel: 'iOS');
}

/// iOS 启动入口（P1-08）：建立 MethodChannel 会话并注入 `core.start` 配置。
///
/// 数据目录由 Swift 插件创建在应用沙盒内；插件缺失或目录不可用时返回 null，
/// 应用以离线空态启动。
Future<CoreSession?> openIOSSession() async {
  final IOSTransport transport = IOSTransport();
  try {
    await transport.connect();
  } on Object catch (error) {
    debugPrint('Nexmem iOS 内核事件通道连接失败（$error）');
    return null;
  }
  final String? dataDir = await transport.appDataDir();
  if (dataDir == null || dataDir.isEmpty) {
    debugPrint('Nexmem iOS 内核数据目录不可用');
    await transport.close();
    return null;
  }
  // 注入原生局域网 IP，启用同 WiFi 账号发现（UDP 广播签名名片）。
  final String? localIp = await transport.localIp();
  // iOS 禁止向 255.255.255.255 受限广播发送（sendto: no route to host），
  // 需注入 en0 的子网定向广播地址，否则 LAN Beacon 只收不发。
  final String? broadcastIp = await transport.lanBroadcastAddr();
  final Map<String, dynamic> config = <String, dynamic>{'data_dir': dataDir};
  if (localIp != null && localIp.isNotEmpty) {
    config['lan_addrs'] = <String>[localIp];
  }
  if (broadcastIp != null && broadcastIp.isNotEmpty) {
    config['lan_broadcast_addr'] = broadcastIp;
  }
  return CoreSession(
    transport,
    startConfig: config,
    // iOS 重装/备份恢复会改变沙盒容器 UUID，需重定位失效的数据目录。
    rebaseStaleDataDir: true,
    pickFile: transport.pickFile,
    pickImage: transport.pickImage,
    pickMedia: transport.pickMedia,
    pickVideo: transport.pickVideo,
    pickAudio: transport.pickAudio,
    voiceRecorder: makeVoiceRecorder(),
    pickDirectory: transport.pickDirectory,
    pickFolder: () =>
        pickFolderAttachment(directoryPicker: transport.pickDirectory),
    readChatFileBytes: (String path) =>
        readChatFileBytes(path: path),
    saveChatFile: (String path, String fileName) =>
        saveChatFileToDevice(sourcePath: path, fileName: fileName),
  );
}
