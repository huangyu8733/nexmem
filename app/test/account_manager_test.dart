import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/account/account_local_store.dart';
import 'package:nexmem_app/features/account/account_manager.dart';
import 'package:nexmem_app/features/account/account_profile.dart';
import 'package:nexmem_app/transport/transport.dart';

/// 记录 core.stop / core.start 的最小内核替身；每个 data_dir 对应一个账号。
class _SwitchTransport implements CoreTransport {
  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int lastSeq = 0;

  String dataDir = '/tmp/nexmem/data';
  bool started = true;
  final List<String> calls = <String>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    calls.add(method);
    switch (method) {
      case 'core.dataDir':
        if (!started) {
          throw const NexmemException('NOT_STARTED', '内核尚未启动');
        }
        return <String, dynamic>{'data_dir': dataDir};
      case 'core.stop':
        started = false;
        return <String, dynamic>{};
      case 'core.start':
        final Object? dir = params?['config']?['data_dir'];
        dataDir = dir is String && dir.isNotEmpty ? dir : dataDir;
        started = true;
        return <String, dynamic>{'state': 'online'};
      case 'account.me':
        if (!started) {
          throw const NexmemException('NOT_STARTED', '内核尚未启动');
        }
        return <String, dynamic>{
          'account_id': 'acct-${dataDir.length}-${dataDir.hashCode.abs()}',
          'device_id': 'device-1',
          'display_name': '测试账号',
        };
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<void> close() async {}
}

class _MemoryStore extends AccountLocalStore {
  Map<String, dynamic>? data;

  @override
  Future<Map<String, dynamic>?> read() async => data;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    data = Map<String, dynamic>.from(value);
  }

  @override
  Future<void> deleteAccountData(String dataDir, String profileId) async {
    deleted = profileId;
  }

  String? deleted;
}

