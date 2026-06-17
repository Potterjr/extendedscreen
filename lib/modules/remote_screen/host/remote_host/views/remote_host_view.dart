import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/modules/remote_screen/host/remote_host/controllers/remote_host_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';

class RemoteHostView extends GetView<RemoteHostController> {
  const RemoteHostView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Obx(() {
                final tid = controller.textureId.value;
                if (tid == null) return const _WaitingForTablet();
                return AspectRatio(
                  aspectRatio: controller.aspectRatio,
                  child: LayoutBuilder(
                    builder: (ctx, cons) {
                      return Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) => controller.onPointerDown(
                          e.localPosition.dx / cons.maxWidth,
                          e.localPosition.dy / cons.maxHeight,
                        ),
                        onPointerUp: (e) => controller.onPointerUp(
                          e.localPosition.dx / cons.maxWidth,
                          e.localPosition.dy / cons.maxHeight,
                        ),
                        child: Texture(textureId: tid),
                      );
                    },
                  ),
                );
              }),
            ),
            _TopBar(controller: controller),
          ],
        ),
      ),
    );
  }
}

class _WaitingForTablet extends StatelessWidget {
  const _WaitingForTablet();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(
              strokeWidth: 3, color: Color(0xFF00C8FF)),
        ),
        const SizedBox(height: 18),
        Text(
          'remote_host_waiting'.tr,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  final RemoteHostController controller;
  const _TopBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
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
            Text(
              'session_remote_label'.tr,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Obx(() => _Chip(
                  icon: Icons.bolt,
                  label:
                      '${Get.find<BaseConnectionManager>().latencyMs.value}ms',
                )),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: controller.onReconnect,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text('common_reconnect'.tr),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: controller.onDisconnect,
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: Text('common_disconnect'.tr),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip({required this.icon, required this.label});

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
          Icon(icon, size: 12, color: Colors.white70),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}
