import 'package:flutter/material.dart';
import 'package:extendedscreen/shared/models/device_model.dart';

/// Host-only picker: lists detected ADB clients so the user chooses which
/// Android device to stream to (instead of auto-picking the first one).
class DevicePickerCard extends StatelessWidget {
  final List<DeviceModel> devices;
  final ValueChanged<DeviceModel> onSelect;
  final VoidCallback onRefresh;

  const DevicePickerCard({
    super.key,
    required this.devices,
    required this.onSelect,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
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
              Text(
                'Android client',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                color: Colors.white.withValues(alpha: 0.6),
                tooltip: 'Refresh devices',
                onPressed: onRefresh,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No device detected — plug in via USB-C',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            )
          else
            ...devices.map(
              (d) => _DeviceTile(device: d, onTap: () => onSelect(d)),
            ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final DeviceModel device;
  final VoidCallback onTap;
  const _DeviceTile({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            const Icon(Icons.tablet_android, color: Color(0xFF00C8FF), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.model ?? device.serial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    device.serial,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: Colors.white.withValues(alpha: 0.3),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