void main() {
  test('PIN 摘要使用随机盐且可校验', () {
    const String pin = '123456';
    final String first = hashPin(pin, newPinSalt());
    final String second = hashPin(pin, newPinSalt());
    expect(first, isNot(second));
    expect(first.contains(pin), isFalse);
    expect(verifyPin(pin, first), isTrue);
    expect(verifyPin('654321', first), isFalse);
    expect(verifyPin(pin, 'bad-hash'), isFalse);
  });

  test('初始化补默认账号并合并本地档案', () async {
    final _SwitchTransport transport = _SwitchTransport();
    final _MemoryStore store = _MemoryStore();
    store.data = AccountSessionState(
      activeId: 'saved',
      profiles: <AccountProfile>[
        AccountProfile(id: 'saved', label: '旧账号', dataDir: '/tmp/nexmem/old'),
      ],
      lock: const LockSettings(autoLockMinutes: 5),
    ).toJson();
    final AccountManager manager = AccountManager(
      session: CoreSession(transport),
      store: store,
    );

    // 首帧即可用，不等待异步存储。
    expect(manager.initialized, isTrue);
    expect(manager.profiles, hasLength(1));
    await manager.initialize();

    expect(manager.activeId, 'saved');
    expect(manager.profiles.single.label, '旧账号');
    expect(manager.lockSettings.autoLockMinutes, 5);
  });

  test('重启后按上次活跃档案的数据目录恢复内核', () async {
    final _SwitchTransport transport = _SwitchTransport();
    final _MemoryStore store = _MemoryStore();
    store.data = AccountSessionState(
      activeId: 'saved',
      profiles: <AccountProfile>[
        AccountProfile(
          id: 'saved',
          label: '旧账号',
          dataDir: '/tmp/nexmem/old',
        ),
      ],
    ).toJson();
    final CoreSession session = CoreSession(
      transport,
      startConfig: <String, dynamic>{
        'data_dir': '/tmp/nexmem/data',
        'bootstrap': <String, dynamic>{'relay': true},
      },
    );
    final AccountManager manager = AccountManager(
      session: session,
      store: store,
    );
    await manager.initialize();

    expect(transport.dataDir, '/tmp/nexmem/old');
    expect(transport.started, isTrue);
    expect(session.activeStartConfig?['bootstrap'], isA<Map<String, dynamic>>());

    // 内核返回的账号身份与档案不一致时不覆盖已有档案。
    await manager.syncCurrentAccount();
    expect(manager.active?.dataDir, '/tmp/nexmem/old');
  });

  test('添加账号后切换，再切回默认账号使用各自数据目录', () async {
    final _SwitchTransport transport = _SwitchTransport();
    final AccountManager manager = AccountManager(
      session: CoreSession(transport),
      store: _MemoryStore(),
    );
    await manager.initialize();

    final String firstDir = transport.dataDir;
    final AccountProfile added = await manager.addAccount(label: '工作账号');
    expect(added.managed, isTrue);
    expect(added.dataDir, contains('/profiles/'));

    await manager.switchAccount(added.id);
    expect(manager.activeId, added.id);
    expect(transport.started, isTrue);
    expect(transport.dataDir, added.dataDir);
    expect(manager.active?.accountId, isNotEmpty);

    transport.calls.clear();
    await manager.switchAccount('default');
    expect(transport.calls.first, 'core.stop');
    expect(transport.dataDir, firstDir);
    expect(manager.activeId, 'default');
  });

  test('删除账号需要退出登录，默认账号不可删除', () async {
    final _MemoryStore store = _MemoryStore();
    final AccountManager manager = AccountManager(
      session: CoreSession(_SwitchTransport()),
      store: store,
    );
    await manager.initialize();
    final AccountProfile added = await manager.addAccount(label: '临时账号');

    await manager.deleteAccount('default');
    expect(manager.profiles.any((AccountProfile p) => p.isDefault), isTrue);
    await manager.switchAccount(added.id);
    await manager.deleteAccount(added.id);
    expect(manager.profiles.any((AccountProfile p) => p.id == added.id), isTrue);

    await manager.logout();
    expect(manager.activeId, isNull);
    await manager.deleteAccount(added.id, deleteData: true);
    expect(manager.profiles.any((AccountProfile p) => p.id == added.id), isFalse);
    expect(store.deleted, added.id);
  });

  test('临时锁停止内核，错误 PIN 不解锁，正确 PIN 恢复账号', () async {
    final _SwitchTransport transport = _SwitchTransport();
    final AccountManager manager = AccountManager(
      session: CoreSession(transport),
      store: _MemoryStore(),
    );
    await manager.initialize();
    await manager.setPin('2468');

    expect(await manager.lockNow(), isTrue);
    expect(manager.locked, isTrue);
    expect(transport.started, isFalse);

    expect(await manager.unlock('1357'), isFalse);
    expect(manager.locked, isTrue);

    expect(await manager.unlock('2468'), isTrue);
    expect(manager.locked, isFalse);
    expect(transport.started, isTrue);
  });

  test('移动端重装后失效的账号数据目录重定位到当前沙盒', () async {
    final _SwitchTransport transport = _SwitchTransport();
    final _MemoryStore store = _MemoryStore();
    store.data = AccountSessionState(
      activeId: 'default',
      profiles: <AccountProfile>[
        AccountProfile(
          id: 'default',
          label: '默认账号',
          dataDir: '/private/var/OLD-UUID/Application Support/nexmem/data',
        ),
        AccountProfile(
          id: 'p-work',
          label: '工作账号',
          dataDir: '/private/var/OLD-UUID/Application Support/nexmem/profiles/p-work',
          managed: true,
        ),
      ],
    ).toJson();
    const String current = '/private/var/NEW-UUID/Application Support/nexmem/data';
    final CoreSession session = CoreSession(
      transport,
      startConfig: <String, dynamic>{'data_dir': current},
      rebaseStaleDataDir: true,
    );
    final AccountManager manager = AccountManager(
      session: session,
      store: store,
      dataDirExists: (String path) async => path.startsWith(current),
    );
    await manager.initialize();

    expect(
      manager.profiles.firstWhere((AccountProfile p) => p.isDefault).dataDir,
      current,
    );
    expect(
      manager.profiles
          .firstWhere((AccountProfile p) => p.id == 'p-work')
          .dataDir,
      '/private/var/NEW-UUID/Application Support/nexmem/profiles/p-work',
    );
    // 目录已对齐平台启动配置，不应再用失效的旧目录重启内核。
    expect(transport.calls, isNot(contains('core.start')));
  });

  test('仍存在的旧目录不被改写，桌面端不启用数据目录重定位', () async {
    final _MemoryStore store = _MemoryStore();
    store.data = AccountSessionState(
      activeId: 'default',
      profiles: <AccountProfile>[
        AccountProfile(id: 'default', label: '默认账号', dataDir: '/data/old'),
      ],
    ).toJson();
    final AccountManager desktop = AccountManager(
      session: CoreSession(
        _SwitchTransport(),
        startConfig: <String, dynamic>{'data_dir': '/data/new'},
      ),
      store: store,
      dataDirExists: (String path) async => false,
    );
    await desktop.initialize();
    expect(desktop.active?.dataDir, '/data/old');

    final AccountManager existing = AccountManager(
      session: CoreSession(
        _SwitchTransport(),
        startConfig: <String, dynamic>{'data_dir': '/data/new'},
        rebaseStaleDataDir: true,
      ),
      store: store,
      dataDirExists: (String path) async => true,
    );
    await existing.initialize();
    expect(existing.active?.dataDir, '/data/old');
  });

  test('忘记 PIN 清除本地锁并退出登录', () async {
    final _SwitchTransport transport = _SwitchTransport();
    final AccountManager manager = AccountManager(
      session: CoreSession(transport),
      store: _MemoryStore(),
    );
    await manager.initialize();
    await manager.setPin('1234');
    await manager.lockNow();
    await manager.resetPinAndLogout();

    expect(manager.lockSettings.hasPin, isFalse);
    expect(manager.locked, isFalse);
    expect(manager.activeId, isNull);
  });
}
