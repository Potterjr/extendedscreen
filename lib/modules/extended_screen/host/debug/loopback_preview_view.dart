import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:extendedscreen/modules/extended_screen/host/debug/loopback_preview_controller.dart';
import 'package:extendedscreen/shared/connection/connection_state.dart';
import 'package:extendedscreen/shared/models/display_config_model.dart';

/// Debug only (`SYNTH_TABLETS`): a tile per synthetic tablet, showing its
/// stream as it reached the tablet's socket, decoded on this Mac. Each tile
/// is drawn in its tablet's panel shape, so a stream that carries another
/// tablet's display shows bars. A tile's label says which mode its session
/// runs in; one the Mac views and drives (Mac -> Tablet) has no stream to
/// show, since the Mac sends it none and a stand-in sends no screen.
class LoopbackPreviewView extends GetView<LoopbackPreviewController> {
  const LoopbackPreviewView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'loopback_preview_title'.tr,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final tile in controller.tiles)
                _Tile(controller: controller, tile: tile),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final LoopbackPreviewController controller;
  final LoopbackTile tile;
  const _Tile({required this.controller, required this.tile});

  static const _accent = Color(0xFF00C8FF);

  @override
  Widget build(BuildContext context) {
    final panel = tile.tablet.panel;
    final dim = TextStyle(
      color: Colors.white.withValues(alpha: 0.55),
      fontSize: 12,
    );
    return SizedBox(
      width: 360,
      child: Obx(() {
        final session = controller.sessionOf(tile);
        final phase = session?.phase.value ?? ConnectionPhase.disconnected;
        final started = session?.captured.value;
        final notice = session?.notice.value;
        final codec = switch (tile.codec.value) {
          CodecType.h265 => 'H.265',
          CodecType.h264 => 'H.264',
          null => '–',
        };
        final texture = tile.textureId.value;
        final busy = phase.isConnecting || phase.isActive;
        // Fixed for the session's life: a tablet whose mode is changed gets
        // a new session, which this builder follows through the hub's map.
        final choice = session?.effectiveChoice;
        final reverse = choice?.isReverse ?? false;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${tile.tablet.serial}  ·  $panel Hz',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                TextButton(
                  // Keyed by what it does, as ConnectionCard's button: a
                  // phase change under a finger replaces it, so a press on
                  // Start never lands as Stop.
                  key: ValueKey('${tile.tablet.serial}/'
                      '${session != null && busy ? 'stop' : 'start'}'),
                  onPressed: () => session != null && busy
                      ? controller.stop(tile)
                      : controller.start(tile),
                  child: Text(session != null && busy
                      ? 'loopback_preview_stop'.tr
                      : 'loopback_preview_start'.tr),
                ),
              ],
            ),
            Text(
              [
                if (choice != null) choice.label,
                phase.label,
                codec,
                '${tile.fps.value} fps',
                if (started != null)
                  'loopback_preview_display'
                      .trParams({'id': '${started.displayId}'}),
                if (started?.fellBack ?? false) 'loopback_preview_fell_back'.tr,
              ].join('  ·  '),
              style: dim,
            ),
            if (notice != null)
              Text(
                notice.tr,
                style: const TextStyle(color: Color(0xFFFFB300), fontSize: 12),
              ),
            const SizedBox(height: 8),
            AspectRatio(
              aspectRatio: panel.width / panel.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: _accent.withValues(alpha: 0.4)),
                ),
                // A session the Mac views gets no stream from the Mac: a
                // texture still there is an earlier session's last picture,
                // so it is not shown as this one's.
                child: reverse
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'loopback_no_picture_reverse'.tr,
                            textAlign: TextAlign.center,
                            style: dim,
                          ),
                        ),
                      )
                    : texture == null
                        ? Center(
                            child: Text('loopback_preview_no_stream'.tr,
                                style: dim),
                          )
                        : Texture(textureId: texture),
              ),
            ),
          ],
        );
      }),
    );
  }
}
