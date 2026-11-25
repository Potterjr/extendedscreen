import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';

const _accent = Color(0xFF00C8FF);

/// Host, Home: an iPhone or iPad plugged in over USB, which the Mac shows
/// and drives in its own native window. Outside the hub: it takes no place
/// under Maximum tablets and has no Disconnect (closing its window stops
/// the capture). Its Open screen button opens that window on this device
/// (or brings it forward).
class IphoneUsbCard extends StatelessWidget {
  final IosScreenDevice device;

  /// Whether touches reach the phone (its TouchRunner over usbmuxd); null
  /// when there is no touch service (tests), or when it cannot be said
  /// which phone the service is bound to (more than one attached): the
  /// status then says nothing about touch.
  final Rx<IosTouchState>? touch;

  final VoidCallback onOpen;

  /// Whether the device's native window is open: the button then shows it
  /// rather than opening it.
  final bool windowOpen;

  const IphoneUsbCard({
    super.key,
    required this.device,
    required this.onOpen,
    this.touch,
    this.windowOpen = false,
  });

  /// USB-C, the role, and whether touch works, once it has been tried
  /// (idle says nothing: nobody has tried yet).
  static String statusFor(IosTouchState? state) => [
    'USB-C',
    'role_mac_controls'.tr,
    if (state == IosTouchState.ready)
      'iphone_remote_touch_ready'.tr
    else if (state != null && state != IosTouchState.idle)
      'iphone_remote_touch_off'.tr,
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white60, fontSize: 12);
    final touch = this.touch;
    final Widget status = touch == null
        ? Text(statusFor(null), style: style)
        : Obx(() => Text(statusFor(touch.value), style: style));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          // One icon for an iPhone and an iPad: the capture device says
          // neither, and its name is whatever the user called the device.
          const Icon(Icons.phonelink, color: _accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                status,
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: ValueKey('iphone-usb/${device.id}/open'),
            onPressed: onOpen,
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.black,
            ),
            child: Text(
              windowOpen ? 'iphone_usb_show_window'.tr : 'iphone_usb_open'.tr,
            ),
          ),
        ],
      ),
    );
  }
}
