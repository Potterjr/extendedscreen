import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/host_session.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/models/session_choice.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/models/session_spec.dart';
import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/battery_chip.dart';
import 'package:extendedscreen/shared/widgets/confirm_dialog.dart';
import 'package:extendedscreen/shared/widgets/connection_card.dart';
import 'package:extendedscreen/shared/widgets/connection_steps.dart';
import 'package:extendedscreen/shared/widgets/device_info_card.dart';
import 'package:extendedscreen/shared/widgets/device_picker_card.dart';
import 'package:extendedscreen/shared/widgets/latency_chip.dart';
import 'package:extendedscreen/shared/widgets/session_card.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    final cm = Get.find<BaseConnectionManager>();
    final settings = Get.find<SettingsService>();

    return Scaffold(
      appBar: AppBar(
        // On the host: with no tablet, the mode the next one would run in
        // (picked in the add panel below); with one, that tablet's own mode
        // (a session keeps the mode it was made for, whatever the selector
        // says by now); with several, the app's name and how many. Wrapped
        // in Obx so it reacts. The client always shows the static app name,
        // so it must NOT be in an Obx (a builder that reads no observable
        // trips GetX's "improper use").
        title: controller.isHost
            ? Obx(() {
                // A session beside the tablets that only listens on Wi-Fi
                // is no device yet.
                final sessions = [
                  for (final s
                      in (cm as HostConnectionManager).sessions.values)
                    if (!HostConnectionManager.isListening(s)) s,
                ];
                final count = sessions.length;
                const style = TextStyle(fontWeight: FontWeight.w600);
                if (count == 0) {
                  return Text(settings.sessionModeRx.value.label, style: style);
                }
                if (count == 1) {
                  return Text(sessions.single.effectiveChoice.label,
                      style: style);
                }
                return Row(
                  children: [
                    Text('app_name'.tr, style: style),
                    const SizedBox(width: 10),
                    Text(
                      'home_appbar_tablets'.trParams({'n': '$count'}),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 14,
                      ),
                    ),
                  ],
                );
              })
            : Text(
                'app_name'.tr,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
        actions: [
          // Debug builds with synthetic tablets only (a const condition).
          if (synthTablets && controller.isHost)
            IconButton(
              icon: const Icon(Icons.grid_view_outlined),
              tooltip: 'loopback_preview_title'.tr,
              onPressed: () => Get.toNamed(AppRoutes.loopbackPreview),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: controller.onGoToSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: controller.isHost
            ? _HostBody(
                hub: cm as HostConnectionManager,
                controller: controller,
                settings: settings,
              )
            : _ClientBody(cm: cm, controller: controller, settings: settings),
      ),
    );
  }
}

/// The tablet's Home: its one link to the Mac.
class _ClientBody extends StatelessWidget {
  final BaseConnectionManager cm;
  final HomeController controller;
  final SettingsService settings;
  const _ClientBody(
      {required this.cm, required this.controller, required this.settings});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final phase = cm.phase.value;
      final wifi = settings.linkTypeRx.value == LinkType.wifi;
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ConnectionCard(
            phase: phase,
            onTap: controller.onConnectTap,
            codecLabel:
                settings.codecRx.value == CodecType.h265 ? 'H.265' : 'H.264',
            wifi: wifi,
          ),
          const SizedBox(height: 16),
          // Charging is the same USB-C cable as the data link but isn't
          // implied by it — show it plainly instead of leaving it silent.
          Obx(() {
            final status = controller.batteryStatus.value;
            if (status == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: BatteryChip(
                  isCharging: status.isCharging,
                  level: status.level,
                ),
              ),
            );
          }),
          // Where to dial. Hidden during a session; while waiting for the
          // Mac (the client's usual state) it stays put, so a tablet set to
          // the wrong link can be switched without stopping. iOS has no
          // choice to make: it is always Wi-Fi.
          if (!phase.isActive) ...[
            if (!runsOnIos) ...[
              _LinkTypeSelector(controller: controller),
              const SizedBox(height: 16),
            ],
            if (wifi) ...[
              _WifiClientCard(
                controller: controller,
                // A snapshot taken inside this Obx (see the host's picker).
                hosts: controller.pairedHosts,
              ),
              const SizedBox(height: 16),
            ],
          ],
          // Only while actively connecting — the ConnectionCard above
          // already states disconnected/error/streaming on its own, so
          // showing this too in those phases just duplicates it.
          if (phase.isConnecting) ...[
            ConnectionSteps(phase: phase, wifi: wifi),
            const SizedBox(height: 20),
          ],
          // Reverse remote (Mac controls this tablet): the tablet is the
          // capture source, so offer a screen-share button instead of the
          // "open view" button (there is no incoming video to open).
          if (controller.needsScreenShare.value ||
              controller.isScreenSharing.value)
            _ShareScreenButton(controller: controller)
          else
            _OpenViewButton(controller: controller, phase: phase),
          const SizedBox(height: 12),
          if (phase.isActive)
            LatencyChip(
                latencyMs: cm.latencyMs.value,
                wifi: wifi,
                bitrate: cm.streamBitrate.value),
          if (phase == ConnectionPhase.error) ...[
            const SizedBox(height: 16),
            _ErrorBanner(message: cm.errorMessage.value),
          ],
        ],
      );
    });
  }
}

