import 'package:web/web.dart' as web;

/// `localStorage` 键：Web 端「仅在线接收」提示是否已展示。
const String _key = 'nexmem.web.online_notice_seen';

bool loadSeen() => web.window.localStorage.getItem(_key) == '1';

void saveSeen() => web.window.localStorage.setItem(_key, '1');
