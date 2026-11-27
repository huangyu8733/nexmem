import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../app/core_session.dart';
import 'account_data_dir_probe.dart'
    if (dart.library.io) 'account_data_dir_probe_io.dart' as data_dir_probe;
import 'account_local_store.dart';
import 'account_profile.dart';

/// 本机账号与临时锁的统一状态。
///
/// 多账号通过「一个账号一个数据目录」实现：切换时停内核、换 `data_dir`
/// 重启再读 `account.me`。锁屏同样会停内核，解锁后重启当前账号。
class AccountManager extends ChangeNotifier {
  AccountManager({
    required this.session,
    AccountLocalStore? store,
    DateTime Function()? clock,
    Future<bool> Function(String path)? dataDirExists,
  })  : _store = store ?? const AccountLocalStore(),
        _clock = clock ?? DateTime.now,
        _dataDirExists = dataDirExists ?? data_dir_probe.accountDataDirExists,
        _lastActivity = (clock ?? DateTime.now)() {
    // 首帧即可进入主界面：默认档案同步构造，本地档案在 initialize 中异步合并，
    // 避免平台存储初始化拖慢启动或让 Widget 测试停在加载页。
    final Object? configured = session?.activeStartConfig?['data_dir'] ??
        session?.startConfig?['data_dir'];
    _state = AccountSessionState(
      activeId: 'default',
      profiles: <AccountProfile>[
        AccountProfile(
          id: 'default',
          label: '默认账号',
          dataDir: configured is String ? configured.trim() : '',
          accountId: session?.accountId ?? '',
          createdAt: _clock().millisecondsSinceEpoch,
        ),
      ],
    );
  }

  final CoreSession? session;
  final AccountLocalStore _store;
  final DateTime Function() _clock;
  final Future<bool> Function(String path) _dataDirExists;

  AccountSessionState _state = const AccountSessionState();
  final bool _initialized = true;
  bool _locked = false;
  bool _exited = false;
  int _generation = 0;
  DateTime _lastActivity;
  Timer? _idleTimer;

  AccountSessionState get state => _state;
  List<AccountProfile> get profiles => List<AccountProfile>.unmodifiable(
        _state.profiles,
      );
  String? get activeId =>
      _state.activeId.isEmpty ? null : _state.activeId;
  AccountProfile? get active => _state.profile(_state.activeId);
  LockSettings get lockSettings => _state.lock;
  bool get locked => _locked;
  bool get exited => _exited;
  bool get initialized => _initialized;

  /// 账号/锁定状态每次变化后递增：外层据此重建 AppShell，
  /// 避免切换账号后残留旧会话、聊天草稿与远控状态。
  int get generation => _generation;

  /// 合并本地档案并启动自动锁计时；默认档案已在构造函数中同步就绪。
  Future<void> initialize() async {
    _lastActivity = _clock();
    _idleTimer ??= Timer.periodic(const Duration(seconds: 10), _checkIdle);
    final Map<String, dynamic>? raw = await _store.read();
    if (raw != null) {
      final AccountSessionState loaded = AccountSessionState.fromJson(raw);
      if (loaded.profiles.isNotEmpty) {
        _state = loaded.profile(loaded.activeId) == null
            ? loaded.copyWith(activeId: loaded.profiles.first.id)
            : loaded;
        _generation++;
        notifyListeners();
      }
    }
    await _rebaseStaleMobileDataDirs();
    await _restoreActiveDataDir();
    unawaited(_persist());
  }

  /// 移动端重装/从备份恢复后，沙盒容器 UUID 会变化，`account_session.json`
  /// 里保存的绝对路径可能指向已失效的旧容器。内核用旧目录启动时 Identity
  /// 可从 Keychain 恢复，但数据库无法打开，表现为联系人/群聊/会话/设置
  /// 服务探测失败。这里把失效目录重定位到平台当前数据目录。
  ///
  /// 桌面端可能存在用户指定的合法外部目录，默认不做重定位；只有移动端
  /// 会话显式打开 [CoreSession.rebaseStaleDataDir] 才启用。
  Future<void> _rebaseStaleMobileDataDirs() async {
    final CoreSession? session = this.session;
    if (session == null || !session.rebaseStaleDataDir) {
      return;
    }
    final Object? configured = session.startConfig?['data_dir'];
    if (configured is! String || configured.trim().isEmpty) {
      return;
    }
    final String currentDefault = configured.trim();
    bool changed = false;
    final List<AccountProfile> rebased = <AccountProfile>[];
    for (final AccountProfile profile in _state.profiles) {
      final String dir = profile.dataDir;
      if (dir.isEmpty ||
          dir == currentDefault ||
          await _dataDirExists(dir)) {
        rebased.add(profile);
        continue;
      }
      final String? replacement = _rebaseProfileDir(
        profile: profile,
        oldDir: dir,
        currentDefault: currentDefault,
      );
      if (replacement == null || replacement == dir) {
        rebased.add(profile);
        continue;
      }
      rebased.add(profile.copyWith(dataDir: replacement));
      changed = true;
    }
    if (!changed) {
      return;
    }
    _state = _state.copyWith(profiles: rebased);
    await _persist();
    notifyListeners();
  }

