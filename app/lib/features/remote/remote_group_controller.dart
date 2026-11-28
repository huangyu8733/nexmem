// 远控群控管理：把控制端输入广播到多台已连接设备，并提供设备管理列表。
//
// 单台会话仍由 RemoteControlService 负责；本文件只管理「同时控制哪些设备」，
// 不重复实现信令、媒体与输入注入。群控只作用于已连接且已授权键鼠的控制端
// 会话，单台会话行为与没有群控时完全一致。

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 'remote_device_directory.dart';
import 'remote_input_codec.dart';
import 'remote_session.dart';

/// 群控所需的最小服务接口；RemoteControlService 天然满足。
abstract class RemoteGroupService {
  RemoteInfo? get current;

  Future<void> sendKey(String key, {required bool down, int modifiers = 0});

  Future<void> sendCombo(String key, {int modifiers = 0});

  Future<void> sendText(String text);

  Future<void> sendPointer(RemotePointerEvent event);

  Future<void> sendTouch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  });

  Future<void> sendClipboardText(String text);

  Future<void> end({String reason = '会话已结束'});
}

/// 群控设备列表中的一项。
class RemoteGroupTarget {
  const RemoteGroupTarget({
    required this.peer,
    required this.name,
    required this.info,
  });

  final String peer;
  final String name;
  final RemoteInfo info;
}

/// 群控状态：是否开启、勾选了哪些设备，以及向这些设备广播输入。
///
/// [services] 直接使用壳层的控制端服务表，连接/断开后由调用方 [sync] 刷新
/// 勾选集合，避免群控指向已经结束的会话。
class RemoteGroupController {
  RemoteGroupController({
    required this.services,
    this.deviceTypeOf,
    this.groupType = RemoteDeviceType.other,
  }) {
    sync();
  }

  final Map<String, RemoteGroupService> services;

  /// 由设备台账提供 peer → 设备类型；未提供时全部按「其他」对待。
  final RemoteDeviceType Function(String peer)? deviceTypeOf;

  /// 当前群控的设备类型。只控制同类型设备，避免跨平台键位语义错乱。
  RemoteDeviceType groupType;

  final Set<String> _selected = <String>{};

  /// 会话集合变化时是否允许为空集合自动补齐。
  ///
  /// 用户主动「清空 / 取消勾选」后必须为 false，否则每次 build 调用 [sync]
  /// 都会把刚清掉的设备重新选上，界面看起来像按钮失效。
  bool _autoSelect = true;

  /// 群控开关；关闭时所有输入仍只发给当前查看的设备。
  bool enabled = false;

  Set<String> get selected => Set<String>.unmodifiable(_selected);

  RemoteDeviceType typeOf(String peer) => deviceTypeOf?.call(peer) ??
      RemoteDeviceType.other;

  /// 群控目标不足两台时自动退出，避免 UI 显示「群控中」但输入已退化成单控。
  void _enforceGroupState() {
    if (enabled && targetCount < 2) {
      enabled = false;
      _selected.clear();
    }
  }

  /// 切换群控类型时清空勾选，防止把上一类型的设备带入广播。
  void setGroupType(RemoteDeviceType type) {
    if (groupType == type) {
      return;
    }
    groupType = type;
    _selected.clear();
    if (!enabled) {
      return;
    }
    _autoSelect = true;
    final Set<String> active =
        availableTargets.map((RemoteGroupTarget t) => t.peer).toSet();
    _selected.addAll(active);
    _enforceGroupState();
  }

  /// 当前可作为群控目标的设备（已连接、控制端角色、与当前类型一致）。
  List<RemoteGroupTarget> get availableTargets {
    final List<RemoteGroupTarget> result = <RemoteGroupTarget>[];
    for (final MapEntry<String, RemoteGroupService> entry
        in services.entries) {
      final RemoteInfo? info = entry.value.current;
      if (info == null || !info.isController || !info.isActive) {
        continue;
      }
      // 设备台账未标注的新会话按「其他」处理，与默认类型一致。
      if (typeOf(entry.key) != groupType) {
        continue;
      }
      result.add(RemoteGroupTarget(
        peer: entry.key,
        name: info.peerName.isEmpty ? entry.key : info.peerName,
        info: info,
      ));
    }
    return result;
  }

