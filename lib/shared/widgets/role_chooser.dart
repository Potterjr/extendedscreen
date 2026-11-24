import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/widgets/device_card.dart';

const _accent = Color(0xFF00C8FF);

/// Host, Home: what a device is to be, asked when its Connect is pressed:
/// a device the Mac has not had before, or one whose remembered role the
/// Mac's encoder has no room for now. A device the Mac knows connects in
/// its remembered role without asking, and any device's role is changed
/// later on its card.
class RoleChooser {
  RoleChooser._();

  /// The role picked for [device], or null when the dialog was cancelled.
  /// [preselected] is highlighted; a role [fits] says no to (the Mac's
  /// encoder has no room for it) is offered disabled, with the reason.
  static Future<SessionChoice?> show(
    BuildContext context, {
    required DeviceModel device,
    required SessionChoice preselected,
    required bool Function(SessionChoice) fits,
  }) {
    final serial = device.serial;
    return showDialog<SessionChoice>(
      context: context,
      builder: (context) {
        final width = math.min(420.0, MediaQuery.sizeOf(context).width - 64);
        return AlertDialog(
          backgroundColor: const Color(0xFF111827),
          title: Text(
            'home_choose_role_title'.trParams({
              'name': device.model ?? device.serial,
            }),
            style: const TextStyle(color: Colors.white, fontSize: 17),
          ),
          content: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'home_choose_role_hint'.tr,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  for (final c in SessionChoice.all) ...[
                    _ChoiceTile(
                      key: ValueKey(
                        'choose/$serial/${c.mode.name}.${c.direction.name}',
                      ),
                      choice: c,
                      // By effect: an Extended choice carries whichever
                      // direction was saved, which changes nothing it does.
                      highlighted: c.sameEffect(preselected),
                      // The Mac encodes nothing for a device it controls.
                      enabled: c.isReverse || fits(c),
                      onTap: () => Navigator.of(context).pop(c),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              key: ValueKey('choose/$serial/cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text('common_cancel'.tr),
            ),
          ],
        );
      },
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final SessionChoice choice;
  final bool highlighted;
  final bool enabled;
  final VoidCallback onTap;

  const _ChoiceTile({
    super.key,
    required this.choice,
    required this.highlighted,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: highlighted
            ? _accent.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onTap : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted
                    ? _accent
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  RoleChip.iconFor(choice),
                  size: 20,
                  color: highlighted ? _accent : Colors.white60,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        choice.roleLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        choice.roleDescription,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      if (!enabled)
                        Text(
                          'home_row_encoder_full'.tr,
                          style: const TextStyle(
                            color: Color(0xFFFFB300),
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
