import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/features/home/controllers/home_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';
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
        title: const Text(
          'Extended Screen',
          style: TextStyle(fontWeight: FontWeight.w600),
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
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: phase.isActive ? controller.onOpenView : null,
                    icon: const Icon(Icons.open_in_full),
                    label: Text(
                      phase.isActive ? 'Open View' : 'Waiting for stream…',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00C8FF),
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.white12,
                      disabledForegroundColor: Colors.white38,
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (phase.isActive) ...[
                if (controller.isHost)
                  DeviceInfoCard(device: cm.activeDevice.value),
                if (controller.isHost) const SizedBox(height: 12),
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
