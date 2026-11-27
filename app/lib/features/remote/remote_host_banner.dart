// 被控中顶部提示条：明确告知正在被控制，并提供暂停/继续与立即断开。
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 'remote_session.dart';

class RemoteHostBanner extends StatelessWidget {
  const RemoteHostBanner({
    super.key,
    required this.info,
    required this.onPause,
    required this.onResume,
    required this.onStop,
  });

  final RemoteInfo info;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final bool paused = info.state == RemoteState.paused;
    return Material(
      color: paused ? const Color(0xFF5A4A12) : const Color(0xFF7A1F1F),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: <Widget>[
              Icon(
                paused ? Icons.pause_circle_outline : Icons.screen_share,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  paused
                      ? context.t('远程控制已暂停（画面仍可见）')
                      : context.t('{0} 正在远程控制本机', [_name()]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              TextButton(
                key: const ValueKey<String>('remote-host-pause'),
                onPressed: paused ? onResume : onPause,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size(48, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  paused ? context.t('继续') : context.t('暂停'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                key: const ValueKey<String>('remote-host-stop'),
                onPressed: onStop,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size(48, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  context.t('断开'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _name() => info.peerName.isEmpty ? info.peer : info.peerName;
}