  /// 默认档案直接回到平台数据目录；「添加账号」档案保留 `profiles/<id>`
  /// 相对结构，仅替换沙盒根目录，避免把 A 账号的数据误指向 B 账号。
  String? _rebaseProfileDir({
    required AccountProfile profile,
    required String oldDir,
    required String currentDefault,
  }) {
    if (profile.isDefault) {
      return currentDefault;
    }
    final List<String> segments = oldDir
        .replaceAll(r'\', '/')
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2 ||
        segments[segments.length - 2] != 'profiles' ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(segments.last)) {
      return null;
    }
    final String current = currentDefault.replaceAll(r'\', '/');
    final String parent = p.posix.dirname(current);
    if (parent.isEmpty || parent == '.' || parent == current) {
      return null;
    }
    return p.posix.join(parent, 'profiles', segments.last);
  }

  /// 启动时按上次活跃档案的数据目录重启内核。
  ///
  /// 平台入口只知道默认启动目录；若上次退出前切到了别的账号，必须在
  /// `bootstrap()` 之前把内核切回该档案，否则界面显示 A 账号、数据却落在 B。
  Future<void> _restoreActiveDataDir() async {
    final Map<String, dynamic>? config = await startupConfigForActive();
    final CoreSession? session = this.session;
    if (config == null || session == null) {
      return;
    }
    // 内核可能已由平台入口启动：这种情形必须停机换目录。
    // 尚未启动时保留给 shell 的 bootstrap(startConfig:) 使用，避免对
    // 未启动内核调用 core.stop。
    final String? current = await session.currentDataDir();
    if (current == null || current.isEmpty) {
      return;
    }
    try {
      await session.restartWithConfig(config);
      _generation++;
      notifyListeners();
    } on Object {
      // 切换失败不阻塞进入应用，界面仍可手动切换账号。
    }
  }

  /// 启动时若活跃档案的目录与平台默认目录不同，返回该档案的启动配置。
  Future<Map<String, dynamic>?> startupConfigForActive() async {
    final CoreSession? session = this.session;
    final AccountProfile? profile = active;
    if (session == null || profile == null || profile.dataDir.isEmpty) {
      return null;
    }
    final Object? configured = session.activeStartConfig?['data_dir'] ??
        session.startConfig?['data_dir'];
    if (configured is String &&
        configured.trim().isNotEmpty &&
        configured.trim() == profile.dataDir) {
      return null;
    }
    return _configFor(profile);
  }

  /// 内核就绪后回填账号 ID 与数据目录，供下次切换使用。
  Future<void> syncCurrentAccount() async {
    final CoreSession? session = this.session;
    final CoreAccount? account = session?.account;
    if (session == null || account == null || _locked) {
      return;
    }
    final AccountProfile? current = active;
    if (current == null) {
      return;
    }
    final String dir = current.dataDir.isNotEmpty
        ? current.dataDir
        : await _currentDataDir();
    if (current.accountId == account.accountId && current.dataDir == dir) {
      return;
    }
    // 内核账号与档案记录不一致时不能盲目覆盖：这通常意味着启动目录恢复
    // 失败，覆盖会把 A 账号的身份写进 B 账号档案。只补空值。
    final String accountId = current.accountId.isEmpty
        ? account.accountId
        : current.accountId;
    final String dataDir = current.dataDir.isEmpty ? dir : current.dataDir;
    if (accountId == current.accountId && dataDir == current.dataDir) {
      return;
    }
    _replaceProfile(
      current.copyWith(accountId: accountId, dataDir: dataDir),
    );
    await _persist();
    notifyListeners();
  }

  /// 新增一个本地账号档案；数据目录为当前目录同级的 `profiles/<id>`。
  Future<AccountProfile> addAccount({required String label}) async {
    final String id = _newProfileId();
    final String dir = await _nextDataDir(id);
    final int now = _clock().millisecondsSinceEpoch;
    final AccountProfile profile = AccountProfile(
      id: id,
      label: label.trim().isEmpty ? '新账号' : label.trim(),
      dataDir: dir,
      managed: true,
      createdAt: now,
      lastUsedAt: now,
    );
    _state = _state.copyWith(
      profiles: <AccountProfile>[..._state.profiles, profile],
    );
    await _persist();
    notifyListeners();
    return profile;
  }

  /// 切换账号；失败时尝试恢复到原账号，避免内核停在未知状态。
  Future<void> switchAccount(String id) async {
    final AccountProfile? target = _state.profile(id);
    if (target == null || _locked || _exited) {
      return;
    }
    if (_state.activeId == id) {
      return;
    }
    await _captureActiveDataDir();
    final Map<String, dynamic> config = await _configFor(target);
    final Object? dir = config['data_dir'];
    if (dir is! String || dir.isEmpty) {
      throw StateError('账号数据目录未知，无法切换');
    }
    final CoreSession? session = this.session;
    if (session != null) {
      try {
        await session.restartWithConfig(config);
      } on Object {
        await _restorePreviousAccount();
        rethrow;
      }
    }
    final int now = _clock().millisecondsSinceEpoch;
    final AccountProfile updated = target.copyWith(
      accountId: session?.accountId ?? target.accountId,
      lastUsedAt: now,
    );
    _replaceProfile(updated);
    _state = _state.copyWith(activeId: id);
    _generation++;
    _lastActivity = _clock();
    await _persist();
    notifyListeners();
  }

  Future<void> _restorePreviousAccount() async {
    final CoreSession? session = this.session;
    final AccountProfile? previous = active;
    if (session == null || previous == null) {
      return;
    }
    try {
      await session.restartWithConfig(await _configFor(previous));
    } on Object {
      // 恢复失败时不覆盖原始错误，由界面提示用户重试。
    }
  }

  /// 重命名账号档案（不影响内核里的昵称）。
  Future<void> renameAccount(String id, String label) async {
    final AccountProfile? profile = _state.profile(id);
    final String name = label.trim();
    if (profile == null || name.isEmpty) {
      return;
    }
    _replaceProfile(profile.copyWith(label: name));
    await _persist();
    notifyListeners();
  }

  /// 删除账号档案。当前账号需先退出登录；默认账号不可删除。
  Future<void> deleteAccount(
    String id, {
    bool deleteData = false,
  }) async {
    final AccountProfile? profile = _state.profile(id);
    if (profile == null || profile.isDefault || id == _state.activeId) {
      return;
    }
    if (deleteData && profile.managed && profile.dataDir.isNotEmpty) {
      await _store.deleteAccountData(profile.dataDir, profile.id);
    }
    _state = _state.copyWith(
      profiles: _state.profiles
          .where((AccountProfile item) => item.id != id)
          .toList(growable: false),
    );
    await _persist();
    notifyListeners();
  }

  /// 退出登录：停内核并回到账号选择页，档案仍保留。
  Future<void> logout() async {
    try {
      await session?.stop();
    } on Object {
      // 本地退出仍生效；内核异常不应把用户困在已登录界面。
    }
    _state = _state.copyWith(activeId: '');
    _generation++;
    _lastActivity = _clock();
    await _persist();
    notifyListeners();
  }

  /// 退出应用：Web 端由界面展示退出页，原生端请求关闭窗口。
  Future<void> exitApp() async {
    if (_exited) {
      return;
    }
    await logout();
    _exited = true;
    _generation++;
    notifyListeners();
  }

  /// 清除 Web 端退出标记（退出页上的「重新进入」）。
  void cancelExit() {
    if (!_exited) {
      return;
    }
    _exited = false;
    _generation++;
    notifyListeners();
  }

  /// 立即锁定：必须先设置 PIN。锁定时停内核，解锁后重启当前账号。
  Future<bool> lockNow() async {
    if (_locked || !_state.lock.hasPin) {
      return false;
    }
    _lastActivity = _clock();
    await _captureActiveDataDir();
    try {
      await session?.stop();
    } on Object {
      // 即便内核停止失败，界面仍进入锁定态，避免隐私暴露。
    }
    _locked = true;
    _generation++;
    notifyListeners();
    return true;
  }

  /// 校验 PIN 并解锁；内核重启失败时保持锁定并把错误抛给界面。
  Future<bool> unlock(String pin) async {
    if (!_locked || !_state.lock.hasPin) {
      return false;
    }
    if (!verifyPin(pin, _state.lock.pinHash)) {
      return false;
    }
    await _captureActiveDataDir();
    final CoreSession? session = this.session;
    final AccountProfile? current = active;
    if (session != null && current != null) {
      await session.restartWithConfig(await _configFor(current));
    }
    _locked = false;
    _lastActivity = _clock();
    _generation++;
    notifyListeners();
    return true;
  }

  /// 忘记 PIN：清除本地锁并退出登录，不触碰任何账号数据。
  Future<void> resetPinAndLogout() async {
    _state = _state.copyWith(lock: const LockSettings());
    await _persist();
    await logout();
    _locked = false;
    _generation++;
    notifyListeners();
  }

  Future<void> setPin(String pin) async {
    final String salt = newPinSalt();
    _state = _state.copyWith(
      lock: _state.lock.copyWith(
        enabled: true,
        salt: salt,
        pinHash: hashPin(pin, salt),
      ),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> clearPin() async {
    if (_locked) {
      return;
    }
    _state = _state.copyWith(
      lock: const LockSettings(),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> setAutoLockMinutes(int minutes) async {
    final int value = minutes < 0 ? 0 : minutes;
    _state = _state.copyWith(
      lock: _state.lock.copyWith(
        enabled: value > 0 || _state.lock.hasPin,
        autoLockMinutes: value,
      ),
    );
    await _persist();
    notifyListeners();
  }

  /// 键盘/触摸活动：重置自动锁倒计时。
  void recordActivity() {
    _lastActivity = _clock();
  }

  void _checkIdle(Timer _) {
    if (_locked || _exited || !_state.lock.enabled) {
      return;
    }
    final int minutes = _state.lock.autoLockMinutes;
    if (minutes <= 0 || activeId == null) {
      return;
    }
    if (_clock().difference(_lastActivity).inMinutes >= minutes) {
      unawaited(lockNow());
    }
  }

  Future<void> _persist() async {
    try {
      await _store.write(_state.toJson());
    } on Object {
      // 存储不可用时保持内存状态，界面仍可继续操作。
    }
  }

  void _replaceProfile(AccountProfile profile) {
    _state = _state.copyWith(
      profiles: _state.profiles
          .map((AccountProfile item) => item.id == profile.id ? profile : item)
          .toList(growable: false),
    );
  }

  Future<String> _currentDataDir() async {
    final AccountProfile? current = active;
    if (current != null && current.dataDir.isNotEmpty) {
      return current.dataDir;
    }
    final String? dir = await session?.currentDataDir();
    if (dir != null && dir.isNotEmpty) {
      return dir;
    }
    final Object? configured = session?.activeStartConfig?['data_dir'] ??
        session?.startConfig?['data_dir'];
    return configured is String ? configured.trim() : '';
  }

  Future<void> _captureActiveDataDir() async {
    final AccountProfile? current = active;
    if (current == null || current.dataDir.isNotEmpty) {
      return;
    }
    final String dir = await _currentDataDir();
    if (dir.isNotEmpty) {
      _replaceProfile(current.copyWith(dataDir: dir));
      await _persist();
    }
  }

  Future<Map<String, dynamic>> _configFor(AccountProfile profile) async {
    // 当前生效配置优先于初始配置，否则切换账号后的网络设置会被初始目录覆盖。
    final Map<String, dynamic> config = <String, dynamic>{
      ...?session?.startConfig,
      ...?session?.activeStartConfig,
    };
    final String dir = profile.dataDir.isNotEmpty
        ? profile.dataDir
        : await _currentDataDir();
    if (dir.isNotEmpty) {
      config['data_dir'] = dir;
    }
    return config;
  }

  Future<String> _nextDataDir(String id) async {
    final String current = await _currentDataDir();
    if (current.isEmpty) {
      // Web 自托管服务未暴露数据目录时，使用服务端工作目录下的相对路径。
      return 'profiles/$id';
    }
    final String normalized = current.replaceAll(r'\', '/');
    final List<String> segments = normalized
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      return 'profiles/$id';
    }
    segments.removeLast();
    final String base = segments.isEmpty ? '' : '${segments.join('/')}/';
    return '${base}profiles/$id';
  }

  String _newProfileId() {
    final int suffix = Random.secure().nextInt(1 << 31);
    return 'p-${_clock().microsecondsSinceEpoch.toRadixString(36)}-'
        '${suffix.toRadixString(36)}';
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }
}