/// The Mac's Home. Over Wi-Fi, one session shown through the hub's facade,
/// as it has always been. Over USB, a card per tablet, and the panel that
/// adds another (always on screen, so a second tablet is one tap away).
class _HostBody extends StatelessWidget {
  final HostConnectionManager hub;
  final HomeController controller;
  final SettingsService settings;
  const _HostBody(
      {required this.hub, required this.controller, required this.settings});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final phase = hub.phase.value;
      final wifi = settings.linkTypeRx.value == LinkType.wifi;
      final codecLabel =
          settings.codecRx.value == CodecType.h265 ? 'H.265' : 'H.264';
      final sessions = hub.sessions.values.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      // Every session's phase and grant read here, so this builder hears
      // each of them change (the facade follows only the focused one).
      for (final s in sessions) {
        s.phase.value;
      }
      final capturing = [
        for (final s in sessions) s.granted.value,
      ].any((g) => g != null);
      // The session beside the USB tablets that only listens for a device
      // on Wi-Fi is under way for nobody: it neither hides the selectors
      // nor counts as a tablet here (its card still shows).
      final engaged = [
        for (final s in sessions)
          if (!HostConnectionManager.isListening(s)) s,
      ];
      // The encoder's load line and the picker's room follow what the
      // encoder is taken to manage, which can be learned while nothing
      // else here changes.
      hub.capacityChanges.value;
      final busy =
          engaged.any(
            (s) => s.phase.value.isConnecting || s.phase.value.isActive,
          ) ||
          phase.isConnecting ||
          phase.isActive;
      // The link is every tablet's at once: its selector shows only while
      // nothing is under way, and never with several tablets. Mode and
      // direction say what the next session made runs as, and a session
      // that exists keeps what it was made for. Over USB they sit in the
      // add panel, always: they are part of adding a tablet, and a tablet
      // that has a card changes mode from that card's menu. Over Wi-Fi,
      // where there is one session and no card, they go with the link
      // selector, and a change reaches a session that waits to retry by
      // replacing it (HomeController.onSelectSessionMode).
      // Nor while a tablet is between two sessions (its mode being changed
      // from its card): it is in none of [sessions] for a moment, the hub
      // acts on no link change meanwhile, and it comes back over USB.
      final selectors = !busy && engaged.length <= 1 && !hub.replacing;
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (controller.missingPermissions.isNotEmpty) ...[
            _PermissionBanner(
              onGrant: () => controller
                  .onGrantPermission(controller.missingPermissions.first),
            ),
            const SizedBox(height: 16),
          ],
          if (wifi)
            ..._wifi(phase, codecLabel, selectors)
          else
            ..._usb(
              phase,
              codecLabel,
              sessions,
              engaged,
              busy,
              selectors,
              capturing,
            ),
        ],
      );
    });
  }

  /// Over Wi-Fi: the one session through the facade, laid out as before
  /// several tablets existed. Its stop is the card's [HomeController
  /// .onConnectTap], which also pauses the auto-connect.
  List<Widget> _wifi(ConnectionPhase phase, String codecLabel, bool selectors) {
    return [
      ConnectionCard(
        phase: phase,
        onTap: controller.onConnectTap,
        // There is no device to pick, so the button starts listening; in
        // `error` the host retries on its own and the card offers Cancel.
        canConnect: phase == ConnectionPhase.disconnected,
        codecLabel: codecLabel,
        wifi: true,
      ),
      const SizedBox(height: 16),
      if (selectors) ...[..._modeSelectors(), ..._linkSelector()],
      // Where the tablet finds this Mac. Not part of the idle-only block
      // above: listening is a connecting phase, and that is exactly when the
      // address is needed (to type on a tablet that can't find the Mac by
      // itself).
      if (!phase.isActive) ...[
        // Snapshot for the same reason as the picker's list.
        _WifiHostCard(addresses: controller.localAddresses.toList()),
        const SizedBox(height: 16),
      ],
      if (phase.isActive) ...[
        DeviceInfoCard(device: hub.activeDevice.value),
        const SizedBox(height: 12),
        LatencyChip(
            latencyMs: hub.latencyMs.value,
            wifi: true,
            bitrate: hub.streamBitrate.value),
      ],
      if (phase == ConnectionPhase.error) ...[
        const SizedBox(height: 16),
        _ErrorBanner(message: hub.errorMessage.value),
      ],
    ];
  }

  /// Over USB: a card per tablet (with none, the facade's card, which says
  /// what the hub is doing: looking for a device, or that none is
  /// attached), the link selector while idle, and the add panel, which
  /// holds the mode the next tablet added runs in above its tiles.
  List<Widget> _usb(
    ConnectionPhase phase,
    String codecLabel,
    List<HostSession> sessions,
    List<HostSession> engaged,
    bool busy,
    bool selectors,
    bool capturing,
  ) {
    final focusedKey = hub.focusedKey.value;
    final devices = hub.availableDevices.toList();
    final cap = hub.cap;
    // With one tablet at most (cap 1), picking another one replaces the
    // session there is while it is not under way, as it always has.
    final canPick = hub.canAdd || (cap == 1 && engaged.length <= 1 && !busy);
    // A Disconnect of every tablet (the remote view's, say) is still ending
    // them: the tablets it freed are not short of room, and the facade
    // still reads the phase of a session that has no card any more.
    final ending = hub.endingAll.value;
    // What a tile pressed now would run as: the selectors' choice, read
    // through their observables so this builder follows them.
    final next = SessionSpec.from(
        SessionChoice(
            settings.sessionModeRx.value, settings.remoteDirectionRx.value),
        LinkType.usb,
        displayMode: settings.displayMode);
    final free = hub.freeDevices.toList();
    // What a tablet the Mac has had before ran as last time, which is what
    // it comes back as when it connects by itself. A press on its tile
    // asks for the mode chosen above the tiles instead, so the tile says
    // which one the tablet is used to. The known list is not observable;
    // reading it at each build is enough, since a tablet's entry changes
    // only while it has a session (as it goes live, or when its mode is
    // changed from its card), and its tile is back only once that session
    // has left the map this builder follows.
    final known = free.isEmpty
        ? const <String, SessionChoice?>{}
        : {for (final k in settings.knownDevices) k.serial: k.choice};
    final lastModes = <String, String>{
      for (final d in free)
        if (known[d.serial] case final last?)
          d.serial: 'home_tile_last_mode'.trParams({'mode': last.label}),
    };
    final disabled = <String, String>{
      for (final d in free)
        // A tablet the Mac only views takes nothing of the encoder: it
        // needs a place, and no room there.
        if (!canPick ||
            (!next.isReverseRemote &&
                !hub.budget.wouldFit(
                    settings.captureConfigFor(
                        settings.clientPanelFor(d.serial) ??
                            settings.lastClientPanel,
                        next),
                    cap: cap)))
          d.serial: ending ? 'home_disconnecting'.tr : 'home_at_limit'.tr,
    };
    // Places in use: a tablet between two sessions holds its own.
    final header = [
      'home_tablets_count'.trParams({
        'n': '${hub.heldPlaces.length}',
        'cap': '$cap',
      }),
      if (capturing)
        'home_encoder_load'.trParams({
          'load': '${(hub.budget.load * 100).round()}',
          'codec': codecLabel,
        }),
    ].join(' · ');
    return [
      if (engaged.isEmpty) ...[
        ConnectionCard(
          // Nothing left to stop while every session ends: no Disconnect
          // for a session that has gone.
          phase: ending ? ConnectionPhase.disconnected : phase,
          onTap: controller.onConnectTap,
          // Over USB the host connects by picking a device, not here; in
          // `error` (no device yet, looked for again every second) the card
          // offers Cancel.
          canConnect: false,
          codecLabel: codecLabel,
        ),
        if (phase == ConnectionPhase.error) ...[
          const SizedBox(height: 16),
          _ErrorBanner(message: hub.errorMessage.value),
        ],
        const SizedBox(height: 16),
      ],
      for (final s in sessions) ...[
        SessionCard(
          key: ValueKey('session/${s.key}'),
          session: s,
          focused: engaged.length > 1 && s.key == focusedKey,
          listed: devices.firstWhereOrNull((d) => d.serial == s.key),
          onFocus: () => controller.onFocus(s.key),
          onStop: controller.onSessionStop,
          onRetry: controller.onSessionRetry,
          // The remote view shows every tablet the Mac controls; the key
          // only says which tile to show alone. The hub's focus stays.
          onOpenRemote: () => controller.onOpenRemoteView(key: s.key),
          // Not while every session is being ended: the hub would refuse.
          onMode: ending ? null : controller.onSessionMode,
        ),
        const SizedBox(height: 12),
      ],
      if (sessions.isNotEmpty) const SizedBox(height: 4),
      // No link selector on the Mac: USB always runs, and Wi-Fi is the add
      // panel's switch.
      DevicePickerCard(
        // Snapshots taken here, inside the Obx builder, so GetX subscribes
        // to them. Passing the RxList itself registers nothing (the card
        // reads it in its own build, outside this builder), which left the
        // picker stale after a refresh.
        devices: free,
        title: 'home_add_tablet'.tr,
        header: header,
        // A tablet between two sessions is attached, and on its way back.
        emptyText: engaged.isNotEmpty || hub.replacing
            ? 'home_all_attached_connected'.tr
            : null,
        disabledReasons: disabled,
        subtitles: lastModes,
        // Always there, whatever the tablets are doing: it changes none of
        // them, only what the next press on a tile below asks for.
        leading: [
          Padding(
            key: const ValueKey('next/caption'),
            padding: const EdgeInsets.only(left: 4, top: 10, bottom: 8),
            child: Text(
              'home_next_tablet_mode'.tr,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ..._modeSelectors(gap: 12),
          _WifiListenSwitch(
            key: const ValueKey('next/wifi-listen'),
            on: settings.wifiListenRx.value,
            listening: hub.listening.value,
            addresses: controller.localAddresses.toList(),
            turnedAway: hub.wifiTurnedAway.value,
            onChanged: controller.onWifiListen,
          ),
        ],
        refreshing: controller.refreshingDevices.value,
        onSelect: controller.onSelectDevice,
        onRefresh: controller.refreshDevices,
      ),
    ];
  }

  /// What the next session made runs as: session mode and, for remote
  /// control, the direction, each followed by [gap]. Keyed, since the
  /// direction comes and goes with the mode.
  List<Widget> _modeSelectors({double gap = 16}) => [
        _SessionModeSelector(
            key: const ValueKey('next/mode'), controller: controller),
        SizedBox(key: const ValueKey('next/mode/gap'), height: gap),
        if (controller.isRemoteControl) ...[
          _DirectionSelector(
              key: const ValueKey('next/dir'), controller: controller),
          SizedBox(key: const ValueKey('next/dir/gap'), height: gap),
        ],
      ];

  /// USB or Wi-Fi.
  List<Widget> _linkSelector() => [
        _LinkTypeSelector(controller: controller),
        const SizedBox(height: 16),
      ];
}

class _OpenViewButton extends StatelessWidget {
  final HomeController controller;
  final ConnectionPhase phase;
  const _OpenViewButton({required this.controller, required this.phase});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: phase.isActive ? controller.onOpenView : null,
        icon: const Icon(Icons.open_in_full),
        label: Text(
          phase.isActive ? 'home_open_view'.tr : 'home_waiting_for_stream'.tr,
        ),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF00C8FF),
          foregroundColor: Colors.black,
          disabledBackgroundColor: Colors.white12,
          disabledForegroundColor: Colors.white38,
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
    );
  }
}

