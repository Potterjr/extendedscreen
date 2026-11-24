import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

const _accent = Color(0xFF00C8FF);
const _amber = Color(0xFFFFB300);
const _live = Color(0xFF00E676);

/// Host, Home: one device's session (a tablet over USB, a device on
/// Wi-Fi). Its name, one status line (link, encoded size, rate, round
/// trip), the one action its phase calls for (Disconnect, Cancel, or in
/// `error` Retry beside Cancel), what went wrong in plain words, and its
/// role as a row of chips: what the device is for, picked on the card
/// itself.
///
/// Tapping the card focuses its session: the values the hub shows as its
/// own follow the focused device. Its own `Obx` reads only [session]'s
/// observables (and the settings its codec follows), so one device's
/// latency ticking rebuilds no other card.
class DeviceCard extends StatelessWidget {
  final HostSession session;

  /// This is the hub's focused session: drawn with an accent border.
  final bool focused;

  /// The device list's entry for this tablet, for its model before the
  /// session has listed the device itself.
  final DeviceModel? listed;

  /// Another device on the page has the same model: the status line says
  /// the serial, so the two can be told apart. (Over Wi-Fi it always says
  /// the address.)
  final bool showSerial;

  final VoidCallback onFocus;
  final ValueChanged<String> onStop;
  final ValueChanged<String> onRetry;

  /// The Mac controls this device: reopen the remote view on it.
  final VoidCallback onOpenRemote;

  /// Picture settings: the device's own settings sheet.
  final VoidCallback onPictureSettings;

  /// A role chip's press: the session the chip was built for (not
  /// whichever one holds this card by the time the finger comes up) and
  /// the role picked. Null: no chip can be pressed (every session is being
  /// ended).
  final void Function(HostSession session, SessionChoice choice)? onRole;

  const DeviceCard({
    super.key,
    required this.session,
    required this.focused,
    required this.onFocus,
    required this.onStop,
    required this.onRetry,
    required this.onOpenRemote,
    required this.onPictureSettings,
    this.onRole,
    this.listed,
    this.showSerial = false,
  });

  /// The roles [s] can be given: all three over USB for an Android
  /// tablet; never "the Mac controls this device" over Wi-Fi or for an
  /// iPhone or iPad, whose input the Mac cannot inject (adb does it), as
  /// [SessionChoice.effective] says.
  static List<SessionChoice> choicesFor(HostSession s) => [
    for (final c in SessionChoice.all)
      if (!c.isReverse || (s.link == LinkType.usb && !s.isApple)) c,
  ];

  /// What a change from [from] to [to] asks of the device's user, as the
  /// chip's tooltip. The Mac cannot do it for them: capturing the tablet's
  /// screen takes a tap and a consent there, and a tablet that was the one
  /// viewed stays on its Home until its view is opened. Named by the
  /// tablet's own button labels.
  static String hint(SessionChoice from, SessionChoice to) {
    if (to.isReverse) {
      return 'session_mode_hint_to_reverse'.trParams({
        'share': 'home_start_share'.tr,
      });
    }
    if (from.isReverse) {
      return 'session_mode_hint_from_reverse'.trParams({
        'open': 'home_open_view'.tr,
      });
    }
    return 'session_mode_hint_restart'.tr;
  }

