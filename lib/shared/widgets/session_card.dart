import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/connection_card.dart';
import 'package:extendedscreen/shared/widgets/connection_steps.dart';
import 'package:extendedscreen/shared/widgets/latency_chip.dart';

/// Host, Home over USB: one tablet's session. Which tablet, how it is
/// linked and what it runs (with a menu to have it run as something else),
/// its phase with the one action that fits it (Disconnect, Cancel, or in
/// `error` Retry beside Cancel), and while live its round trip, rate and
/// what the shared encoder gave it.
///
/// Tapping the card focuses its session: the values the hub shows as its
/// own follow the focused tablet. Its own `Obx` reads only [session]'s
/// observables, so one tablet's latency ticking rebuilds no other card.
class SessionCard extends StatelessWidget {
  final HostSession session;

  /// This is the hub's focused session: drawn with an accent border.
  final bool focused;

  /// The device list's entry for this tablet, for its model before the
  /// session has listed the device itself.
  final DeviceModel? listed;

  final VoidCallback onFocus;
  final ValueChanged<String> onStop;
  final ValueChanged<String> onRetry;

  /// Reverse remote: reopen the remote view of this tablet.
  final VoidCallback onOpenRemote;

  /// The mode menu's pick: the session the menu was opened on (not
  /// whichever one holds this card by the time an item is pressed) and what
  /// it is to run as. Null: no menu (every session is being ended).
  final void Function(HostSession session, SessionChoice choice)? onMode;

  const SessionCard({
    super.key,
    required this.session,
    required this.focused,
    required this.onFocus,
    required this.onStop,
    required this.onRetry,
    required this.onOpenRemote,
    this.onMode,
    this.listed,
  });

  static const _accent = Color(0xFF00C8FF);

