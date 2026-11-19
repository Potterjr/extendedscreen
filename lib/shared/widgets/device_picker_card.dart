import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/device_model.dart';

/// Host-only picker: lists detected ADB clients so the user chooses which
/// Android device to stream to (instead of auto-picking the first one). On
/// Home over USB it is the panel that adds a tablet beside those connected.
///
/// Plain widget over a snapshot: [devices] and [disabledReasons] must be plain
/// values read inside the caller's `Obx`, not the `RxList` itself, or a list
/// change doesn't rebuild the card.
class DevicePickerCard extends StatelessWidget {
  final List<DeviceModel> devices;
  final ValueChanged<DeviceModel> onSelect;
  final VoidCallback onRefresh;

  /// A manual refresh is running: the refresh button shows a spinner and is
  /// disabled until it finishes.
  final bool refreshing;

  /// The title (default: "Android client"), an optional line under it, and
  /// what the card says with no device to list (default: none detected).
  final String? title;
  final String? header;
  final String? emptyText;

  /// Devices that can't be picked now, by serial, each with the reason its
  /// tile shows. Such a tile is dimmed and ignores taps.
  final Map<String, String> disabledReasons;

  const DevicePickerCard({
    super.key,
    required this.devices,
    required this.onSelect,
    required this.onRefresh,
    this.refreshing = false,
    this.title,
    this.header,
    this.emptyText,
    this.disabledReasons = const {},
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
              Expanded(
                child: Text(
                  title ?? 'device_android_client'.tr,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              IconButton(
                icon: refreshing
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      )
                    : const Icon(Icons.refresh, size: 18),
                color: Colors.white.withValues(alpha: 0.6),
                tooltip: 'device_refresh_tooltip'.tr,
                onPressed: refreshing ? null : onRefresh,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (header case final header?)
            Text(
              header,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
              ),
            ),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                emptyText ?? 'device_none_detected'.tr,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            )
          else
            // Keyed by device: the list can change under a finger (a
            // tablet plugged in or connected by itself leaves or joins it),
            // and an unkeyed tile would keep the press while taking the
            // next device's tap, connecting a tablet nobody touched.
            ...devices.map(
              (d) => _DeviceTile(
                key: ValueKey('device/${d.serial}'),
                device: d,
                disabledReason: disabledReasons[d.serial],
                onTap: () => onSelect(d),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final DeviceModel device;
  final VoidCallback onTap;

  /// Why it can't be picked now; null when it can.
  final String? disabledReason;

  const _DeviceTile({
    super.key,
    required this.device,
    required this.onTap,
    this.disabledReason,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = disabledReason == null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              const Icon(Icons.tablet_android,
                  color: Color(0xFF00C8FF), size: 20),
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
                    if (disabledReason case final reason?)
                      Text(
                        reason,
                        style: const TextStyle(
                          color: Color(0xFFFFB300),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (enabled)
                Icon(
                  Icons.chevron_right,
                  color: Colors.white.withValues(alpha: 0.3),
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