  /// The status line's words for [phase] when the session is not live, in
  /// plain language: no protocol step names.
  static String statusFor(
    ConnectionPhase phase, {
    required bool refused,
    required bool retrying,
  }) {
    if (phase == ConnectionPhase.handshaking) {
      // Waiting for the device to dial in (its app opened, or the key adb
      // handed it taken).
      return 'home_status_waiting_app'.tr;
    }
    if (phase.isConnecting) return 'home_status_connecting'.tr;
    if (phase == ConnectionPhase.error) {
      if (refused) return 'home_status_waiting_you'.tr;
      if (retrying) return 'home_status_retrying'.tr;
    }
    return 'home_status_not_connected'.tr;
  }

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
      final problem = _problem(
        phase,
        s.errorKey.value,
        s.errorMessage.value,
        s.notice.value,
      );
      final latency = s.latencyMs.value;
      final hz = s.refreshRateHz.value;
      final bitrate = s.streamBitrate.value;
      final refused = s.refused.value;
      final retrying = s.retryPending.value;
      // The card reads the device's own settings, which can change while
      // nothing of the session does.
      settings.codecRx.value;
      settings.deviceProfiles.value;
      final current = s.effectiveChoice;
      final status = <String>[
        s.link.chipLabel,
        // Over Wi-Fi the device's address, always: two devices with the
        // same model would look alike.
        if (wifi && device != null) device.serial,
        if (!wifi && showSerial) s.key,
        if (phase.isActive) ...[
          if (granted != null) '${granted.width}×${granted.height}',
          '$hz fps',
          '$latency ms',
          if (bitrate != null)
            '${(bitrate / 1000000).toStringAsFixed(bitrate < 10000000 ? 1 : 0)} Mbps',
          if (granted?.shared == true) 'home_status_shared'.tr,
        ] else
          statusFor(phase, refused: refused, retrying: retrying),
      ].join(' · ');
      final reverseLive = s.spec.isReverseRemote && phase.isActive;
      final ownProfile = SettingsService.hasOwnProfile(s.key);
      // A role changes by replacing the session, which the hub does for one
      // that is live or waits in `error`, not for one on its way to being
      // live, and on Wi-Fi only for a device beside the tablets.
      final canChange =
          onRole != null &&
          (phase.isActive || phase == ConnectionPhase.error) &&
          (!wifi || s.beside);
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onFocus,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
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
                Row(
                  children: [
                    Icon(
                      switch (s.platform) {
                        HostSession.helloPlatformIphone => Icons.phone_iphone,
                        HostSession.helloPlatformIpad => Icons.tablet_mac,
                        _ =>
                          model == 'iPhone'
                              ? Icons.phone_iphone
                              : Icons.tablet_android,
                      },
                      color: _accent,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            model ??
                                (s.beside ? 'session_wifi_beside'.tr : s.key),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: phase.isActive
                                      ? _live
                                      : phase == ConnectionPhase.error
                                      ? Colors.redAccent
                                      : phase.isConnecting
                                      ? _accent
                                      : Colors.white38,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  status,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ..._actions(s.key, phase),
                  ],
                ),
                if (problem != null) ...[
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
                            : _amber,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          problem,
                          style: TextStyle(
                            color: phase == ConnectionPhase.error
                                ? Colors.redAccent
                                : _amber,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                // Keyed by the session object: when the hub replaces the
                // session under this same card, the chips are new elements,
                // so a press that began on the old session's chip does
                // nothing.
                KeyedSubtree(
                  key: ObjectKey(s),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in choicesFor(s))
                        RoleChip(
                          key: ValueKey(
                            '${s.key}/role/${c.mode.name}.${c.direction.name}',
                          ),
                          choice: c,
                          selected: c.sameEffect(current),
                          enabled: !c.sameEffect(current) && canChange,
                          hint: c.sameEffect(current) ? null : hint(current, c),
                          // Built now, so it carries this session.
                          onPressed: !c.sameEffect(current) && canChange
                              ? () => onRole!(s, c)
                              : null,
                        ),
                    ],
                  ),
                ),
                if (ownProfile || reverseLive) ...[
                  const SizedBox(height: 8),
                  // A Wrap, not a Row with a Spacer: the Spacer's share of
                  // the row cut Picture settings short beside Open remote.
                  // Each button keeps its whole label; when the two do not
                  // fit side by side, Open remote goes onto the next line.
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      // This device's own settings (preset, codec, text
                      // size, frame-rate cap), for a device that is the same
                      // one next time.
                      if (ownProfile)
                        TextButton.icon(
                          key: ValueKey('${s.key}/settings'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.tune, size: 16),
                          label: Text(
                            'home_picture_settings'.tr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: onPictureSettings,
                        ),
                      // The Mac controls this device: the Mac is the
                      // viewer. The remote view opens by itself when the
                      // first such device goes live; this gets back in
                      // after backing out of it.
                      if (reverseLive)
                        FilledButton.icon(
                          key: ValueKey('${s.key}/open-remote'),
                          onPressed: onOpenRemote,
                          icon: const Icon(Icons.touch_app_outlined, size: 18),
                          label: Text(
                            'home_open_remote'.tr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.black,
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }

  /// The one action the phase calls for. Keyed by the device and by what
  /// the button reads, so when the phase changes under a finger the button
  /// is replaced and the touch does nothing.
  List<Widget> _actions(String key, ConnectionPhase phase) {
    Widget button(String label, Color color, VoidCallback onPressed) =>
        TextButton(
          key: ValueKey('$key/$label'),
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: color,
            visualDensity: VisualDensity.compact,
          ),
          child: Text(label.tr),
        );
    if (phase.isActive) {
      return [button('common_disconnect', Colors.redAccent, () => onStop(key))];
    }
    if (phase.isConnecting) {
      return [button('common_cancel', Colors.white70, () => onStop(key))];
    }
    if (phase == ConnectionPhase.error) {
      // In `error` always: a session the encoder refused waits for it, and
      // one waiting out its retry's backoff runs that retry now.
      return [
        button('common_cancel', Colors.white70, () => onStop(key)),
        button('common_retry', _accent, () => onRetry(key)),
      ];
    }
    return const [];
  }

  /// What the card says went wrong, translated now (so a language switch
  /// reaches it): in `error`, an unplugged tablet in plain words, else the
  /// failure's own text; otherwise what the session noticed about its
  /// capture or its decoder (Extend fell back, the encoder was full on a
  /// rebuild, the Mac could not make a decoder), if anything.
  static String? _problem(
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

/// One role a device can be given, as a chip on its card. The [selected]
/// one is what it runs as and cannot be pressed; the others say, in their
/// tooltip ([hint]), what the change asks of the device's user.
class RoleChip extends StatelessWidget {
  final SessionChoice choice;
  final bool selected;
  final bool enabled;
  final String? hint;
  final VoidCallback? onPressed;

  const RoleChip({
    super.key,
    required this.choice,
    required this.selected,
    required this.enabled,
    this.hint,
    this.onPressed,
  });

  static IconData iconFor(SessionChoice c) => c.isReverse
      ? Icons.cast_outlined
      : c.mode == SessionMode.remoteControl
      ? Icons.touch_app_outlined
      : Icons.desktop_windows_outlined;

  @override
  Widget build(BuildContext context) {
    final chip = Opacity(
      opacity: !selected && !enabled ? 0.45 : 1,
      child: Material(
        color: selected
            ? _accent.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: enabled ? onPressed : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected
                    ? _accent
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  iconFor(choice),
                  size: 15,
                  color: selected ? _accent : Colors.white60,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    choice.roleLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontSize: 13,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return hint == null ? chip : Tooltip(message: hint!, child: chip);
  }
}
