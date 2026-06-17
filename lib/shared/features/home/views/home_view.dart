import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/shared/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
import 'package:extendedscreen/shared/models/session_mode.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';
import 'package:extendedscreen/shared/widgets/connection_card.dart';
import 'package:extendedscreen/shared/widgets/connection_steps.dart';
import 'package:extendedscreen/shared/widgets/device_info_card.dart';
import 'package:extendedscreen/shared/widgets/device_picker_card.dart';
import 'package:extendedscreen/shared/widgets/latency_chip.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    final cm = Get.find<BaseConnectionManager>();
    final settings = Get.find<SettingsService>();

    return Scaffold(
      appBar: AppBar(
        // On the host show the chosen session mode (the launcher feeds into
        // this screen) — wrapped in Obx so it reacts to mode changes. The
        // client always shows the static app name, so it must NOT be in an Obx
        // (a builder that reads no observable trips GetX's "improper use").
        title: controller.isHost
            ? Obx(() => Text(
                  settings.sessionModeRx.value.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ))
            : Text(
                'app_name'.tr,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: controller.onGoToSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Obx(() {
          final phase = cm.phase.value;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              ConnectionCard(
                phase: phase,
                onTap: controller.onConnectTap,
                // Host connects only via the device picker, not this button.
                canConnect: !controller.isHost,
                codecLabel: settings.codecRx.value == CodecType.h265
                    ? 'H.265'
                    : 'H.264',
              ),
              const SizedBox(height: 16),
              // Host: pick which Android client to stream to while idle.
              if (controller.isHost &&
                  !phase.isActive &&
                  !phase.isConnecting) ...[
                // Remote-control only: choose which side drives the session.
                if (controller.isRemoteControl) ...[
                  _DirectionSelector(controller: controller),
                  const SizedBox(height: 16),
                ],
                DevicePickerCard(
                  devices: cm.availableDevices,
                  onSelect: controller.onSelectDevice,
                  onRefresh: controller.refreshDevices,
                ),
                const SizedBox(height: 16),
              ],
              // Client: show connection progress and an Open View button that
              // unlocks once the stream is ready.
              if (!controller.isHost) ...[
                ConnectionSteps(phase: phase),
                const SizedBox(height: 20),
                // Reverse remote (Mac controls this tablet): the tablet is the
                // capture source, so offer a screen-share button instead of the
                // "open view" button (there is no incoming video to open).
                if (controller.needsScreenShare.value ||
                    controller.isScreenSharing.value)
                  _ShareScreenButton(controller: controller)
                else
                  _OpenViewButton(controller: controller, phase: phase),
                const SizedBox(height: 12),
              ],
              if (phase.isActive) ...[
                if (controller.isHost)
                  DeviceInfoCard(device: cm.activeDevice.value),
                if (controller.isHost) const SizedBox(height: 12),
                // Host, reverse remote (Mac controls tablet): the Mac is the
                // viewer. It auto-opens the remote view on connect, but offer a
                // button to get back in after backing out.
                if (controller.isHost && controller.isReverseRemote) ...[
                  _OpenRemoteButton(controller: controller),
                  const SizedBox(height: 12),
                ],
                LatencyChip(latencyMs: cm.latencyMs.value),
              ],
              if (phase == ConnectionPhase.error) ...[
                const SizedBox(height: 16),
                _ErrorBanner(message: cm.errorMessage.value),
              ],
            ],
          );
        }),
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
          final active = controller.remoteDirection.value;
          return Row(
            children: RemoteDirection.values.map((dir) {
              final selected = dir == active;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                      right: dir == RemoteDirection.values.first ? 8 : 0),
                  child: Material(
                    color: selected
                        ? const Color(0xFF00C8FF).withValues(alpha: 0.16)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => controller.onSelectDirection(dir),
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
                                color: selected ? Colors.white : Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              dir.description,
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
        }),
      ],
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