class _ShareScreenButton extends StatelessWidget {
  final HomeController controller;
  const _ShareScreenButton({required this.controller});

  @override
  Widget build(BuildContext context) {
    final sharing = controller.isScreenSharing.value;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: sharing ? null : controller.onStartScreenShare,
            icon: Icon(sharing ? Icons.cast_connected : Icons.screen_share),
            label: Text(sharing ? 'home_sharing'.tr : 'home_start_share'.tr),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00C8FF),
              foregroundColor: Colors.black,
              disabledBackgroundColor: const Color(0xFF00C8FF),
              disabledForegroundColor: Colors.black,
              textStyle:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          sharing ? 'home_sharing_hint'.tr : 'home_start_share_hint'.tr,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}

/// Host, with remote control chosen for the next session: which side drives
/// it. Options keyed `next/dir/<name>`.
class _DirectionSelector extends StatelessWidget {
  final HomeController controller;
  const _DirectionSelector({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'remote_dir_title'.tr,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Obx(() {
          // Over Wi-Fi only tablet → Mac exists (the other way injects input
          // with `adb shell input`), so that one shows as chosen and the
          // other is greyed out, whatever was saved for USB.
          final wifi = controller.isWifi;
          final active = controller.effectiveDirection;
          return Row(
            children: RemoteDirection.values.map((dir) {
              final selected = dir == active;
              final available = !(wifi && dir.isReverse);
              return Expanded(
                key: ValueKey('next/dir/${dir.name}'),
                child: Padding(
                  padding: EdgeInsets.only(
                      right: dir == RemoteDirection.values.first ? 8 : 0),
                  child: Opacity(
                    opacity: available ? 1 : 0.45,
                    child: Material(
                      color: selected
                          ? const Color(0xFF00C8FF).withValues(alpha: 0.16)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: available
                            ? () => controller.onSelectDirection(dir)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected
                                  ? const Color(0xFF00C8FF)
                                  : Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                dir.label,
                                style: TextStyle(
                                  color:
                                      selected ? Colors.white : Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                available
                                    ? dir.description
                                    : 'remote_dir_usb_only'.tr,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        }),
      ],
    );
  }
}

/// USB or Wi-Fi. On the host it sits with the other idle-only selectors; on
/// the client it shows whenever no session is live.
class _LinkTypeSelector extends StatelessWidget {
  final HomeController controller;
  const _LinkTypeSelector({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final active = controller.linkType.value;
      return Row(
        children: LinkType.values.map((type) {
          final selected = type == active;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: type == LinkType.values.first ? 8 : 0,
              ),
              child: Material(
                color: selected
                    ? const Color(0xFF00C8FF).withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => controller.onSelectLinkType(type),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF00C8FF)
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          type == LinkType.wifi ? Icons.wifi : Icons.usb,
                          size: 20,
                          color: selected
                              ? const Color(0xFF00C8FF)
                              : Colors.white54,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                type.label,
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                type.description,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
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
            ),
          );
        }).toList(),
      );
    });
  }
}

/// Host, Wi-Fi, idle: where the tablet will find this Mac, and the one thing
/// the user has to know (pair over USB first). Takes the place of the device
/// picker, since over Wi-Fi there is no device list to pick from.
///
/// Plain widget over a snapshot, like [DevicePickerCard].
class _WifiHostCard extends StatelessWidget {
  final List<String> addresses;
  const _WifiHostCard({required this.addresses});

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
          Text(
            'wifi_host_title'.tr,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.wifi, color: Color(0xFF00C8FF), size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  addresses.isEmpty
                      ? 'wifi_host_no_network'.tr
                      : 'wifi_host_address'.trParams({
                          'address': addresses.join(', '),
                          'port': '${BaseConnectionManager.port}',
                        }),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'wifi_host_hint'.tr,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Client, Wi-Fi: whether this tablet can reach a Mac at all (it has to have
/// been paired over USB), each paired Mac with a button to forget it, plus a
/// field for the Mac's address on networks where discovery finds nothing.
///
/// Stateful only to own the text field's controller, so Home rebuilding on
/// every phase change doesn't reset what is being typed.
class _WifiClientCard extends StatefulWidget {
  final HomeController controller;

  /// The paired Macs, read inside Home's `Obx`.
  final List<PairedHost> hosts;

  const _WifiClientCard({required this.controller, required this.hosts});

  @override
  State<_WifiClientCard> createState() => _WifiClientCardState();
}

class _WifiClientCardState extends State<_WifiClientCard> {
  late final _address = TextEditingController(
    text: widget.controller.wifiHostAddress,
  );

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  /// Forgetting is not undone from here (it takes a USB session), so ask.
  Future<void> _forget(PairedHost host) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'wifi_forget_title'.trParams({'name': host.name}),
      message: 'wifi_forget_message'.tr,
      confirmLabel: 'wifi_forget_confirm'.tr,
    );
    if (confirmed) await widget.controller.onForgetHost(host.id);
  }

  @override
  Widget build(BuildContext context) {
    final paired = widget.hosts.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'wifi_client_title'.tr,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          if (!paired)
            Row(
              children: [
                const Icon(Icons.usb, color: Color(0xFFFFB300), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    (runsOnIos
                            ? 'wifi_client_not_paired_ios'
                            : 'wifi_client_not_paired')
                        .tr,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ],
            ),
          for (final host in widget.hosts)
            Row(
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  color: Color(0xFF00E676),
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'wifi_client_paired'.trParams({'name': host.name}),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                IconButton(
                  // Keyed by the Mac, so a row that moves up when another is
                  // forgotten is not mistaken for the one that was pressed.
                  key: ValueKey('forget-${host.id}'),
                  icon: const Icon(Icons.link_off, size: 20),
                  color: Colors.white54,
                  tooltip: 'wifi_client_forget'.tr,
                  onPressed: () => _forget(host),
                ),
              ],
            ),
          if (paired) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: widget.controller.onSetWifiHostAddress,
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
                widget.controller.onSaveWifiHostAddress(_address.text);
              },
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                labelText: 'wifi_client_address_label'.tr,
                helperText: 'wifi_client_address_hint'.tr,
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Host: compact segmented control for what the next session made runs as
/// (one tap on Home, not a launcher screen). Over USB it sits in the add
/// panel, over Wi-Fi with the link selector. Options keyed by what they
/// choose (`next/mode/<name>`).
class _SessionModeSelector extends StatelessWidget {
  final HomeController controller;
  const _SessionModeSelector({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final active = controller.sessionMode.value;
      return Row(
        children: SessionMode.values.map((mode) {
          final selected = mode == active;
          return Expanded(
            key: ValueKey('next/mode/${mode.name}'),
            child: Padding(
              padding: EdgeInsets.only(
                  right: mode == SessionMode.values.first ? 8 : 0),
              child: Material(
                color: selected
                    ? const Color(0xFF00C8FF).withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => controller.onSelectSessionMode(mode),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF00C8FF)
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mode.label,
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          mode.description,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      );
    });
  }
}

/// Host: inline "grant permissions" prompt shown directly on Home when Screen
/// Recording / Accessibility is missing. Replaces the old fail → snackbar →
/// navigate-to-Settings-and-back detour — the user grants without leaving
/// Home, and the banner clears itself on app resume once granted.
class _PermissionBanner extends StatelessWidget {
  final VoidCallback onGrant;
  const _PermissionBanner({required this.onGrant});

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFFFB300);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, color: amber, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'perm_required_title'.tr,
                  style: const TextStyle(
                      color: amber, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  'perm_required_msg'.tr,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onGrant,
            style: TextButton.styleFrom(foregroundColor: amber),
            child: Text('common_open'.tr),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// The add panel's "Listen on Wi-Fi" switch: while it is on, the Mac also
/// takes paired devices on Wi-Fi (an iPhone, a tablet set to Wi-Fi) beside
/// the USB tablets, each in a place of its own under Maximum tablets. While
/// it listens it says where (the Mac's addresses, to type on a device that
/// cannot find it), and how many devices it had no place for.
class _WifiListenSwitch extends StatelessWidget {
  final bool on;
  final bool listening;
  final List<String> addresses;
  final int turnedAway;
  final ValueChanged<bool> onChanged;
  const _WifiListenSwitch({
    super.key,
    required this.on,
    required this.listening,
    required this.addresses,
    required this.turnedAway,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // A Material of its own: the card it sits in paints its colour on a
    // plain box, which a list tile's ink would be drawn under.
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        value: on,
        onChanged: onChanged,
        secondary: const Icon(Icons.wifi, color: Colors.white70, size: 20),
        title: Text(
          'home_wifi_listen'.tr,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          [
            if (on && listening && addresses.isNotEmpty)
              'home_wifi_listening_at'
                  .trParams({'addr': addresses.join(', ')})
            else
              'home_wifi_listen_desc'.tr,
            if (on && turnedAway > 0)
              'home_wifi_turned_away'.trParams({'n': '$turnedAway'}),
          ].join('\n'),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
