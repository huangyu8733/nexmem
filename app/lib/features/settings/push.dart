import '../../transport/transport.dart';

/// 推送环境；与 Go 宿主 / 索引服务的 push_tokens.env 字段对应。
enum PushEnvironment { production, sandbox }

extension PushEnvironmentName on PushEnvironment {
  String get wireName => switch (this) {
        PushEnvironment.production => 'production',
        PushEnvironment.sandbox => 'sandbox',
      };
}

/// 设备推送令牌上报通道（C-07）。
///
/// 设备令牌本身由原生宿主（APNs / FCM）获取，本服务只负责经内核把令牌登记到
/// 索引服务，或在用户关闭推送时注销。真机 token 获取能力受 R-16 约束。
abstract class PushService {
  /// 登记令牌；返回当前账号已登记的令牌总数。
  Future<int> register(String token, {PushEnvironment env = PushEnvironment.production});

  /// 注销令牌；返回是否确实移除了一个令牌。
  Future<bool> unregister(
    String token, {
    PushEnvironment env = PushEnvironment.production,
  });
}

/// 占位实现：内核未接入时明确抛 NOT_STARTED，不伪装成功。
class UnavailablePushService implements PushService {
  const UnavailablePushService();

  @override
  Future<int> register(String token, {PushEnvironment env = PushEnvironment.production}) async {
    throw const NexmemException('NOT_STARTED', '推送上报服务尚未接入内核');
  }

  @override
  Future<bool> unregister(String token, {PushEnvironment env = PushEnvironment.production}) async {
    throw const NexmemException('NOT_STARTED', '推送上报服务尚未接入内核');
  }
}

/// 经内核 `push.register` / `push.unregister` 上报到索引服务。
class TransportPushService implements PushService {
  const TransportPushService(this.transport);

  final CoreTransport transport;

  @override
  Future<int> register(String token, {PushEnvironment env = PushEnvironment.production}) async {
    final Map<String, dynamic> data = await transport.call(
      'push.register',
      params: <String, dynamic>{'token': token, 'env': env.wireName},
    );
    final Object? count = data['tokens'];
    return count is num ? count.toInt() : 0;
  }

  @override
  Future<bool> unregister(String token, {PushEnvironment env = PushEnvironment.production}) async {
    final Map<String, dynamic> data = await transport.call(
      'push.unregister',
      params: <String, dynamic>{'token': token, 'env': env.wireName},
    );
    return data['removed'] == true;
  }
}
