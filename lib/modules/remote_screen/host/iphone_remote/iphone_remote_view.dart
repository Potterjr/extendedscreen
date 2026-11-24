import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:extendedscreen/modules/remote_screen/host/ios_screen_channel.dart';
import 'package:extendedscreen/modules/remote_screen/host/ios_touch_service.dart';
import 'package:extendedscreen/modules/remote_screen/host/iphone_remote/iphone_remote_controller.dart';

/// Mac: an iPhone or iPad plugged in over USB, seen and driven (see
/// [IphoneRemoteController]).
class IphoneRemoteView extends GetView<IphoneRemoteController> {
  const IphoneRemoteView(
      {super.key, this.probeEnabled = IphoneRemoteController.probeDefine});

  /// Shows the latency probe's menu and overlay and probes each
  /// pointer-down (see [IphoneRemoteController.probeEnabled]; the
  /// controller's flag is its own, so tests can set both).
  final bool probeEnabled;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('iphone_remote_title'.tr),
        actions: [
          if (probeEnabled) _ProbeMenu(controller: controller),
          Obx(() => IconButton(
                key: const ValueKey('iphone/home'),
                icon: Icon(Icons.home_outlined,
                    color: controller.homeFailed.value
                        ? Colors.orangeAccent
                        : null),
                tooltip: controller.homeFailed.value
                    ? 'iphone_remote_home_failed'.tr
                    : 'iphone_remote_home'.tr,
                onPressed: controller.touch.state.value == IosTouchState.ready
                    ? controller.onHome
                    : null,
              )),
          Obx(() => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _TouchChip(state: controller.touch.state.value),
              )),
        ],
      ),
      body: Obx(() {
        final texture = controller.screen.textureId.value;
        final frame = controller.screen.frameSize.value;
        final state = controller.screenState.value;
        if (texture == null || frame == null) {
          return _Message(state: state, onRetry: controller.retry);
        }
        // The reason touches are off lies over the picture, so the picture
        // does not move when it comes and goes. Only a runner that does not
        // answer is worth a word: before the first try, and while the phone
        // is briefly off usbmuxd (it is, each time its capture starts), the
        // runner may well be running.
        final noRunner =
            controller.touch.state.value == IosTouchState.noRunner;
        return Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: AspectRatio(
                  aspectRatio: frame.width / frame.height,
                  child: LayoutBuilder(builder: (context, box) {
                    final size = Size(box.maxWidth, box.maxHeight);
                    final surface = GestureDetector(
                      key: const ValueKey('iphone/surface'),
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => controller.onTap(d.localPosition, size),
                      onLongPressStart: (d) =>
                          controller.onLongPressStart(d.localPosition),
                      onLongPressMoveUpdate: (_) => controller.onLongPressMove(),
                      onLongPressEnd: (d) =>
                          controller.onLongPressEnd(d.localPosition, size),
                      onLongPressCancel: controller.onLongPressCancel,
                      onPanStart: (d) => controller.onPanStart(d.localPosition),
                      onPanEnd: (d) => controller.onPanEnd(
                          d.localPosition, size),
                      onPanCancel: controller.onPanCancel,
                      child: Texture(textureId: texture),
                    );
                    if (!probeEnabled) return surface;
                    // A Listener sees the pointer go down before the gesture
                    // arena decides anything, so the probe starts there.
                    return Listener(
                      onPointerDown: (e) =>
                          controller.onPointerDown(e.localPosition, size),
                      child: surface,
                    );
                  }),
                ),
              ),
            ),
            if (noRunner)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _Banner(text: 'iphone_remote_runner_missing'.tr),
              ),
            if (probeEnabled)
              Positioned(
                left: 8,
                bottom: 8,
                child: _ProbeOverlay(controller: controller),
              ),
          ],
        );
      }),
    );
  }
}

/// The scripted latency trials (probe builds only).
class _ProbeMenu extends StatelessWidget {
  const _ProbeMenu({required this.controller});
  final IphoneRemoteController controller;

  @override
  Widget build(BuildContext context) => Obx(() => PopupMenuButton<ProbeScript>(
        key: const ValueKey('iphone/probe'),
        icon: const Icon(Icons.speed),
        tooltip: 'iphone_probe_menu'.tr,
        enabled: !controller.scripting.value,
        onSelected: (kind) => controller.runProbe(kind),
        itemBuilder: (_) => [
          PopupMenuItem(
              value: ProbeScript.tap,
              child: Text('iphone_probe_run_tap'.trParams(
                  {'n': '${IphoneRemoteController.probeTrials}'}))),
          PopupMenuItem(
              value: ProbeScript.swipe,
              child: Text('iphone_probe_run_swipe'.trParams(
                  {'n': '${IphoneRemoteController.probeTrials}'}))),
        ],
      ));
}

/// The felt probe's p50/p90 over its last results, and the scripted run's.
class _ProbeOverlay extends StatelessWidget {
  const _ProbeOverlay({required this.controller});
  final IphoneRemoteController controller;

  static String _ms(double? v) => v == null ? '–' : v.toStringAsFixed(0);

  static String _stats(ProbeSummary s) => 'iphone_probe_stats'.trParams({
        'n': '${s.count}',
        'p50': _ms(s.p50),
        'p90': _ms(s.p90),
      });

  @override
  Widget build(BuildContext context) => Obx(() {
        controller.probeRevision.value;
        final script = controller.script;
        final kind = controller.scriptKind;
        final lines = [
          '${'iphone_probe_felt'.tr} ${_stats(controller.felt)}'
              ' · ${'iphone_probe_last'.tr} ${_ms(controller.lastFeltMs.value)}',
          if (script != null && kind != null)
            '${kind == ProbeScript.tap ? 'atap' : 'aswipe'} '
                '${controller.scripting.value ? 'iphone_probe_running'.trParams({
                    'done': '${controller.scriptDone}',
                    'n': '${IphoneRemoteController.probeTrials}',
                  }) : ''} ${_stats(script)}',
        ];
        return Container(
          key: const ValueKey('iphone/probe-overlay'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Colors.black54,
          child: Text(lines.join('\n'),
              style: const TextStyle(
                  color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
        );
      });
}

class _TouchChip extends StatelessWidget {
  const _TouchChip({required this.state});
  final IosTouchState state;

  @override
  Widget build(BuildContext context) {
    final ready = state == IosTouchState.ready;
    return Chip(
      avatar: Icon(ready ? Icons.touch_app : Icons.do_not_touch,
          size: 16, color: ready ? Colors.greenAccent : Colors.orangeAccent),
      label: Text(ready
          ? 'iphone_remote_touch_ready'.tr
          : 'iphone_remote_touch_off'.tr),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: const Color(0xFF3A2A00),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(text,
            style: const TextStyle(color: Color(0xFFFFCC66), fontSize: 13)),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.state, required this.onRetry});
  final IphoneScreenState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = switch (state) {
      IphoneScreenState.noDevice => 'iphone_remote_no_device'.tr,
      IphoneScreenState.permissionDenied => 'iphone_remote_permission'.tr,
      IphoneScreenState.failed => 'iphone_remote_failed'.tr,
      _ => 'iphone_remote_waiting'.tr,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.phone_iphone, size: 48, color: Colors.white38),
            const SizedBox(height: 16),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
            if (state == IphoneScreenState.permissionDenied ||
                state == IphoneScreenState.failed) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: Text('common_retry'.tr)),
            ],
          ],
        ),
      ),
    );
  }
}
