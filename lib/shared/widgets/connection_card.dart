import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';

class ConnectionCard extends StatelessWidget {
  final ConnectionPhase phase;
  final VoidCallback onTap;

  /// Whether to show the "Connect" action while disconnected. On the host this
  /// is false — connecting happens only by picking a device. "Disconnect" is
  /// always shown while active, and "Cancel" while connecting — plus, on the
  /// host, while an automatic retry is pending after an error.
  final bool canConnect;

  /// Active codec label shown in the subtitle while connected (e.g. "H.265").
  final String codecLabel;

  /// The link in use, for the subtitle: its name while connected, and what to
  /// do to get connected (plug in, or join the same Wi-Fi) while not.
  final bool wifi;

  /// Offered as Retry in `error` (a host session: one whose failure armed no
  /// retry, which only the user can start again, or one whose retry waits
  /// out its backoff, which this runs now), beside Cancel ([onTap]), which
  /// ends the session and frees its place. Null: Cancel alone.
  final VoidCallback? onRetry;

  /// Prepended to the action button's key (`'<prefix>/<label>'`), so that
  /// several cards on one screen (one per tablet) never share a key.
  final String? actionKeyPrefix;

  const ConnectionCard({
    super.key,
    required this.phase,
    required this.onTap,
    this.canConnect = true,
    this.codecLabel = 'H.264',
    this.wifi = false,
    this.onRetry,
    this.actionKeyPrefix,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = phase.isActive;
    final isConnecting = phase.isConnecting;
    final color = _phaseColor(phase);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: isConnecting
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(_phaseIcon(phase), color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isActive ? 'common_connected'.tr : phase.label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isActive
                      ? 'conn_card_active_subtitle'.trParams({
                          'link': wifi ? 'Wi-Fi' : 'USB-C',
                          'codec': codecLabel,
                        })
                      : wifi
                          ? 'conn_card_wifi_prompt'.tr
                          : 'conn_card_plug_prompt'.tr,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Retry's companion: a session that won't retry by itself can
          // still be ended, so its card (and its place under the cap) does
          // not stay for good.
          if (phase == ConnectionPhase.error && onRetry != null)
            TextButton(
              key: ValueKey(actionKeyPrefix == null
                  ? 'common_cancel'.tr
                  : '$actionKeyPrefix/${'common_cancel'.tr}'),
              onPressed: onTap,
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: Text('common_cancel'.tr),
            ),
          if (_action case final action?)
            TextButton(
              // Keyed by what it does: the phase can change between a
              // finger going down and coming up (an auto-connect starting, a
              // redial), and without the key that touch would land on the
              // new meaning, a press on Connect arriving as Cancel. With it
              // the button is replaced and the touch does nothing.
              key: ValueKey(actionKeyPrefix == null
                  ? action.label
                  : '$actionKeyPrefix/${action.label}'),
              onPressed: action.onPressed,
              style: TextButton.styleFrom(foregroundColor: action.color),
              child: Text(action.label),
            ),
        ],
      ),
    );
  }

  /// The one action this card offers for the current phase, if any. The host
  /// in `error` gets Cancel rather than Connect: it retries on its own, so the
  /// useful choice there is to stop retrying. With [onRetry] given, Retry,
  /// with Cancel beside it (see [build]).
  ({String label, Color color, VoidCallback onPressed})? get _action {
    if (phase.isActive) {
      return (
        label: 'common_disconnect'.tr,
        color: Colors.redAccent,
        onPressed: onTap,
      );
    }
    if (phase == ConnectionPhase.error && onRetry != null) {
      return (
        label: 'common_retry'.tr,
        color: const Color(0xFF00C8FF),
        onPressed: onRetry!,
      );
    }
    if (phase.isConnecting || (phase == ConnectionPhase.error && !canConnect)) {
      return (label: 'common_cancel'.tr, color: Colors.white70, onPressed: onTap);
    }
    if (canConnect) {
      return (
        label: 'common_connect'.tr,
        color: const Color(0xFF00C8FF),
        onPressed: onTap,
      );
    }
    return null;
  }

  Color _phaseColor(ConnectionPhase p) => switch (p) {
        ConnectionPhase.streaming => const Color(0xFF00E676),
        ConnectionPhase.paused => const Color(0xFFFFB300),
        ConnectionPhase.error => Colors.redAccent,
        _ when p.isConnecting => const Color(0xFF00C8FF),
        _ => Colors.white38,
      };

  IconData _phaseIcon(ConnectionPhase p) => switch (p) {
        ConnectionPhase.streaming => Icons.monitor,
        ConnectionPhase.paused => Icons.pause_circle_outline,
        ConnectionPhase.error => Icons.error_outline,
        ConnectionPhase.disconnected => Icons.monitor_outlined,
        _ => Icons.sync,
      };
}
