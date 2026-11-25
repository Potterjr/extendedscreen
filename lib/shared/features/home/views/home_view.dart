import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/app/routes/app_routes.dart';
import 'package:extendedscreen/shared/connection/debug/synthetic_tablet.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/connection/host_connection_manager.dart';
import 'package:extendedscreen/shared/connection/wifi_pairing_service.dart';
import 'package:extendedscreen/shared/models/device_model.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/link_type.dart';
import 'package:extendedscreen/shared/platform/ios_app.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/add_device_panel.dart';
import 'package:extendedscreen/shared/widgets/battery_chip.dart';
import 'package:extendedscreen/shared/widgets/confirm_dialog.dart';
import 'package:extendedscreen/shared/widgets/connection_card.dart';
import 'package:extendedscreen/shared/widgets/connection_steps.dart';
import 'package:extendedscreen/shared/widgets/device_card.dart';
import 'package:extendedscreen/shared/widgets/device_settings_sheet.dart';
import 'package:extendedscreen/shared/widgets/iphone_usb_card.dart';
import 'package:extendedscreen/shared/widgets/latency_chip.dart';
import 'package:extendedscreen/shared/widgets/role_chooser.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    final cm = Get.find<BaseConnectionManager>();
    final settings = Get.find<SettingsService>();

    return Scaffold(
      appBar: AppBar(
        // The same plain title on both sides, never in an Obx (a builder
        // that reads no observable trips GetX's "improper use"): the host's
        // devices and their roles are on their cards.
        title: Text(
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

/// The Mac's Home: a card per device (each session, whatever its link, and
/// each iPhone or iPad plugged in over USB), then the panel that adds one:
/// the devices found and not connected, and accepting devices over Wi-Fi.
/// What a device is for (its role) is chosen on its own card, or when a new
/// one is connected; nothing on the page says what the next one runs as.
class _HostBody extends StatelessWidget {
  final HostConnectionManager hub;
  final HomeController controller;
  final SettingsService settings;
  const _HostBody(
      {required this.hub, required this.controller, required this.settings});

  /// The Connect of a new device, or of a remembered one whose remembered
  /// role the encoder has no room for: its role first (the remembered one,
  /// else the default, preselected), then the connect, in that role.
  /// Cancelled, nothing is connected. The pick is checked again by the
  /// controller, since the page can change under the dialog.
  Future<void> _choose(BuildContext context, DeviceModel d) async {
    final picked = await RoleChooser.show(
      context,
      device: d,
      preselected: settings.knownChoice(d.serial) ?? settings.nextChoice,
      fits: (c) => controller.fitsEncoder(d.serial, c),
    );
    if (picked != null) await controller.onConnectDevice(d, choice: picked);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final codecLabel = settings.codecRx.value == CodecType.h265
          ? 'H.265'
          : 'H.264';
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
      // The encoder's load line and the rows' room follow what the encoder
      // is taken to manage, which can be learned while nothing else here
      // changes; and a device's own settings change what it would encode.
      hub.capacityChanges.value;
      settings.deviceProfiles.value;
      final focusedKey = hub.focusedKey.value;
      final devices = hub.availableDevices.toList();
      final free = hub.freeDevices.toList();
      final held = hub.heldPlaces;
      final iosDevices = controller.iosUsbDevices.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final addresses = controller.localAddresses.toList();
      final cap = hub.cap;
      // A Disconnect of every device (the remote view's, say) is still
      // ending them: no role can be changed meanwhile.
      final ending = hub.endingAll.value;
      // Why no device can be added now (no place, or ending everything),
      // the same for every row. Read here, so this builder follows it.
      final blocked = controller.addBlockedReason();
      // Two devices with the same model would look alike: their cards and
      // rows add the serial. Over Wi-Fi a card always shows the address.
      final models = <String, int>{};
      for (final m in [
        for (final s in sessions)
          (s.activeDevice.value ??
                  devices.firstWhereOrNull((d) => d.serial == s.key))
              ?.model,
        for (final d in free) d.model,
      ]) {
        if (m != null) models[m] = (models[m] ?? 0) + 1;
      }
      bool twin(String? model) => model != null && (models[model] ?? 0) > 1;
      // Which role a device found had last time. The known list is not
      // observable; reading it at each build is enough, since a tablet's
      // entry changes only while it has a session or is between two (and
      // so out of [free], which this builder follows).
      final rows = [
        for (final d in free)
          () {
            final known = settings.knownChoice(d.serial);
            // A remembered role the encoder has no room for now is no dead
            // end: Connect asks for the role (one the Mac only views always
            // fits), the remembered one shown but not offered.
            final knownFits =
                known == null || controller.fitsEncoder(d.serial, known);
            return AddDeviceRow(
              device: d,
              asksRole: known == null || !knownFits,
              subtitle: [
                d.isEmulator
                    ? 'home_row_emulator'.tr
                    : 'home_row_plugged_in'.tr,
                if (twin(d.model)) d.serial,
                known != null
                    ? 'home_row_last_role'.trParams({'role': known.roleLabel})
                    : 'home_row_new'.tr,
              ].join(' · '),
              disabledReason: blocked,
              note: blocked == null && !knownFits
                  ? 'home_row_role_no_room'.trParams({'role': known.roleLabel})
                  : null,
            );
          }(),
      ];
      // The devices connected, and, once no other can be added, that the
      // places are all taken (a tablet between two sessions, or one that
      // waits to retry, holds its own).
      final summary = [
        if (held.isNotEmpty || sessions.isNotEmpty || capturing)
          'home_devices_connected'.trParams({
            'n': '${sessions.where((s) => s.phase.value.isActive).length}',
          }),
        if (held.isNotEmpty && held.length >= cap)
          'home_devices_at_cap'.trParams({'cap': '$cap'}),
        if (capturing)
          'home_encoder_load'.trParams({
            'load': '${(hub.budget.load * 100).round()}',
            'codec': codecLabel,
          }),
      ].join(' · ');
      final anyCard = sessions.isNotEmpty || iosDevices.isNotEmpty;
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
          _DevicesHeader(
            key: const ValueKey('home/devices'),
            summary: summary.isEmpty ? null : summary,
          ),
          const SizedBox(height: 10),
          for (final s in sessions) ...[
            DeviceCard(
              key: ValueKey('session/${s.key}'),
              session: s,
              focused: sessions.length > 1 && s.key == focusedKey,
              showSerial: twin(
                (s.activeDevice.value ??
                        devices.firstWhereOrNull((d) => d.serial == s.key))
                    ?.model,
              ),
              listed: devices.firstWhereOrNull((d) => d.serial == s.key),
              onFocus: () => controller.onFocus(s.key),
              onStop: controller.onSessionStop,
              onRetry: controller.onSessionRetry,
              // That tablet's own native window, opened or brought
              // forward. The hub's focus stays.
              onOpenRemote: () => controller.onOpenRemoteView(s.key),
              onPictureSettings: () => DeviceSettingsSheet.show(
                context,
                s.key,
                name:
                    (s.activeDevice.value ??
                            devices.firstWhereOrNull((d) => d.serial == s.key))
                        ?.model ??
                    s.key,
              ),
              // Not while every session is being ended: the hub would
              // refuse.
              onRole: ending ? null : controller.onSessionMode,
            ),
            const SizedBox(height: 12),
          ],
          for (final d in iosDevices) ...[
            IphoneUsbCard(
              key: ValueKey('iphone-usb/${d.id}'),
              device: d,
              // The touch service is bound to one phone, which the capture
              // devices do not name: with two attached, neither card can say
              // whose touch it is.
              touch: iosDevices.length == 1 ? controller.iosTouchState : null,
              windowOpen: controller.iphoneWindowOpen(d.id),
              onOpen: () => controller.onOpenIphone(d.id),
            ),
            const SizedBox(height: 12),
          ],
          if (!anyCard)
            if (free.isEmpty && !hub.replacing)
              _EmptyState(
                key: const ValueKey('home/empty'),
                wifiOn: settings.wifiListenRx.value,
              )
            else
              Text(
                'home_none_connected'.tr,
                key: const ValueKey('home/none-connected'),
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
          const SizedBox(height: 20),
          AddDevicePanel(
            key: const ValueKey('home/add'),
            rows: rows,
            // A tablet between two sessions is attached, and on its way
            // back.
            emptyText:
                free.isEmpty &&
                    (sessions.isNotEmpty ||
                        hub.replacing ||
                        iosDevices.isNotEmpty)
                ? 'home_all_attached_connected'.tr
                : null,
            refreshing: controller.refreshingDevices.value,
            onRefresh: controller.refreshDevices,
            onConnect: controller.onConnectDevice,
            onChoose: (d) => _choose(context, d),
            // Always the last row, whatever the devices above do.
            wifiRow: _WifiAcceptRow(
              key: const ValueKey('add/wifi-listen'),
              on: settings.wifiListenRx.value,
              listening: hub.listening.value,
              addresses: addresses,
              turnedAway: hub.wifiTurnedAway.value,
              cap: cap,
              capIsTheMacs: controller.capIsTheMacs,
              onChanged: controller.onWifiListen,
            ),
          ),
        ],
      );
    });
  }
}

