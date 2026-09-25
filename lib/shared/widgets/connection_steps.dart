import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';

/// Client-side connection status: a single combined row (icon + phase label +
/// short caption + progress bar) instead of a three-step checklist. The phase
/// label already says exactly how far things have gotten, so a full
/// checklist was more scrolling than the information was worth while waiting.
class ConnectionSteps extends StatelessWidget {
  final ConnectionPhase phase;
  const ConnectionSteps({super.key, required this.phase});

  /// 0.0–1.0 progress toward streaming, for the bar under the status row.
  double get _progress => switch (phase) {
        ConnectionPhase.streaming || ConnectionPhase.paused => 1.0,
        ConnectionPhase.configuring => 0.66,
        ConnectionPhase.error || ConnectionPhase.disconnected => 0.0,
        _ => 0.33, // detecting / adb connecting / port forwarding / handshaking
      };

  String get _caption => switch (phase) {
        ConnectionPhase.streaming || ConnectionPhase.paused =>
          'step_ready_detail'.tr,
        ConnectionPhase.configuring => 'step_configure_detail'.tr,
        ConnectionPhase.error => 'phase_error'.tr,
        ConnectionPhase.disconnected => 'conn_card_plug_prompt'.tr,
        _ => 'step_connect_detail'.tr,
      };

  @override
  Widget build(BuildContext context) {
    final isError = phase == ConnectionPhase.error;
    final isDone = phase.isActive;
    final isIdle = phase == ConnectionPhase.disconnected;
    final color = isError
        ? Colors.redAccent
        : isDone
            ? const Color(0xFF00E676)
            : const Color(0xFF00C8FF);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!isDone && !isError && !isIdle)
                SizedBox(
                  width: 20,
                  height: 20,
                  child:
                      CircularProgressIndicator(strokeWidth: 2.5, color: color),
                )
              else
                Icon(
                  isError
                      ? Icons.error
                      : isDone
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                  color: color,
                  size: 20,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  phase.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Text(
              _caption,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 4,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}
