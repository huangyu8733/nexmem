// 远控本机偏好：不随设置备份同步，避免把「允许被控」带到其他设备。
import 'remote_session.dart';
import 'remote_storage.dart';

class RemotePrefs {
  RemotePrefs._();

  static final RemotePrefs instance = RemotePrefs._();
  static const String _fileName = 'prefs.json';

  bool enabled = true;
  bool requireConfirm = true;
  bool allowInput = true;
  bool allowClipboard = true;
  bool allowFile = true;
  int idleMinutes = 15;
  RemoteQuality quality = RemoteQuality.balanced;
  bool loaded = false;

  RemotePermissions get allowed => RemotePermissions(
        input: allowInput,
        clipboard: allowClipboard,
        file: allowFile,
      );

  Future<void> load(RemoteStorage storage) async {
    if (loaded) {
      return;
    }
    final Map<String, dynamic>? json = await storage.readJson(_fileName);
    if (json != null) {
      enabled = json['enabled'] != false;
      requireConfirm = json['require_confirm'] != false;
      allowInput = json['allow_input'] != false;
      allowClipboard = json['allow_clipboard'] != false;
      allowFile = json['allow_file'] != false;
      idleMinutes = (json['idle_minutes'] as num?)?.toInt() ?? 15;
      quality = RemoteQuality.values.firstWhere(
        (RemoteQuality q) => q.name == json['quality'],
        orElse: () => RemoteQuality.balanced,
      );
    }
    loaded = true;
  }

  Future<void> save(RemoteStorage storage) => storage.writeJson(_fileName, <String, dynamic>{
        'enabled': enabled,
        'require_confirm': requireConfirm,
        'allow_input': allowInput,
        'allow_clipboard': allowClipboard,
        'allow_file': allowFile,
        'idle_minutes': idleMinutes,
        'quality': quality.name,
      });
}