  bool get canGroup => availableTargets.length > 1;

  /// 已勾选且仍可控制的设备。
  List<RemoteGroupTarget> get targets => <RemoteGroupTarget>[
        for (final RemoteGroupTarget target in availableTargets)
          if (_selected.contains(target.peer)) target,
      ];

  int get targetCount => targets.length;

  /// 会话集合变化后只剔除已结束设备。
  ///
  /// 这里不能因为「空集合」重新全选：调用方会在 build 阶段调用 [sync] 同步
  /// 会话数量，自动补齐会立刻撤销用户刚刚点下的「清空」。
  void sync() {
    final Set<String> active =
        availableTargets.map((RemoteGroupTarget t) => t.peer).toSet();
    _selected.retainWhere(active.contains);
    if (_autoSelect && _selected.isEmpty) {
      _selected.addAll(active);
    }
    _enforceGroupState();
  }

  bool isSelected(String peer) => _selected.contains(peer);

  void toggle(String peer) {
    _autoSelect = false;
    if (!_selected.remove(peer)) {
      _selected.add(peer);
    }
    _enforceGroupState();
  }

  void selectAll() {
    _autoSelect = false;
    _selected.addAll(availableTargets.map((RemoteGroupTarget t) => t.peer));
    _enforceGroupState();
  }

  void clearSelection() {
    _autoSelect = false;
    _selected.clear();
    _enforceGroupState();
  }

  void setEnabled(bool value) {
    enabled = value && canGroup;
    if (!enabled) {
      _selected.clear();
      return;
    }
    _autoSelect = true;
    sync();
  }

  Future<void> _broadcast(
    RemotePermission permission,
    Future<void> Function(RemoteGroupService service) action,
  ) async {
    if (!enabled) {
      return;
    }
    final List<Future<void>> futures = <Future<void>>[];
    for (final RemoteGroupTarget target in targets) {
      if (!target.info.permissions.allows(permission)) {
        continue;
      }
      final RemoteGroupService? service = services[target.peer];
      if (service == null) {
        continue;
      }
      // 单台失败不影响其余设备；逐台尽力而为。
      futures.add(
        action(service).catchError((Object _) => Future<void>.value()),
      );
    }
    await Future.wait(futures);
  }

  Future<void> broadcastKey(
    String key, {
    required bool down,
    int modifiers = 0,
  }) =>
      _broadcast(
        RemotePermission.input,
        (RemoteGroupService service) => service.sendKey(
          key,
          down: down,
          modifiers: modifiers,
        ),
      );

  Future<void> broadcastCombo(String key, {int modifiers = 0}) => _broadcast(
        RemotePermission.input,
        (RemoteGroupService service) =>
            service.sendCombo(key, modifiers: modifiers),
      );

  Future<void> broadcastText(String text) => _broadcast(
        RemotePermission.input,
        (RemoteGroupService service) => service.sendText(text),
      );

  Future<void> broadcastPointer(RemotePointerEvent event) => _broadcast(
        RemotePermission.input,
        (RemoteGroupService service) => service.sendPointer(event),
      );

  /// 广播多点触摸，手机控手机/电脑控手机时所有勾选设备同步执行手势。
  Future<void> broadcastTouch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  }) =>
      _broadcast(
        RemotePermission.input,
        (RemoteGroupService service) =>
            service.sendTouch(phase, points, modifiers: modifiers),
      );

  Future<void> broadcastClipboard(String text) => _broadcast(
        RemotePermission.clipboard,
        (RemoteGroupService service) => service.sendClipboardText(text),
      );

  /// 批量断开勾选设备；终态清理仍由各会话自身的监听器负责。
  Future<void> endSelected() async {
    final List<Future<void>> futures = <Future<void>>[];
    for (final RemoteGroupTarget target in targets) {
      final RemoteGroupService? service = services[target.peer];
      if (service == null) {
        continue;
      }
      futures.add(
        service.end().catchError((Object _) => Future<void>.value()),
      );
    }
    await Future.wait(futures);
    // 被断开的设备不应在 sync 时又被自动勾选回来。
    _autoSelect = false;
    sync();
  }
}

