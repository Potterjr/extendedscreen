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
        // On the host show the chosen session mode (picked via the selector
        // below), or with several tablets the app's name and how many —
        // wrapped in Obx so it reacts. The client always shows the static
        // app name, so it must NOT be in an Obx (a builder that reads no
        // observable trips GetX's "improper use").
        title: controller.isHost
            ? Obx(() {
                final count = (cm as HostConnectionManager).sessions.length;
                const style = TextStyle(fontWeight: FontWeight.w600);
                if (count <= 1) {
                  return Text(settings.sessionModeRx.value.label, style: style);
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
      final phases = [for (final s in sessions) s.phase.value];
      final capturing = [for (final s in sessions) s.granted.value]
          .any((g) => g != null);
      // The encoder's load line and the picker's room follow what the
      // encoder is taken to manage, which can be learned while nothing
      // else here changes.
      hub.capacityChanges.value;
      final busy = phases.any((p) => p.isConnecting || p.isActive) ||
          phase.isConnecting ||
          phase.isActive;
      // Mode, direction and link apply to the next connect, and to every
      // tablet at once: only while nothing is under way, and never with
      // several tablets (their sessions keep what they started with).
      final selectors = !busy && sessions.length <= 1;
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
            ..._usb(phase, codecLabel, sessions, busy, selectors, capturing),
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
      if (selectors) ..._selectors(),
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
        if (controller.isReverseRemote) ...[
          _OpenRemoteButton(controller: controller),
          const SizedBox(height: 12),
        ],
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
  /// attached), the selectors while idle, and the add panel.
  List<Widget> _usb(ConnectionPhase phase, String codecLabel,
      List<HostSession> sessions, bool busy, bool selectors, bool capturing) {
    final focusedKey = hub.focusedKey.value;
    final devices = hub.availableDevices.toList();
    final cap = hub.cap;
    final remote = settings.sessionModeRx.value == SessionMode.remoteControl;
    // With one tablet at most (cap 1), picking another one replaces the
    // session there is while it is not under way, as it always has.
    final canPick = hub.canAdd || (cap == 1 && sessions.length <= 1 && !busy);
    // A Disconnect of every tablet (the remote view's, say) is still ending
    // them: the tablets it freed are not short of room, and the facade
    // still reads the phase of a session that has no card any more.
    final ending = hub.endingAll.value;
    final spec = SessionSpec.of(settings, LinkType.usb);
    final free = hub.freeDevices.toList();
    final disabled = <String, String>{
      for (final d in free)
        if (!canPick ||
            !hub.budget.wouldFit(
                settings.captureConfigFor(
                    settings.clientPanelFor(d.serial) ??
                        settings.lastClientPanel,
                    spec),
                cap: cap))
          d.serial: ending
              ? 'home_disconnecting'.tr
              : remote && sessions.isNotEmpty
                  ? 'home_remote_single'.tr
                  : 'home_at_limit'.tr,
    };
    final header = [
      'home_tablets_count'.trParams({'n': '${hub.usbSessionCount}', 'cap': '$cap'}),
      if (capturing)
        'home_encoder_load'.trParams({
          'load': '${(hub.budget.load * 100).round()}',
          'codec': codecLabel,
        }),
    ].join(' · ');
    return [
      if (sessions.isEmpty) ...[
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
          focused: sessions.length > 1 && s.key == focusedKey,
          listed: devices.firstWhereOrNull((d) => d.serial == s.key),
          onFocus: () => controller.onFocus(s.key),
          onStop: controller.onSessionStop,
          onRetry: controller.onSessionRetry,
          onOpenRemote: () {
            controller.onFocus(s.key);
            controller.onOpenRemoteView();
          },
        ),
        const SizedBox(height: 12),
      ],
      if (sessions.isNotEmpty) const SizedBox(height: 4),
      if (selectors) ..._selectors(),
      DevicePickerCard(
        // Snapshots taken here, inside the Obx builder, so GetX subscribes
        // to them. Passing the RxList itself registers nothing (the card
        // reads it in its own build, outside this builder), which left the
        // picker stale after a refresh.
        devices: free,
        title: 'home_add_tablet'.tr,
        header: header,
        emptyText:
            sessions.isNotEmpty ? 'home_all_attached_connected'.tr : null,
        disabledReasons: disabled,
        refreshing: controller.refreshingDevices.value,
        onSelect: controller.onSelectDevice,
        onRefresh: controller.refreshDevices,
      ),
    ];
  }

  /// Session mode, remote direction (remote control only) and link.
  List<Widget> _selectors() => [
        _SessionModeSelector(controller: controller),
        const SizedBox(height: 16),
        if (controller.isRemoteControl) ...[
          _DirectionSelector(controller: controller),
          const SizedBox(height: 16),
        ],
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

class _OpenRemoteButton extends StatelessWidget {
  final HomeController controller;
  const _OpenRemoteButton({required this.controller});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: controller.onOpenRemoteView,
        icon: const Icon(Icons.touch_app_outlined),
        label: Text('home_open_remote'.tr),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF00C8FF),
          foregroundColor: Colors.black,
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

class _DirectionSelector extends StatelessWidget {
  final HomeController controller;
  const _DirectionSelector({required this.controller});

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

/// Host, idle: compact segmented control for which session to run — replaces
/// the old dedicated Launcher screen so switching modes is one tap on Home
/// instead of a forced screen on every launch.
class _SessionModeSelector extends StatelessWidget {
  final HomeController controller;
  const _SessionModeSelector({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final active = controller.sessionMode.value;
      return Row(
        children: SessionMode.values.map((mode) {
          final selected = mode == active;
          return Expanded(
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
