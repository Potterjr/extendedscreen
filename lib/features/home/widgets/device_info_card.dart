import 'package:flutter/material.dart';
import '../../../core/models/device_model.dart';

class DeviceInfoCard extends StatelessWidget {
  final DeviceModel? device;
  const DeviceInfoCard({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    if (device == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.tablet_android, color: Color(0xFF00C8FF), size: 20),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device!.model ?? 'Samsung Galaxy Tab',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),
              Text(
                device!.serial,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
