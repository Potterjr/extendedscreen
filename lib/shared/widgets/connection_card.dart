import 'package:flutter/material.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';

class ConnectionCard extends StatelessWidget {
  final ConnectionPhase phase;
  final VoidCallback onTap;

  /// Whether to show the "Connect" action while disconnected. On the host this
  /// is false — connecting happens only by picking a device. "Disconnect" is
  /// always shown while active.
  final bool canConnect;

  const ConnectionCard({
    super.key,
    required this.phase,
    required this.onTap,
    this.canConnect = true,
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
                  isActive ? 'Connected' : phase.label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isActive
                      ? 'USB-C  •  H.264'
                      : 'Plug tablet via USB-C cable',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!isConnecting && (isActive || canConnect))
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                foregroundColor: isActive ? Colors.redAccent : const Color(0xFF00C8FF),
              ),
              child: Text(isActive ? 'Disconnect' : 'Connect'),
            ),
        ],
      ),
    );
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
