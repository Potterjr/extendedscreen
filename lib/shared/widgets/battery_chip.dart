import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Client-only: shows the tablet's own charging state (distinct from the
/// stream's USB-C/latency chips) so a plugged-in tablet that isn't actually
/// charging is visible at a glance instead of silently draining.
class BatteryChip extends StatelessWidget {
  final bool isCharging;
  final int level; // 0-100, or -1 if unknown

  const BatteryChip({super.key, required this.isCharging, required this.level});

  @override
  Widget build(BuildContext context) {
    final color =
        isCharging ? const Color(0xFF00E676) : Colors.white.withValues(alpha: 0.5);
    final icon = isCharging ? Icons.battery_charging_full : Icons.battery_std;
    final label = level >= 0
        ? (isCharging
            ? 'battery_charging_pct'.trParams({'pct': '$level'})
            : 'battery_not_charging_pct'.trParams({'pct': '$level'}))
        : (isCharging ? 'battery_charging'.tr : 'battery_not_charging'.tr);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