  /// The width the top row keeps for the tablet's model, whatever its
  /// chips would take.
  static const _minTitleWidth = 72.0;

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsService>();
    return Obx(() {
      final s = session;
      final phase = s.phase.value;
      final device = s.activeDevice.value ?? listed;
      final model = device?.model;
      final wifi = s.link == LinkType.wifi;
      final granted = s.granted.value;
      final error = _errorLine(
        phase,
        s.errorKey.value,
        s.errorMessage.value,
        s.notice.value,
      );
      final latency = s.latencyMs.value;
      final hz = s.refreshRateHz.value;
      final bitrate = s.streamBitrate.value;
      final codec = settings.codecRx.value == CodecType.h265
          ? 'H.265'
          : 'H.264';
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onFocus,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: focused
                    ? _accent.withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0.08),
                width: focused ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The model keeps [_minTitleWidth] and the chips take what
                // they need of the rest. When that is not enough (a narrow
                // window, the longest mode's label), the mode chip is cut
                // short instead of the row running over the card's edge.
                LayoutBuilder(
                  builder: (context, box) => Row(
                    children: [
                      const Icon(
                        Icons.tablet_android,
                        color: _accent,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              model ?? s.key,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            if (model != null)
                              Text(
                                s.key,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          // Less the icon and the two gaps beside the model.
                          maxWidth: (box.maxWidth - 40 - _minTitleWidth).clamp(
                            0.0,
                            double.infinity,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Chip(
                              icon: wifi ? Icons.wifi : Icons.usb,
                              text: s.link.label,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: _Chip(text: s.effectiveChoice.label),
                            ),
                            // A tablet's mode changes by replacing its
                            // session, which the hub does for one that is
                            // live or waits in `error`, not for one on its
                            // way to being live.
                            if (onMode case final onMode?
                                when !wifi &&
                                    (phase.isActive ||
                                        phase == ConnectionPhase.error)) ...[
                              const SizedBox(width: 2),
                              _ModeMenu(session: s, onMode: onMode),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ConnectionCard(
                  phase: phase,
                  canConnect: false,
                  codecLabel: codec,
                  wifi: wifi,
                  actionKeyPrefix: s.key,
                  onTap: () => onStop(s.key),
                  // In `error` always: a session the encoder refused waits
                  // for it, and one waiting out its retry's backoff (up to
                  // ten seconds or so over USB) runs that retry now.
                  onRetry: phase == ConnectionPhase.error
                      ? () => onRetry(s.key)
                      : null,
                ),
                if (phase.isConnecting) ...[
                  const SizedBox(height: 10),
                  ConnectionSteps(phase: phase, wifi: wifi),
                ],
                if (phase.isActive) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      LatencyChip(
                        latencyMs: latency,
                        wifi: wifi,
                        bitrate: bitrate,
                      ),
                      _Chip(icon: Icons.speed, text: '$hz fps'),
                    ],
                  ),
                  if (granted != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      (granted.shared
                              ? 'session_granted_shared'
                              : 'session_granted')
                          .trParams({
                            'size': '${granted.width}×${granted.height}',
                            'fps': '${granted.fps}',
                          }),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        phase == ConnectionPhase.error
                            ? Icons.error_outline
                            : Icons.info_outline,
                        size: 16,
                        color: phase == ConnectionPhase.error
                            ? Colors.redAccent
                            : const Color(0xFFFFB300),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          error,
                          style: TextStyle(
                            color: phase == ConnectionPhase.error
                                ? Colors.redAccent
                                : const Color(0xFFFFB300),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                // Reverse remote (the Mac controls this tablet): the Mac is
                // the viewer. The remote view opens by itself when the first
                // such tablet goes live; this gets back in after backing
                // out of it.
                if (s.spec.isReverseRemote && phase.isActive) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: FilledButton.icon(
                      onPressed: onOpenRemote,
                      icon: const Icon(Icons.touch_app_outlined),
                      label: Text('home_open_remote'.tr),
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.black,
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }

  /// What the card says went wrong, translated now (so a language switch
  /// reaches it): in `error`, an unplugged tablet in plain words, else the
  /// failure's own text; otherwise what the session noticed about its
  /// capture or its decoder (Extend fell back, the encoder was full on a
  /// rebuild, the Mac could not make a decoder), if anything.
  static String? _errorLine(
    ConnectionPhase phase,
    String? key,
    String message,
    String? notice,
  ) {
    if (phase == ConnectionPhase.error) {
      if (key == 'error_device_gone') return 'session_unplugged'.tr;
      if (key != null) return key.tr;
      if (message.isNotEmpty) return message;
    }
    return notice?.tr;
  }
}

/// The card's menu of what its tablet can run as. Its own tap target inside
/// the card's, so opening it focuses nothing.
///
/// An item acts on the session the menu was opened on: the items are built
/// as it opens and each keeps that session, where the button's own
/// `onSelected` would be the one of whatever widget stands here when the
/// item is pressed, by then perhaps a new session's under the same key.
class _ModeMenu extends StatelessWidget {
  final HostSession session;
  final void Function(HostSession session, SessionChoice choice) onMode;
  const _ModeMenu({required this.session, required this.onMode});

  @override
  Widget build(BuildContext context) {
    final s = session;
    return PopupMenuButton<SessionChoice>(
      key: ValueKey('${s.key}/mode'),
      tooltip: 'session_change_mode'.tr,
      position: PopupMenuPosition.under,
      borderRadius: BorderRadius.circular(20),
      // Its own colours, like the cards': nothing here follows the theme.
      color: const Color(0xFF1F2937),
      surfaceTintColor: Colors.transparent,
      constraints: const BoxConstraints(minWidth: 112, maxWidth: 360),
      itemBuilder: (_) {
        final current = s.effectiveChoice;
        return [
          for (final choice in SessionChoice.all)
            _item(s, current, choice),
        ];
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          Icons.swap_horiz,
          size: 18,
          color: Colors.white.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  /// One choice: checked and not to be pressed when it is what the tablet
  /// runs as, else with what picking it means for the tablet's user.
  PopupMenuItem<SessionChoice> _item(
    HostSession s,
    SessionChoice current,
    SessionChoice choice,
  ) {
    final isCurrent = choice.sameEffect(current);
    return PopupMenuItem<SessionChoice>(
      key: ValueKey(
        '${s.key}/mode/${choice.mode.name}.${choice.direction.name}',
      ),
      value: choice,
      enabled: !isCurrent,
      onTap: () => onMode(s, choice),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: isCurrent
                  ? const Icon(Icons.check, size: 18, color: SessionCard._accent)
                  : null,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    choice.label,
                    style: TextStyle(
                      color: isCurrent ? Colors.white70 : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  if (!isCurrent)
                    Text(
                      _hint(current, choice),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What a change from [from] to [to] asks of the tablet's user. The Mac
  /// cannot do it for them: capturing the tablet's screen takes a tap and a
  /// consent there, and a tablet that was the one viewed stays on its Home
  /// until its view is opened. Named by the tablet's own button labels.
  static String _hint(SessionChoice from, SessionChoice to) {
    if (to.isReverse) {
      return 'session_mode_hint_to_reverse'
          .trParams({'share': 'home_start_share'.tr});
    }
    if (from.isReverse) {
      return 'session_mode_hint_from_reverse'
          .trParams({'open': 'home_open_view'.tr});
    }
    return 'session_mode_hint_restart'.tr;
  }
}

/// A small label in a pill, for the card's link and mode. In less width
/// than its text needs, the text ends in an ellipsis.
class _Chip extends StatelessWidget {
  final IconData? icon;
  final String text;
  const _Chip({required this.text, this.icon});

  @override
  Widget build(BuildContext context) {
    final color = Colors.white.withValues(alpha: 0.6);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          // Cut short where the chip is given less than its text needs
          // (the card's mode chip in a narrow window).
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
