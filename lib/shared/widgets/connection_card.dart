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

  const ConnectionCard({
    super.key,
    required this.phase,
    required this.onTap,
    this.canConnect = true,
    this.codecLabel = 'H.264',
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
                      ? 'conn_card_active_subtitle'
                          .trParams({'codec': codecLabel})
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
          if (_action case final action?)
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(foregroundColor: action.color),
              child: Text(action.label),
            ),
        ],
      ),
    );
  }

  /// The one action this card offers for the current phase, if any. The host
  /// in `error` gets Cancel rather than Connect: it retries on its own, so the
  /// useful choice there is to stop retrying.
  ({String label, Color color})? get _action {
    if (phase.isActive) {
      return (label: 'common_disconnect'.tr, color: Colors.redAccent);
    }
    if (phase.isConnecting || (phase == ConnectionPhase.error && !canConnect)) {
      return (label: 'common_cancel'.tr, color: Colors.white70);
    }
    if (canConnect) {
      return (label: 'common_connect'.tr, color: const Color(0xFF00C8FF));
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