/// 管理远控设备列表：勾选设备、开关群控、批量断开。
class RemoteGroupSheet extends StatefulWidget {
  const RemoteGroupSheet({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  final RemoteGroupController controller;
  final VoidCallback onChanged;
  final VoidCallback onClose;

  @override
  State<RemoteGroupSheet> createState() => _RemoteGroupSheetState();
}

class _RemoteGroupSheetState extends State<RemoteGroupSheet> {
  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final RemoteGroupController controller = widget.controller;
    final VoidCallback onClose = widget.onClose;
    final List<RemoteGroupTarget> targets = controller.availableTargets;
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.groups_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.t('管理远控设备'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('remote-group-sheet-close'),
                  tooltip: context.t('关闭'),
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
            // 群控只作用于同类型设备：不同平台的键位/修饰键语义不同。
            DropdownButtonFormField<RemoteDeviceType>(
              key: const ValueKey<String>('remote-group-type'),
              initialValue: controller.groupType,
              decoration: InputDecoration(
                labelText: context.t('设备类型'),
                isDense: true,
              ),
              items: <DropdownMenuItem<RemoteDeviceType>>[
                for (final RemoteDeviceType type
                    in RemoteDeviceType.assignable)
                  DropdownMenuItem<RemoteDeviceType>(
                    value: type,
                    child: Text(context.t(type.label)),
                  ),
              ],
              onChanged: (RemoteDeviceType? value) {
                if (value == null) {
                  return;
                }
                controller.setGroupType(value);
                _changed();
              },
            ),
            SwitchListTile(
              key: const ValueKey<String>('remote-group-enabled'),
              contentPadding: EdgeInsets.zero,
              value: controller.enabled,
              onChanged: targets.length > 1
                  ? (bool value) {
                      controller.setEnabled(value);
                      _changed();
                    }
                  : null,
              title: Text(context.t('群控模式')),
              subtitle: Text(
                context.t('{0} · 已选择 {1} 台', [
                  context.t(controller.groupType.label),
                  controller.targetCount,
                ]),
              ),
            ),
            if (targets.length < 2)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  context.t('至少需要两台同类型设备在线才能群控'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            Expanded(
              child: targets.isEmpty
                  ? Center(child: Text(context.t('暂无远控设备')))
                  : ListView(
                      children: <Widget>[
                        for (final RemoteGroupTarget target in targets)
                          CheckboxListTile(
                            key: ValueKey<String>('remote-device-${target.peer}'),
                            contentPadding: EdgeInsets.zero,
                            value: controller.isSelected(target.peer),
                            title: Text(
                              target.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${context.t(target.info.state.label)} · '
                              '${context.t(target.info.permissions.input ? '控制键鼠' : '仅查看')}',
                            ),
                            onChanged: (_) {
                              controller.toggle(target.peer);
                              _changed();
                            },
                          ),
                      ],
                    ),
            ),
            Row(
              children: <Widget>[
                TextButton(
                  key: const ValueKey<String>('remote-group-select-all'),
                  onPressed: targets.isEmpty
                      ? null
                      : () {
                          controller.selectAll();
                          _changed();
                        },
                  child: Text(context.t('全选')),
                ),
                TextButton(
                  key: const ValueKey<String>('remote-group-clear'),
                  onPressed: () {
                    controller.clearSelection();
                    _changed();
                  },
                  child: Text(context.t('清空')),
                ),
                const Spacer(),
                FilledButton.tonal(
                  key: const ValueKey<String>('remote-group-end'),
                  onPressed: controller.targetCount == 0
                      ? null
                      : () async {
                          await controller.endSelected();
                          _changed();
                        },
                  child: Text(context.t('断开所选')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