/// "Devices", and under it the places in use and the encoder's load.
class _DevicesHeader extends StatelessWidget {
  final String? summary;
  const _DevicesHeader({super.key, this.summary});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'home_devices'.tr,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (summary case final summary?)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              summary,
              key: const ValueKey('home/summary'),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

/// Nothing attached and nothing connected: what to do. With Wi-Fi already
/// accepted, it does not ask for it to be turned on.
class _EmptyState extends StatelessWidget {
  final bool wifiOn;
  const _EmptyState({super.key, required this.wifiOn});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Icon(Icons.usb, color: Colors.white38, size: 28),
          const SizedBox(height: 10),
          Text(
            (wifiOn ? 'home_empty_wifi_on' : 'home_empty').tr,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// The Add a device panel's last row, Accept devices over Wi-Fi: while it
/// is on, the Mac also takes paired devices on Wi-Fi (an iPhone, a tablet
/// set to Wi-Fi) beside the USB tablets, each in a place of its own under
/// Maximum tablets. It says where the Mac is (its addresses, to type on a
/// device that cannot find it), whether it accepts yet, and how many
/// devices it had no place for.
class _WifiAcceptRow extends StatelessWidget {
  final bool on;
  final bool listening;
  final List<String> addresses;
  final int turnedAway;

  /// The places, and whether this Mac sets them rather than Maximum
  /// tablets: then the turned-away line does not send the user to Settings.
  final int cap;
  final bool capIsTheMacs;
  final ValueChanged<bool> onChanged;
  const _WifiAcceptRow({
    super.key,
    required this.on,
    required this.listening,
    required this.addresses,
    required this.turnedAway,
    required this.cap,
    required this.capIsTheMacs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // A Material of its own: the panel it sits in paints its colour on a
    // plain box, which a list tile's ink would be drawn under.
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        value: on,
        onChanged: onChanged,
        secondary: const Icon(Icons.wifi, color: Colors.white70, size: 20),
        title: Text(
          'home_wifi_accept'.tr,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          [
            [
              'home_wifi_accept_desc'.tr,
              addresses.isEmpty
                  ? 'wifi_host_no_network'.tr
                  : 'home_wifi_mac_at'.trParams({'addr': addresses.join(', ')}),
            ].join(' · '),
            if (on && !listening) 'home_wifi_not_listening'.tr,
            if (on && turnedAway > 0)
              (capIsTheMacs
                      ? 'home_wifi_turned_away_mac'
                      : 'home_wifi_turned_away')
                  .trParams({'n': '$turnedAway', 'cap': '$cap'}),
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

/// USB or Wi-Fi, on the tablet's Home only (it shows whenever no session is
/// live). The Mac has none: its USB always runs, and Wi-Fi is the Add a
/// device panel's last row.
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
                                  color:
                                      selected ? Colors.white : Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                type.description,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11),
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
