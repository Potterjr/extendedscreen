import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/device_model.dart';

const _accent = Color(0xFF00C8FF);

/// One device the Add a device panel offers: attached, with no session.
class AddDeviceRow {
  const AddDeviceRow({
    required this.device,
    required this.subtitle,
    required this.asksRole,
    this.disabledReason,
    this.note,
  });

  final DeviceModel device;

  /// How it is attached, and the role it had last time (or that it is new).
  final String subtitle;

  /// Why it cannot be connected now, in plain words; null when it can.
  final String? disabledReason;

  /// Connect asks for the role first: a new device, or a remembered one
  /// whose remembered role the Mac's encoder has no room for now. Else it
  /// connects in its remembered role.
  final bool asksRole;

  /// Something to know that does not stop a connect (the remembered role
  /// does not fit now), in plain words.
  final String? note;
}

/// Host, Home: the devices found and not connected, each with a Connect
/// button, then [wifiRow] (accepting devices over Wi-Fi), always last.
///
/// Plain widget over a snapshot: [rows] must be plain values read inside
/// the caller's `Obx`, not an `RxList`, or a list change doesn't rebuild
/// the panel.
class AddDevicePanel extends StatelessWidget {
  final List<AddDeviceRow> rows;

  /// What the panel says with no row (null: nothing).
  final String? emptyText;

  /// A manual refresh is running: the refresh button shows a spinner and is
  /// disabled until it finishes.
  final bool refreshing;

  final VoidCallback onRefresh;

  /// Connect on a remembered device: connect it in its remembered role.
  final ValueChanged<DeviceModel> onConnect;

  /// Connect on a row that [AddDeviceRow.asksRole]: choose its role, then
  /// connect.
  final ValueChanged<DeviceModel> onChoose;

  final Widget wifiRow;

  const AddDevicePanel({
    super.key,
    required this.rows,
    required this.onRefresh,
    required this.onConnect,
    required this.onChoose,
    required this.wifiRow,
    this.emptyText,
    this.refreshing = false,
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
                  'home_add_device'.tr,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('add/refresh'),
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
          // Keyed by device: the list can change under a finger (a tablet
          // plugged in or connected by itself leaves or joins it), and an
          // unkeyed row would keep the press while taking the next device's
          // place, connecting a tablet nobody touched.
          for (final row in rows)
            _AddRow(
              key: ValueKey('device/${row.device.serial}'),
              row: row,
              onConnect: () => onConnect(row.device),
              onChoose: () => onChoose(row.device),
            ),
          if (rows.isEmpty && emptyText != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                emptyText!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            ),
          Divider(color: Colors.white.withValues(alpha: 0.08), height: 16),
          wifiRow,
        ],
      ),
    );
  }
}

class _AddRow extends StatelessWidget {
  final AddDeviceRow row;
  final VoidCallback onConnect;
  final VoidCallback onChoose;

  const _AddRow({
    super.key,
    required this.row,
    required this.onConnect,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final d = row.device;
    final enabled = row.disabledReason == null;
    // Only the button connects, and it is keyed by what it does as well as
    // by the device: a device that becomes remembered (or new) under a
    // finger gets another button, which the press does not reach.
    final button = row.asksRole
        ? FilledButton.tonal(
            key: ValueKey('device/${d.serial}/choose'),
            onPressed: enabled ? onChoose : null,
            child: Text('common_connect'.tr),
          )
        : FilledButton.tonal(
            key: ValueKey('device/${d.serial}/connect'),
            onPressed: enabled ? onConnect : null,
            child: Text('common_connect'.tr),
          );
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(
              d.isEmulator ? Icons.developer_mode : Icons.tablet_android,
              color: _accent,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.model ?? d.serial,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    row.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12,
                    ),
                  ),
                  if (row.disabledReason ?? row.note case final reason?)
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
            const SizedBox(width: 8),
            button,
          ],
        ),
      ),
    );
  }
}
