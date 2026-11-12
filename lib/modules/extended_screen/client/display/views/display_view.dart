import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/modules/extended_screen/client/display/controllers/display_controller.dart';
import 'package:extendedscreen/shared/connection/base_connection_manager.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/platform/battery_channel.dart';
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

          // HUD — a bar that collapses to a small handle at the top centre so
          // it doesn't cover the Mac's menu bar. The host's 'Show HUD' switch
          // only hides the stats: Back and Disconnect stay reachable.
          _HudOverlay(controller: controller),

          // Reconnect overlay — shown while the link is being re-established:
          // after a host settings change, but equally after a pulled cable,
          // the Mac sleeping or the Mac app quitting (the client can't tell
          // these apart and keeps redialling). It takes every tap, so it
          // carries its own exits.
          Obx(() {
            final phase = Get.find<BaseConnectionManager>().phase.value;
            final reconnecting =
                phase.isConnecting || phase == ConnectionPhase.error;
            return reconnecting
                ? _ReconnectingOverlay(controller: controller)
                : const SizedBox.shrink();
          }),
        ],
      ),
    );
  }
}

class _ReconnectingOverlay extends StatelessWidget {
  final DisplayController controller;
  const _ReconnectingOverlay({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                    strokeWidth: 3, color: Color(0xFF00C8FF)),
              ),
              const SizedBox(height: 20),
              Text(
                'display_reconnecting'.tr,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                'display_reconnect_hint'.tr,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Back leaves the view but keeps redialling; Home reopens
                  // the view by itself once the Mac is back.
                  OutlinedButton.icon(
                    onPressed: Get.back,
                    icon: const Icon(Icons.arrow_back_ios_new, size: 16),
                    label: Text('common_back'.tr),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: controller.onDisconnect,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: BorderSide(
                          color: Colors.redAccent.withValues(alpha: 0.6)),
                    ),
                    child: Text('common_disconnect'.tr),
                  ),
                ],
              ),
            ],
          ),
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
      return Center(
        child: Text(
          'display_surface_android_only'.tr,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38),
        ),
      );
    }
    // Surface buffer = this device's physical screen size.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);
    return AndroidView(
      viewType: 'extended_screen/surface_view',
      onPlatformViewCreated: (_) {},
      creationParams: {
        'width': (size.width * dpr).round(),
        'height': (size.height * dpr).round(),
      },
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
      onPointerDown: (e) => controller.onPointerDown(
          e.pointer, e.localPosition, MediaQuery.sizeOf(context)),
      onPointerMove: (e) => controller.onPointerMove(
          e.pointer, e.localPosition, MediaQuery.sizeOf(context)),
      onPointerUp: (e) => controller.onPointerUp(
          e.pointer, e.localPosition, MediaQuery.sizeOf(context)),
      onPointerCancel: (e) => controller.onPointerCancel(e.pointer),
      child: const SizedBox.expand(),
    );
  }
}

/// The top-of-screen HUD. It shows the bar for [_visibleFor] when the view
/// opens, then collapses it to [_HudHandle]; tapping the handle brings the bar
/// back, and any touch on the bar restarts the countdown. Only the visible bar
/// and the handle take touches; everywhere else falls through to
/// [_TouchOverlay], so the Mac's menu bar stays usable.
class _HudOverlay extends StatefulWidget {
  final DisplayController controller;
  const _HudOverlay({required this.controller});

  @override
  State<_HudOverlay> createState() => _HudOverlayState();
}

class _HudOverlayState extends State<_HudOverlay> {
  static const _visibleFor = Duration(seconds: 4);
  static const _fade = Duration(milliseconds: 200);

  Timer? _hideTimer;
  bool _barVisible = true;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_visibleFor, () {
      if (mounted) setState(() => _barVisible = false);
    });
  }

  void _reveal() {
    setState(() => _barVisible = true);
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    // The view is immersive and, on Android 15+, drawn under the camera
    // cutout: on some tablets a notch at the top centre, right where the
    // handle sits. Flutter folds the cutout's safe insets into the padding, so
    // SafeArea keeps the bar and the handle clear of it; with no cutout in the
    // window it adds nothing. The padding takes no touches of its own.
    return SafeArea(
      bottom: false,
      // Both layers stay mounted so they can fade; IgnorePointer (not the
      // opacity) is what lets touches through the hidden one.
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: IgnorePointer(
              ignoring: !_barVisible,
              child: AnimatedSlide(
                offset: _barVisible ? Offset.zero : const Offset(0, -1),
                duration: _fade,
                curve: Curves.easeOut,
                child: AnimatedOpacity(
                  opacity: _barVisible ? 1 : 0,
                  duration: _fade,
                  child: Listener(
                    onPointerDown: (_) => _scheduleHide(),
                    child: Obx(() => _HudBar(
                          controller: widget.controller,
                          showStats:
                              Get.find<SettingsService>().showHudOverlay.value,
                        )),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: IgnorePointer(
              ignoring: _barVisible,
              child: AnimatedOpacity(
                opacity: _barVisible ? 0 : 1,
                duration: _fade,
                child: _HudHandle(onTap: _reveal),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small tab at the top centre that reveals the HUD bar. Its touch target is
/// larger than the tab drawn inside it, but still small so it covers as
/// little of the Mac's menu bar as possible.
class _HudHandle extends StatelessWidget {
  final VoidCallback onTap;
  const _HudHandle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'display_show_controls'.tr,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 64,
          height: 48,
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: 48,
              height: 20,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(10)),
              ),
              child: const Icon(Icons.keyboard_arrow_down,
                  size: 18, color: Colors.white70),
            ),
          ),
        ),
      ),
    );
  }
}

/// The HUD bar itself. With [showStats] off (the host's 'Show HUD' switch) it
/// shrinks to Back and Disconnect, so the view always has an on-screen exit.
class _HudBar extends StatelessWidget {
  final DisplayController controller;
  final bool showStats;
  const _HudBar({required this.controller, required this.showStats});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: showStats ? MainAxisSize.max : MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'common_back'.tr,
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: Get.back,
            style: IconButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(width: 12),
          if (showStats) ...[
            Text(
              'app_name'.tr,
              style: const TextStyle(
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
            // The display auto-opens on connect and covers Home, so charging
            // has to be shown here too — this is where the tablet is used.
            if (Get.isRegistered<BatteryChannel>())
              Obx(() {
                final battery = Get.find<BatteryChannel>().status.value;
                if (battery == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _StatChip(
                    icon: battery.isCharging
                        ? Icons.battery_charging_full
                        : Icons.battery_std,
                    label: battery.level >= 0
                        ? '${battery.level}%'
                        : (battery.isCharging
                            ? 'battery_charging'.tr
                            : 'battery_not_charging'.tr),
                    color:
                        battery.isCharging ? const Color(0xFF00E676) : null,
                  ),
                );
              }),
          ],
          TextButton(
            onPressed: controller.onDisconnect,
            style: TextButton.styleFrom(
              foregroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text('common_disconnect'.tr),
          ),
        ],
      ),
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
