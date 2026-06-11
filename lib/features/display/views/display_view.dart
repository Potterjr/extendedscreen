import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/features/display/controllers/display_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/services/settings_service.dart';

class DisplayView extends GetView<DisplayController> {
  const DisplayView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video surface — AndroidView bridges to SurfaceView + MediaCodec
          _VideoSurface(controller: controller),

          // Touch capture overlay
          _TouchOverlay(controller: controller),

          // HUD controls — visibility controlled by settings
          Obx(() => Get.find<SettingsService>().showHudOverlay.value
              ? _HudOverlay(controller: controller)
              : const SizedBox.shrink()),

          // Reconnect overlay — shown while the host restarts the stream (e.g.
          // after a preset/codec change) and the link is being re-established.
          Obx(() {
            final phase = Get.find<BaseConnectionManager>().phase.value;
            final reconnecting =
                phase.isConnecting || phase == ConnectionPhase.error;
            return reconnecting
                ? const _ReconnectingOverlay()
                : const SizedBox.shrink();
          }),
        ],
      ),
    );
  }
}

class _ReconnectingOverlay extends StatelessWidget {
  const _ReconnectingOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.78),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: Color(0xFF00C8FF)),
            ),
            SizedBox(height: 20),
            Text(
              'Reconnecting…',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 6),
            Text(
              'Applying new settings from the host',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoSurface extends StatelessWidget {
  final DisplayController controller;
  const _VideoSurface({required this.controller});

  @override
  Widget build(BuildContext context) {
    if (!controller.isAndroid) {
      return const Center(
        child: Text(
          'Display surface\n(Android only)',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38),
        ),
      );
    }
    return AndroidView(
      viewType: 'extended_screen/surface_view',
      onPlatformViewCreated: (_) {},
      creationParams: const {'width': 2960, 'height': 1848},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}

class _TouchOverlay extends StatelessWidget {
  final DisplayController controller;
  const _TouchOverlay({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        final size = MediaQuery.sizeOf(context);
        controller.onPointerDown(
          e.localPosition.dx / size.width,
          e.localPosition.dy / size.height,
          e.pointer,
          e.pressure,
        );
      },
      onPointerMove: (e) {
        final size = MediaQuery.sizeOf(context);
        controller.onPointerMove(
          e.localPosition.dx / size.width,
          e.localPosition.dy / size.height,
          e.pointer,
          e.pressure,
        );
      },
      onPointerUp: (e) {
        final size = MediaQuery.sizeOf(context);
        controller.onPointerUp(
          e.localPosition.dx / size.width,
          e.localPosition.dy / size.height,
          e.pointer,
        );
      },
      child: const SizedBox.expand(),
    );
  }
}

class _HudOverlay extends StatelessWidget {
  final DisplayController controller;
  const _HudOverlay({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top bar
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white, size: 18),
                onPressed: Get.back,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 12),
              const Text(
                'Extended Screen',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Obx(() => _StatChip(
                    icon: Icons.refresh,
                    label:
                        '${Get.find<BaseConnectionManager>().refreshRateHz.value} Hz',
                  )),
              const SizedBox(width: 8),
              Obx(() => _StatChip(
                    icon: Icons.speed,
                    label: '${controller.currentFps.value} fps',
                  )),
              const SizedBox(width: 8),
              Obx(() => _StatChip(
                    icon: Icons.bolt,
                    label: '${Get.find<BaseConnectionManager>().latencyMs.value}ms',
                  )),
              const SizedBox(width: 8),
              Obx(() {
                final drops = controller.droppedPerSec.value;
                return _StatChip(
                  icon: Icons.warning_amber_rounded,
                  label: '${drops}drop/s',
                  color: drops == 0
                      ? Colors.white70
                      : drops <= 3
                          ? Colors.orangeAccent
                          : Colors.redAccent,
                );
              }),
              const SizedBox(width: 8),
              TextButton(
                onPressed: controller.onDisconnect,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Disconnect'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  const _StatChip({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color ?? Colors.white70),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: color ?? Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}
