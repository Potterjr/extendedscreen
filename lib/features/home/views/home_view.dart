import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/home_controller.dart';
import '../../../core/connection/connection_manager.dart';
import '../../../core/connection/connection_state.dart';
import '../widgets/connection_card.dart';
import '../widgets/device_info_card.dart';
import '../widgets/latency_chip.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    final cm = Get.find<ConnectionManager>();

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
              ),
              const SizedBox(height: 16),
              if (phase.isActive) ...[
                DeviceInfoCard(device: cm.activeDevice.value),
                const SizedBox(height: 12),
                LatencyChip(latencyMs: cm.latencyMs.value),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: controller.onGoToDisplay,
                    icon: const Icon(Icons.open_in_full),
                    label: const Text('Open Display'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00C8FF),
                      foregroundColor: Colors.black,
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
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
